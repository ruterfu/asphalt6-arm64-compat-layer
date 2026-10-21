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
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
VENV = ROOT / 'build/venv'
CAPSTONE = 'capstone==5.0.7'
PIPELINE = HERE / 'pipeline'
# SHA-256 of the normalized, uncompressed stream (see normalize_stream).
STREAM_SHA256 = '815d958ced17e73334c0f470e53322ddb65f942cb6efefc0021ad1096782610d'
EXTERNAL_PLACEHOLDERS = 0x800000
# Code the default listing leaves undisassembled: (exporter, address list,
# expected record count, SHA-256 of the sorted canonical records).
RECOVERIES = (
    ('ExportTargetedInit.java', 'init-addresses.txt', 1270,
     '9039ed936afe3e8908b98608ff6c9e716ec4a6329bc8de4b285ade7db6a502bd'),
    ('ExportRecoveredLandingPad.java', 'landingpad-addresses.txt', 237,
     'c90bc4aa0471cefde315ca71f055974756c8893332caf20f882034ab91958668'),
)
LAYOUT_FIELDS = ('image_sha256', 'program_name', 'lang', 'compiler', 'pcode_source', 'flow_overrides_included',
                 'byte_order', 'address_spaces', 'registers', 'userops')
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


def canonical(value):
    # Same form the reference build hashed records with (no trailing newline).
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def record_key(record):
    return (int(record['address'], 0) << 1) | int(record['context']['TMode'] == '0x1')


def headless(ghidra, jdk, project, script_dir, script, arguments, log_dir):
    env = dict(os.environ, JAVA_HOME=str(jdk), _JAVA_HOME=str(jdk), TMPDIR=str(log_dir))
    subprocess.run([str(ghidra / 'support/analyzeHeadless'), str(project), 'as6', '-process', 'Asphalt6.armv7',
                    '-readOnly', '-noanalysis', '-max-cpu', '1', '-scriptPath', str(script_dir), '-postScript', script,
                    *[str(a) for a in arguments], '-log', str(log_dir / (script + '.log'))], env=env, check=True)


def recover_supplemental(stream, work, ghidra, jdk, log):
    """Export code the listing leaves undisassembled, from scratch fragments."""
    out = work / 'recovered'
    out.mkdir(parents=True, exist_ok=True)
    with gzip.open(stream) as reader:
        header = json.loads(reader.readline())
    template = out / 'layout-template.json'
    template.write_text(json.dumps(dict({k: header[k] for k in LAYOUT_FIELDS}, schema_version=1,
                                        image_path=str(work / 'pcode/Asphalt6.armv7'), functions=[])))
    records = []
    paths = []
    for script, addresses, count, digest in RECOVERIES:
        target = out / (script[:-5] + '.json')
        if not target.is_file():
            headless(ghidra, jdk, work / 'pcode/project', PIPELINE / 'recover', script,
                     [target, work / 'pcode/Asphalt6.armv7', PIPELINE / 'recover' / addresses, template], out)
        document = json.loads(target.read_text())
        found = sorted((i for f in document['functions'] for i in f['instructions']), key=record_key)
        if len(found) != count or hashlib.sha256(canonical(found)).hexdigest() != digest:
            raise SystemExit('recovered code differs from the supported analysis: ' + script)
        records += found
        paths.append(target)
    log('codegen: %d supplemental instructions verified' % len(records))
    return paths


def lowering_python(log):
    """Python with the pinned capstone the lowering planners require."""
    python = VENV / 'bin/python'
    probe = [str(python), '-c', 'import capstone,sys;sys.exit(capstone.__version__!="5.0.7")']
    if python.is_file() and subprocess.run(probe).returncode == 0:
        return python
    log('codegen: preparing %s in %s' % (CAPSTONE, VENV))
    subprocess.run([sys.executable, '-m', 'venv', str(VENV)], check=True)
    subprocess.run([str(python), '-m', 'pip', 'install', '-q', CAPSTONE], check=True)
    return python


def lower_stream(stream, armv7, supplemental, output, log):
    expected = json.loads((HERE / 'data/aot-sha256.json').read_text())
    if output.is_dir() and {p.name for p in output.glob('*.cpp')} == set(expected) and \
            all(sha256(output / n) == h for n, h in expected.items()):
        log('codegen: translated modules cached')
        return
    if output.exists():
        shutil.rmtree(output)
    log('codegen: translating the program (about 10 minutes)')
    subprocess.run([str(lowering_python(log)), '-I', str(HERE / 'lower.py'), str(stream), str(armv7),
                    ','.join(str(p) for p in supplemental), str(output)], check=True)
    wrong = sorted(n for n, h in expected.items() if not (output / n).is_file() or sha256(output / n) != h)
    if wrong or len(list(output.glob('*.cpp'))) != len(expected):
        raise SystemExit('translated modules differ from the reference: %s' % ', '.join(wrong[:5]))
    log('codegen: %d translated modules verified' % len(expected))


def promote_modules(source, target, log):
    """Block-structured register promotion (keeps each original as fallback)."""
    if target.exists():
        shutil.rmtree(target)
    log('codegen: register promotion')
    subprocess.run([sys.executable, '-I', str(HERE / 'promote.py'), str(source), str(target)], check=True)


