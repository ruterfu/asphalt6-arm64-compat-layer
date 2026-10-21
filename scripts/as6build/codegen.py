"""Translate the game program into the C++ sources the compatibility layer links.

Pipeline (all outputs pinned by SHA-256):
  1. Ghidra 12.1.4 imports the ARMv7 program with default analysis and the
     exporter writes its instruction semantics (P-code) stream.
  2. The stream is lowered to fixed C++ modules (generated/aot).
  3. Callback and table fragments are lowered the same way (generated/host).
  4. The program's data image is written as NativeDataBundle.cpp.
"""
import gzip
import hashlib
import json
import os
import shutil
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
PIPELINE = HERE / 'pipeline'
# SHA-256 of the normalized, uncompressed stream (see normalize_stream).
STREAM_SHA256 = '815d958ced17e73334c0f470e53322ddb65f942cb6efefc0021ad1096782610d'
EXTERNAL_PLACEHOLDERS = 0x800000
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


def normalize_stream(source, target):
    """Drop Ghidra's external placeholder call targets and order the rest.

    Placeholder addresses (EXTERNAL block, outside the program image) depend
    on analysis order and differ between runs; everything else is stable.
    Returns the SHA-256 of the normalized, uncompressed stream.
    """
    digest = hashlib.sha256()
    with gzip.open(source) as reader, gzip.open(target, 'wb') as writer:
        for line in reader:
            if b'"flows":[' in line:
                record = json.loads(line)
                record['flows'] = sorted(t for t in record.get('flows', []) if int(t, 16) < EXTERNAL_PLACEHOLDERS)
                line = (json.dumps(record, separators=(',', ':')) + '\n').encode()
            digest.update(line)
            writer.write(line)
    return digest.hexdigest()


def export_pcode(armv7, work, ghidra, jdk, log):
    out = work / 'pcode'
    stream = out / 'instructions.jsonl.gz'
    marker = out / 'instructions.sha256'
    if stream.is_file() and marker.is_file() and marker.read_text().strip() == STREAM_SHA256:
        log('codegen: P-code stream cached')
        return stream
    if out.exists():
        shutil.rmtree(out)
    (out / 'project').mkdir(parents=True)
    (out / 'tmp').mkdir()
    image = out / 'Asphalt6.armv7'
    shutil.copyfile(armv7, image)
    env = dict(os.environ, JAVA_HOME=str(jdk), _JAVA_HOME=str(jdk), TMPDIR=str(out / 'tmp'))
    log('codegen: Ghidra analysis (one-time, about 10-20 minutes)')
    subprocess.run([str(ghidra / 'support/analyzeHeadless'), str(out / 'project'), 'as6', '-import', str(image),
                    '-max-cpu', '2', '-scriptPath', str(PIPELINE), '-postScript', 'ExportPcodeStream.java',
                    str(image), str(out / 'instructions.partial.jsonl.gz'), str(out / 'non-instruction-ranges.jsonl.gz'),
                    str(PIPELINE / 'ghidra-listing-coverage.json'),
                    '-log', str(out / 'ghidra.log'), '-scriptlog', str(out / 'script.log')], env=env, check=True)
    partial = out / 'instructions.partial.jsonl.gz'
    if normalize_stream(partial, stream) != STREAM_SHA256:
        stream.unlink()
        raise SystemExit('P-code stream differs from the supported analysis; see %s' % (out / 'ghidra.log'))
    marker.write_text(STREAM_SHA256 + '\n')
    partial.unlink()
    log('codegen: P-code stream verified')
    return stream


def generate(armv7, app, generated, work, ghidra=None, jdk=None, log=print):
    ghidra, jdk = locate_tools(ghidra, jdk)
    export_pcode(armv7, work, ghidra, jdk, log)
    raise SystemExit('codegen: lowering stages are not automated yet (see README, "Status")')
