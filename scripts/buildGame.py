#!/usr/bin/env python3
"""Build the Asphalt 6 arm64 compatibility layer from your own game copy.

    python3 scripts/buildGame.py Asphalt6.ipa

Requires an Apple Silicon Mac with Xcode (iOS SDK) and CMake 3.20+. Python
packages (scripts/requirements.txt), Ghidra 12.1.4 and JDK 21 are installed
into build/ automatically on the first run.

Steps (each verified against pinned hashes before the next one runs):
  [1/6] Preparing toolchain            check Xcode/CMake, install packages, Ghidra, JDK
  [2/6] Extracting the game IPA        check it is the supported 1.3.2 release
  [3/6] Building game resources        assemble Asphalt6Data for the app's Documents
  [4/6] Translating the game program (about 20 minutes)  C++ sources under build/generated/
  [5/6] Compiling AOT (about 1-2 hours) build the iOS libraries with CMake
  [6/6] Packaging                      link the unsigned IPA, zip the resources

Outputs in dist/: Asphalt6ARM64.ipa (unsigned, sign it with SideStore or
similar), Asphalt6Data.zip and, when artwork/ holds the HD images,
NativeArtwork.zip.
"""
import argparse
import fcntl
import hashlib
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from as6build import toolchain  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
WORK = ROOT / 'build/work'
DIST = ROOT / 'dist'
SUPPORTED_VERSION = '1.3.2'
ARMV7_SHA256 = '4a2209881ab5933113a15770b0615807cfa7d73bf50a9326569a7ed20f77df00'


STEPS = 6
INDENT = '      '


def step(number, title):
    print('[%d/%d] %s' % (number, STEPS, title), flush=True)