def export_fragments(stream, work, ghidra, jdk, log):
    """Run each fragment exporter against the analyzed project."""
    out = work / 'fragments'
    out.mkdir(parents=True, exist_ok=True)
    template = work / 'recovered/layout-template.json'
    for folder in sorted((PIPELINE / 'fragments').iterdir()):
        target = out / (folder.name + '.json')
        if target.is_file():
            continue
        script = next(folder.glob('Export*.java')).name
        arguments = [target, work / 'pcode/Asphalt6.armv7', folder / 'addresses.txt', template]
        if (folder / 'discovery.json').is_file():
            arguments.append(folder / 'discovery.json')
        headless(ghidra, jdk, work / 'pcode/project', folder, script, arguments, out)
    log('codegen: fragment code exported')
    return out


def lower_fragments(exports, target, work, log):
    expected = json.loads((HERE / 'data/fragments-sha256.json').read_text())
    subprocess.run([str(lowering_python(log)), '-I', str(HERE / 'fragments.py'), str(exports), str(target),
                    str(work / 'fragment-tools')], check=True, stdout=subprocess.DEVNULL)
    wrong = sorted(n for n, h in expected.items() if not (target / n).is_file() or sha256(target / n) != h)
    if wrong:
        raise SystemExit('fragment modules differ from the reference: %s' % ', '.join(wrong[:5]))
    log('codegen: %d fragment modules verified' % len(expected))


BUNDLE_SHA256 = 'fac017704c0071a324ff3d75a33a87a0e8df93cf3e54d1158edceaf6c713dca7'
PAYLOAD_SHA256 = 'd741ab84d87021728f45a69326c1a39befe2a21bbf8acd703065b5156d31f60e'
IMAGE_FILE_DELTA = 0x1000  # program virtual address - file offset, all sections


def write_data_bundle(armv7, target, log):
    """NativeDataBundle.cpp: the program's data image laid out for the layer.

    The template carries the layout (regions, spans, bindings); the span bytes
    are read from the user's program and filled into the payload array.
    """
    import re
    image = Path(armv7).read_bytes()
    template = (HERE / 'data/NativeDataBundle.template.cpp').read_text()
    table = template[template.index('const as6native::DataSpan spans[] = {'):]
    spans = re.findall(r'\{0x([0-9a-f]+)u,(\d+)u,payload\+(\d+),as6native::DataKind::\w+\}', table[:table.index('};')])
    size = max(int(offset) + int(length) for _, length, offset in spans)
    payload = bytearray(size)
    for address, length, offset in spans:
        start = int(address, 16) - IMAGE_FILE_DELTA
        payload[int(offset):int(offset) + int(length)] = image[start:start + int(length)]
    if hashlib.sha256(payload).hexdigest() != PAYLOAD_SHA256:
        raise SystemExit('program data differs from the supported release')
    rows = '\n'.join('  ' + ','.join('0x%02x' % v for v in payload[i:i + 24]) + ','
                     for i in range(0, len(payload), 24))
    text = template.replace('@AS6_PAYLOAD@', rows, 1)
    if hashlib.sha256(text.encode()).hexdigest() != BUNDLE_SHA256:
        raise SystemExit('NativeDataBundle.cpp differs from the reference')
    target.mkdir(parents=True, exist_ok=True)
    (target / 'NativeDataBundle.cpp').write_text(text)
    log('codegen: data bundle verified')


def hook_modules(reference, target, log):
    """Copies of translated modules with the layer's boundary hooks added."""
    target.mkdir(parents=True, exist_ok=True)
    for spec in json.loads((HERE / 'data/module-hooks.json').read_text()):
        source = (reference / spec['module']).read_text()
        if hashlib.sha256(source.encode()).hexdigest() != spec['source_sha256']:
            raise SystemExit('hooked module source differs: ' + spec['module'])
        lines = source.split('\n')
        for start, end, replacement in reversed(spec['edits']):
            lines[start:end] = replacement
        text = '\n'.join(lines)
        if hashlib.sha256(text.encode()).hexdigest() != spec['sha256']:
            raise SystemExit('hooked module differs: ' + spec['output'])
        (target / spec['output']).write_text(text)
    log('codegen: hooked modules written')


def generate(armv7, app, generated, work, ghidra=None, jdk=None, promote=True, log=print):
    ghidra, jdk = locate_tools(ghidra, jdk)
    stream = export_pcode(armv7, work, ghidra, jdk, log)
    supplemental = recover_supplemental(stream, work, ghidra, jdk, log)
    reference = work / 'aot'
    lower_stream(stream, armv7, supplemental, reference, log)
    if promote:
        promote_modules(reference, generated / 'aot', log)
    else:
        if (generated / 'aot').exists():
            shutil.rmtree(generated / 'aot')
        shutil.copytree(reference, generated / 'aot')
    hook_modules(reference, generated / 'host', log)
    lower_fragments(export_fragments(stream, work, ghidra, jdk, log), generated / 'host', work, log)
    write_data_bundle(armv7, generated / 'host', log)
