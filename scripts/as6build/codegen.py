"""Translate the game program into the C++ sources the compatibility layer links.

Pipeline (all outputs pinned by SHA-256):
  1. Ghidra 12.1.4 imports the ARMv7 program with default analysis and the
     exporter writes its instruction semantics (P-code) stream.
  2. The stream is lowered to fixed C++ modules (generated/aot).
  3. Callback and table fragments are lowered the same way (generated/host).
  4. The program's data image is written as NativeDataBundle.cpp.
"""
import hashlib
import os
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIPELINE = HERE / 'pipeline'
STREAM_SHA256 = '291ae1ccb4800db77e9d1b01bb2434dd9403fb5474baa7202025112b2e9d263c'
GHIDRA_VERSION = '12.1.4'


def sha256(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def locate_tools(ghidra, jdk):
    ghidra = Path(ghidra or os.environ.get('GHIDRA_INSTALL_DIR', ''))
    jdk = Path(jdk or os.environ.get('JAVA_HOME', ''))
    if not (ghidra / 'support/analyzeHeadless').is_file():
        raise SystemExit('Ghidra %s not found: pass --ghidra or set GHIDRA_INSTALL_DIR' % GHIDRA_VERSION)
    if not (jdk / 'bin/java').is_file():
        raise SystemExit('JDK 21 not found: pass --jdk or set JAVA_HOME')
    return ghidra, jdk


def export_pcode(armv7, work, ghidra, jdk, log):
    out = work / 'pcode'
    stream = out / 'instructions.jsonl.gz'
    if stream.is_file() and sha256(stream) == STREAM_SHA256:
        log('codegen: P-code stream cached')
        return stream
    if out.exists():
        shutil.rmtree(out)
    (out / 'project').mkdir(parents=True)
    (out / 'tmp').mkdir()
    image = out / 'Asphalt6.armv7'
    shutil.copyfile(armv7, image)
    env = dict(os.environ, JAVA_HOME=str(jdk), _JAVA_HOME=str(jdk), TMPDIR=str(out / 'tmp'))
    log('codegen: Ghidra analysis (one-time, may take an hour or more)')
    subprocess.run([str(ghidra / 'support/analyzeHeadless'), str(out / 'project'), 'as6', '-import', str(image),
                    '-max-cpu', '2', '-scriptPath', str(PIPELINE), '-postScript', 'ExportPcodeStream.java',
                    str(image), str(out / 'instructions.partial.jsonl.gz'), str(out / 'non-instruction-ranges.jsonl.gz'),
                    str(PIPELINE / 'ghidra-listing-coverage.json'),
                    '-log', str(out / 'ghidra.log'), '-scriptlog', str(out / 'script.log')], env=env, check=True)
    partial = out / 'instructions.partial.jsonl.gz'
    if sha256(partial) != STREAM_SHA256:
        raise SystemExit('P-code stream differs from the supported analysis; see %s' % (out / 'ghidra.log'))
    partial.replace(stream)
    return stream


def generate(armv7, app, generated, work, ghidra=None, jdk=None, log=print):
    ghidra, jdk = locate_tools(ghidra, jdk)
    export_pcode(armv7, work, ghidra, jdk, log)
    raise SystemExit('codegen: lowering stages are not automated yet (see README, "Status")')