def log(message):
    # Details under the current step; drop the module prefix ("codegen: ...").
    print(INDENT + re.sub(r'^[a-z]+: ', '', message), flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def single_instance():
    """Refuse to run while another buildGame.py works on this checkout.

    flock is released by the kernel when the process exits, however it ends.
    The descriptor survives the re-exec into build/venv (same process).
    """
    inherited = os.environ.get('AS6_BUILD_LOCK_FD')
    if inherited:
        return int(inherited)
    lock = ROOT / 'build/buildGame.lock'
    lock.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        owner = os.read(fd, 32).decode(errors='replace').strip() or 'unknown'
        toolchain.fail('another buildGame.py is already running (pid %s); wait for it to finish' % owner)
    os.ftruncate(fd, 0)
    os.write(fd, str(os.getpid()).encode())
    os.set_inheritable(fd, True)
    os.environ['AS6_BUILD_LOCK_FD'] = str(fd)
    return fd


def extract(ipa):
    target = WORK / 'ipa'
    if target.exists():
        shutil.rmtree(target)
    with zipfile.ZipFile(ipa) as archive:
        for member in archive.infolist():
            path = Path(member.filename)
            if path.is_absolute() or '..' in path.parts:
                toolchain.fail('unsafe path in IPA: ' + member.filename)
        archive.extractall(target)
    apps = sorted((target / 'Payload').glob('*.app'))
    if len(apps) != 1:
        toolchain.fail('expected exactly one .app inside Payload/')
    app = apps[0]
    info = plistlib.loads((app / 'Info.plist').read_bytes())
    if info.get('CFBundleVersion') != SUPPORTED_VERSION:
        toolchain.fail('unsupported game version %s (need %s)' % (info.get('CFBundleVersion'), SUPPORTED_VERSION))
    armv7 = WORK / 'program.armv7'
    subprocess.run(['lipo', '-thin', 'armv7', str(app / info['CFBundleExecutable']), '-output', str(armv7)], check=True)
    if sha256(armv7) != ARMV7_SHA256:
        toolchain.fail('game program differs from the supported release')
    log('%s %s, game program verified' % (info.get('CFBundleDisplayName', app.name), SUPPORTED_VERSION))
    return app, armv7


def compile_ios(generated, jobs, debug=False):
    from tqdm import tqdm
    build = ROOT / 'build/ios'
    flags = '-g' if debug else ''
    subprocess.run(['cmake', '-S', str(ROOT), '-B', str(build), '-G', 'Unix Makefiles',
                    # -g adds debug info only (same machine code) but grows build/ios to ~18 GB.
                    '-DCMAKE_BUILD_TYPE=', '-DCMAKE_C_FLAGS=%s' % flags, '-DCMAKE_CXX_FLAGS=%s' % flags,
                    '-DCMAKE_OBJCXX_FLAGS=%s' % flags,
                    '-DCMAKE_CXX_EXTENSIONS=OFF', '-DCMAKE_OBJCXX_EXTENSIONS=OFF',
                    '-DCMAKE_SYSTEM_NAME=iOS', '-DCMAKE_OSX_SYSROOT=iphoneos', '-DCMAKE_OSX_ARCHITECTURES=arm64',
                    '-DCMAKE_OSX_DEPLOYMENT_TARGET=17.0', '-DAS6_GENERATED_DIR=%s' % generated],
                   check=True, stdout=subprocess.DEVNULL)
    sources = (len(list((generated / 'aot').glob('*.cpp'))) + len(list((generated / 'host').glob('*.cpp'))) +
               len([p for p in (ROOT / 'host/src').iterdir() if p.suffix in {'.cpp', '.m', '.mm'}]) + 4)
    log('%d sources, %d jobs%s (full log: build/compile.log)' % (sources, jobs, ', debug info' if debug else ''))
    with open(ROOT / 'build/compile.log', 'w') as record, \
            tqdm(total=sources, unit='file', desc=INDENT + 'compiling', smoothing=0.05) as bar:
        process = subprocess.Popen(['cmake', '--build', str(build), '--target', 'as6_ios_host', '--', '-j%d' % jobs],
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        tail = []
        for line in process.stdout:
            record.write(line)
            tail = (tail + [line])[-40:]
            if re.search(r'Building (CXX|C|OBJCXX) object', line):
                bar.update(1)
        if process.wait():
            sys.stderr.write(''.join(tail))
            toolchain.fail('compile failed; see build/compile.log')
        bar.update(bar.total - bar.n)
    return build


def zip_resources(folder, target):
    # Entries sit under Asphalt6Data/; the app unpacks it on first launch.
    with zipfile.ZipFile(target, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as archive:
        for path in sorted(folder.rglob('*')):
            if path.is_file():
                archive.write(path, path.relative_to(folder.parent))
    log('%s written' % target.relative_to(ROOT))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('ipa', type=Path, help='your Asphalt 6 1.3.2 IPA')
    parser.add_argument('--jobs', type=int, default=max(1, (os.cpu_count() or 2) // 2),
                        help='parallel compile jobs (default: half the CPU cores)')
    parser.add_argument('--debug', action='store_true',
                        help='compile with debug info (-g) for crash logs and profiling; build/ios grows to ~18 GB')
    args = parser.parse_args()
    if not args.ipa.is_file():
        parser.error('IPA not found: %s' % args.ipa)

    single_instance()
    # ensure_venv re-runs this script inside build/venv; announce step 1 once.
    if not os.environ.get('AS6_BUILD_IN_VENV'):
        step(1, 'Preparing toolchain')
    os.environ['AS6_BUILD_IN_VENV'] = '1'
    toolchain.check_system()
    if platform.machine() != 'arm64':
        toolchain.fail('an Apple Silicon Mac is required')
    toolchain.ensure_venv(log)
    from as6build import artwork, codegen, package, resources

    ghidra, jdk = toolchain.ensure_ghidra_and_jdk(log)
    log('Xcode, CMake, Python packages, Ghidra 12.1.4 and JDK 21 ready')
    step(2, 'Extracting the game IPA')
    WORK.mkdir(parents=True, exist_ok=True)
    app, armv7 = extract(args.ipa.resolve())
    step(3, 'Building game resources')
    data = resources.build(app, WORK / 'Asphalt6Data', log)
    step(4, 'Translating the game program (about 20 minutes)')
    generated = ROOT / 'build/generated'
    codegen.generate(armv7, app, generated, WORK, ghidra=ghidra, jdk=jdk, log=log)
    step(5, 'Compiling AOT (about 1-2 hours)')
    build = compile_ios(generated, args.jobs, debug=args.debug)
    step(6, 'Packaging')
    DIST.mkdir(exist_ok=True)
    package.package(build, app, data, DIST, log=log)
    zip_resources(WORK / 'Asphalt6Data', DIST / 'Asphalt6Data.zip')
    if artwork.SOURCE.is_dir():
        artwork.package(DIST / 'NativeArtwork.zip', log=log)
    else:
        log('artwork/ not found, NativeArtwork.zip skipped')
    print('Done. Sign and install dist/Asphalt6ARM64.ipa with SideStore, then copy dist/Asphalt6Data.zip '
          '(and optionally dist/NativeArtwork.zip) into the app\'s folder in Files.', flush=True)


if __name__ == '__main__':
    main()
