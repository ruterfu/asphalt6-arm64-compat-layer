"""Lower the code fragments the listing does not reach into generated/host.

Callback tables, vtable gaps and runtime stubs are exported by their own
Ghidra scripts (pipeline/fragments/<name>/) and lowered with the same module
generator as the main program: either in 512-record modules or as one module.
Runs with build/venv's Python (capstone is required by the planners).

usage: fragments.py EXPORT_DIR OUTPUT_DIR
"""
import hashlib
import json
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import lower  # noqa: E402

# (pipeline, module name or prefix, output file or prefix, 512-record blocks,
#  floating/atomic registry category for records owned by this pipeline)
FRAGMENTS = (
    ('anonymous-vtable-gap-recovery', 'anonymous_vtable', 'AnonymousVtable', True,
     'owned-original-anonymous-vtable-recovery'),
    ('autofit-script-callback-recovery', 'autofit_scripts', 'AutofitScripts', True, None),
    ('freetype-callback-recovery', 'freetype_callbacks', 'FreeTypeCallbacks', True, None),
    ('freetype-parser-callback-recovery', 'freetype_parsers', 'FreeTypeParsers', True, None),
    ('freetype-service-callback-recovery', 'freetype_services', 'FreeTypeServices', True, None),
    ('secondary-vtable-class-recovery', 'secondary_vtable_classes', 'SecondaryVtableClasses', True, None),
    ('secondary-vtable-extra-recovery', 'secondary_vtable_extras', 'SecondaryVtableExtras', True, None),
    ('secondary-vtable-thunk-recovery', 'secondary_vtable_thunks', 'SecondaryVtableThunks', True, None),
    ('tt-cmap-callback-recovery', 'tt_cmap_callbacks', 'TTCMapCallbacks', True, None),
    ('winfnt-cmap-callback-recovery', 'winfnt_cmap_callbacks', 'WinFNTCMapCallbacks', True, None),
    ('named-vtable-gap-recovery', 'named_vtable_gaps', 'NamedVtableGaps', False, None),
    ('runtime-callback-5a70ac', 'runtime_callback_5a70ac', 'RuntimeCallback5a70ac', False, None),
    ('runtime-gap-3e4784', 'runtime_gap_3e4784', 'RuntimeGap3e4784', False, 'owned-original-runtime-gap-recovery'),
    ('runtime-gap-4d6c30', 'runtime_gap_4d6c30', 'RuntimeGap4d6c30', False, None),
    ('first-init-gap-recovery', 'startup_recovery_10000', 'StartupRecovery10000', False, None),
)
FRAGMENT_DIR = HERE / 'pipeline' / 'fragments'
INCLUDE = ('#include "../runtime/native_program.hpp"', '#include "native_program.hpp"')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


def owned(record, kind):
    mnemonic = record['mnemonic'].lower()
    if kind == 'atomic':
        return mnemonic.startswith(('ldrex', 'strex', 'dmb', 'dsb', 'clrex', 'isb', 'swp'))
    word = int.from_bytes(bytes.fromhex(record['bytes']), 'little')
    return (any(op['name'].startswith('FLOAT') or op['name'] in {'TRUNC', 'INT2FLOAT'} or
                (op.get('userop_name') or '').startswith(('FloatVector', 'VectorSignedToFloat', 'VectorUnsignedToFloat'))
                for op in record['pcode']) or
            (word & 0x0f000e00) == 0x0e000a00 or any(v in mnemonic for v in ('.f16', '.f32', '.f64')) or
            mnemonic.startswith(('vmrs', 'vmsr')))


def private_lowering(records, category, work):
    """Copy of the lowering tools whose registries also admit `records`."""
    target = work / ('lower-' + category)
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(lower.LOWER, target)
    for kind, registry_name, lock_name, field_key, lock_key in (
            ('atomic', 'verified-atomic-records.json', 'atomic-dependencies.lock.json', 'exact_fields', 'registry_sha256'),
            ('fp', 'verified-fp-records.json', 'fp-dependencies.lock.json', 'canonical_fields', 'fp_registry_sha256')):
        path = target / registry_name
        registry = json.loads(path.read_text())
        for record in records:
            if not owned(record, kind):
                continue
            pc = hex(int(record['address'], 0))
            digest = hashlib.sha256(canonical({f: record.get(f) for f in registry[field_key]})).hexdigest()
            key, value = (pc, digest) if kind == 'atomic' else (pc + ':0', {'canonical_sha256': digest, 'category': category})
            if key in registry['instructions'] and registry['instructions'][key] != value:
                raise RuntimeError('fragment record conflicts with the program registry: ' + key)
            registry['instructions'][key] = value
        path.write_text(json.dumps(registry, indent=2) + '\n')
        lock_path = target / lock_name
        lock = json.loads(lock_path.read_text())
        lock[lock_key] = sha256(path)
        lock_path.write_text(json.dumps(lock, indent=2) + '\n')
    return target


def generate(exports, output, work):
    output.mkdir(parents=True, exist_ok=True)
    written = []
    for pipeline, name, filename, blocks, category in FRAGMENTS:
        document = json.loads((exports / (pipeline + '.json')).read_text())
        records = document['functions'][0]['instructions']
        tools = private_lowering(records, category, work) if category else lower.LOWER
        ModuleGenerator = lower.module_generator(lower.load_lifter(tools))
        if blocks:
            units = []
            for index, start in enumerate(range(0, len(records), 512)):
                block = records[start:start + 512]
                doc = dict(document)
                doc['functions'] = [dict(document['functions'][0], entry=block[0]['address'], instructions=block)]
                doc['instruction_count'] = len(block)
                units.append((doc, block, f'{name}_{index:02d}', f'{filename}{index:02d}.cpp'))
        else:
            units = [(document, records, name, filename + '.cpp')]
        for doc, block, module_name, file_name in units:
            raw, _ = ModuleGenerator(doc).module(block, module_name)
            if raw.count(INCLUDE[0]) != 1:
                raise RuntimeError('unexpected module include in ' + file_name)
            (output / file_name).write_text(raw.replace(*INCLUDE, 1))
            written.append(file_name)
    return written


if __name__ == '__main__':
    exports, output, work = (Path(p) for p in sys.argv[1:4])
    for name in generate(exports, output, work):
        print(name)
