"""Build prerequisites: system tools, the Python environment, Ghidra and JDK.

System tools (Xcode, CMake) must already be installed. Python packages come
from scripts/requirements.txt into build/venv. Ghidra and the JDK are
downloaded once into build/tools and verified by SHA-256.
"""
import contextlib
import hashlib
import os
import shutil
import signal
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
VENV = ROOT / 'build/venv'
TOOLS = ROOT / 'build/tools'
REQUIREMENTS = ROOT / 'scripts/requirements.txt'

GHIDRA = {
    'url': 'https://github.com/NationalSecurityAgency/ghidra/releases/download/'
           'Ghidra_12.1.4_build/ghidra_12.1.4_PUBLIC_20260921.zip',
    'sha256': 'ddac49f903da9d5bac833e5cc79395098b9c33cfd3279be5f31bd00387d2d4db',
    'home': 'ghidra_12.1.4_PUBLIC',
}
JDK = {
    'url': 'https://github.com/adoptium/temurin21-binaries/releases/download/jdk-21.0.12.1%2B1/'
           'OpenJDK21U-jdk_aarch64_mac_hotspot_21.0.12.1_1.tar.gz',
    'sha256': '3623232f33a9c3baadf304480b2535f9a3cba8a58d42ecbb438ba267315d9998',
    'home': 'jdk-21.0.12.1+1/Contents/Home',
}


@contextlib.contextmanager
def child(command, **options):
    """Popen in its own process group; on any exit path out of the block
    (error, Ctrl-C) the whole group is stopped so no tool keeps running."""
    process = subprocess.Popen(command, start_new_session=True, **options)
    try:
        yield process
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        process.wait()
        raise


def fail(message):
    raise SystemExit('error: ' + message)


def check_system():
    """Tools that cannot be installed for the user."""
    if sys.platform != 'darwin':
        fail('macOS is required (Xcode builds the iOS app)')
    if sys.version_info < (3, 9):
        fail('Python 3.9 or newer is required')
    for tool in ('cmake', 'xcrun', 'lipo', 'codesign', 'unzip', 'make'):
        if not shutil.which(tool):
            fail('%s not found; install Xcode and CMake 3.20+ (for example: brew install cmake)' % tool)
    sdk = subprocess.run(['xcrun', '--sdk', 'iphoneos', '--show-sdk-path'], capture_output=True, text=True)
    if sdk.returncode or not sdk.stdout.strip():
        fail('the iOS SDK was not found; install Xcode (not only the command line tools)')
    version = subprocess.run(['cmake', '--version'], capture_output=True, text=True).stdout.split()
    major, minor = (int(v) for v in version[2].split('.')[:2])
    if (major, minor) < (3, 20):
        fail('CMake 3.20 or newer is required (found %s)' % version[2])


def ensure_venv(log):
    """Re-run this script inside build/venv with requirements.txt installed."""
    python = VENV / 'bin/python'
    marker = VENV / '.requirements'
    wanted = REQUIREMENTS.read_text()
    if not (python.is_file() and marker.is_file() and marker.read_text() == wanted):
        log('installing Python packages (%s)' % ', '.join(wanted.split()))
        marker.unlink(missing_ok=True)
        if subprocess.run([sys.executable, '-m', 'venv', str(VENV)]).returncode:
            fail('could not create the Python environment in build/venv')
        if subprocess.run([str(python), '-m', 'pip', 'install', '-q', '--disable-pip-version-check',
                           '-r', str(REQUIREMENTS)]).returncode:
            fail('installing Python packages failed; check the network connection and run again')
        marker.write_text(wanted)
    if Path(sys.prefix).resolve() != VENV.resolve():
        os.execv(str(python), [str(python), '-I'] + sys.argv)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def download(spec, target, log, attempts=3):
    from tqdm import tqdm
    if target.is_file() and sha256(target) == spec['sha256']:
        return target
    partial = target.with_suffix(target.suffix + '.part')
    name = spec['url'].rsplit('/', 1)[-1]
    log('downloading ' + name)
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(spec['url'], timeout=60) as response, open(partial, 'wb') as out:
                total = int(response.headers.get('Content-Length') or 0)
                with tqdm(total=total, unit='B', unit_scale=True, leave=False, desc='      downloading') as bar:
                    for block in iter(lambda: response.read(1 << 20), b''):
                        out.write(block)
                        bar.update(len(block))
            if sha256(partial) == spec['sha256']:
                partial.replace(target)
                return target
            problem = 'checksum mismatch'
        except (OSError, urllib.error.URLError) as error:
            problem = str(getattr(error, 'reason', error))
        partial.unlink(missing_ok=True)
        if attempt < attempts:
            log('download failed (%s), retrying (%d/%d)' % (problem, attempt + 1, attempts))
    fail('could not download %s (%s); check the network connection and run again' % (name, problem))


def unpack(archive, home, extract):
    """Extract into a scratch folder and move the result into place, so an
    interrupted extraction never looks like a finished install."""
    scratch = TOOLS / '.extracting'
    shutil.rmtree(scratch, ignore_errors=True)
    scratch.mkdir(parents=True)
    extract(archive, scratch)
    top = home.relative_to(TOOLS).parts[0]
    shutil.rmtree(TOOLS / top, ignore_errors=True)
    os.replace(scratch / top, TOOLS / top)
    shutil.rmtree(scratch, ignore_errors=True)
    archive.unlink()


def build_decompiler(ghidra, log):
    """Ghidra releases ship no Apple Silicon decompiler. Without it the
    analysis cannot recover switch tables and disassembles less of the
    program, so build it from the sources bundled with the release."""
    feature = ghidra / 'Ghidra/Features/Decompiler'
    target = feature / 'os/mac_arm_64/decompile'
    if target.is_file():
        return
    log('building the Ghidra decompiler for Apple Silicon (about a minute)')
    source = feature / 'src/decompile/cpp'
    result = subprocess.run(['make', '-j%d' % (os.cpu_count() or 4), 'ARCH_TYPE=-arch arm64', 'ghidra_opt'],
                            cwd=source, capture_output=True, text=True)
    if result.returncode:
        sys.stderr.write(result.stdout[-4000:] + result.stderr[-4000:])
        fail('building the Ghidra decompiler failed')
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_name(target.name + '.part')
    shutil.copy2(source / 'ghidra_opt', partial)
    os.replace(partial, target)


def ensure_ghidra_and_jdk(log):
    TOOLS.mkdir(parents=True, exist_ok=True)
    ghidra, jdk = TOOLS / GHIDRA['home'], TOOLS / JDK['home']
    if not (ghidra / 'support/analyzeHeadless').is_file():
        # The system unzip keeps the executable bits Ghidra's launchers need.
        unpack(download(GHIDRA, TOOLS / 'ghidra.zip', log), ghidra,
               lambda a, d: subprocess.run(['unzip', '-q', '-o', str(a), '-d', str(d)], check=True))
    build_decompiler(ghidra, log)
    if not (jdk / 'bin/java').is_file():
        def untar(a, d):
            with tarfile.open(a) as t:
                t.extractall(d, **({'filter': 'tar'} if hasattr(tarfile, 'tar_filter') else {}))
        unpack(download(JDK, TOOLS / 'jdk.tar.gz', log), jdk, untar)
    return ghidra, jdk
