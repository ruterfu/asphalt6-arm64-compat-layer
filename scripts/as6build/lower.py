"""Lower the instruction stream to the fixed C++ modules in generated/aot.

Ordering, sharding and exclusions match the reference build exactly:
* base records (the Ghidra listing) and supplemental records (code the
  listing does not disassemble) are merged by (PC << 1 | Thumb);
* every 512 merged records form one module, named native_NNNNN, except
  that modules also close at the reference build's stage cuts (STAGE_CUTS);
* PCs that are literal data inside code are counted but not translated.
Runs with build/venv's Python (capstone 5.0.7 is required by the planners).
"""
import gzip
import hashlib
import importlib.util
import json
import sys
from pathlib import Path

LOWER = Path(__file__).resolve().parent / 'pipeline' / 'lower'
SHARD = 512
# The reference stream was generated in stages that ended after 32 and 4096
# merged records; each stage end closed a module early. Module boundaries
# (and so module names and contents) follow those cut points.
STAGE_CUTS = (32, 4096)
# Literal pool words the listing decodes as instructions (5 + 2 + 5 rows).
DATA_PCS = frozenset(list(range(0x4fbcf8, 0x4fbd0c, 4)) +
                     [0x51939c, 0x5193a0] +
                     [0x406968, 0x50bb48, 0x56855c, 0x65d608, 0x65d60c])


def canonical(value):
    return (json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':')) + '\n').encode()


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def record_key(record):
    mode = record.get('context', {}).get('TMode')
    if mode not in ('0x0', '0x1'):
        raise RuntimeError('instruction has no exact ISA mode')
    return (number(record['address']) << 1) | int(mode == '0x1')


def verify_bytes(record, image):
    start, size = number(record['address']), record['size']
    offset, raw = number(record['source_file_offset']), bytes.fromhex(record['bytes'])
    if (not record.get('original_bytes_match') or size != len(raw) or size not in (2, 4) or
            offset < 0 or image[offset:offset + size] != raw):
        raise RuntimeError('instruction bytes differ from the program: ' + record['address'])


def unit(records, name):
    return {'name': name, 'entry': records[0]['address'], 'instructions': records}


def base_records(stream):
    with gzip.open(stream, 'rb') as reader:
        header = json.loads(reader.readline())
        yield header
        for line in reader:
            record = json.loads(line)
            if record['record_type'] == 'summary':
                return
            if record['record_type'] != 'instruction':
                raise RuntimeError('unexpected stream record')
            yield record


def merged(stream, supplemental):
    records = base_records(stream)
    header = next(records)
    yield header
    current = next(records, None)
    for extra in supplemental:
        while current is not None and record_key(current) < record_key(extra):
            yield current
            current = next(records, None)
        if current is not None and record_key(current) == record_key(extra):
            raise RuntimeError('supplemental record duplicates a listed instruction')
        yield extra
    while current is not None:
        yield current
        current = next(records, None)


def load_lifter():
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('as6_lift', LOWER / 'lift.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def generate(stream, image, supplemental, output, log=print):
    """Write output/native_NNNNN.cpp and output/program.cpp; return module list."""
    lift = load_lifter()
    image = Path(image).read_bytes()
    supplemental = sorted(supplemental, key=record_key)
    output.mkdir(parents=True, exist_ok=True)
    shared = {'fp': None, 'atomic': None}
    modules = []
    header = None

    class ModuleGenerator(lift.Generator):
        def module(self, records, name):
            self.fp_planner, self.atomic_planner = shared['fp'], shared['atomic']
            if self.fp_planner:
                self.fp_planner.plans.clear()
            self.emit('// Generated offline. Fixed native code; no original instruction container.')
            self.emit('#include "../runtime/native_program.hpp"')
            math_line = len(self.lines)
            self.emit('')
            self.emit('using namespace as6aot; namespace {')
            try:
                self.function(unit(records, name))
            finally:
                shared['fp'], shared['atomic'] = self.fp_planner, self.atomic_planner
            if self.fp_plans:
                self.lines[math_line] = '#include "as6_arm_float.h"'
            entry, thumb = number(records[0]['address']), records[0]['context']['TMode'] == '0x1'
            function = f'fn_{entry:x}_m{int(thumb)}'
            keys = [(number(i['address']) << 1) | int(i['context']['TMode'] == '0x1') for i in records]
            if keys != sorted(set(keys)):
                raise RuntimeError('duplicate/unsorted native target')
            self.emit('struct Entry {std::uint64_t key;NativeFunction function;};')
            self.emit('static constexpr Entry entries[] = {')
            for key in keys:
                self.emit(f'  {{0x{key:x}ULL,{function}}},')
            self.emit('}; }')
            self.emit(f'extern "C" as6aot::NativeFunction as6_aot_lookup_{name}(std::uint32_t pc,bool thumb) {{')
            self.emit('  const auto key=(std::uint64_t(pc)<<1)|std::uint64_t(thumb);')
            self.emit('  std::size_t lo=0,hi=sizeof(entries)/sizeof(entries[0]);')
            self.emit('  while(lo<hi){const auto mid=lo+(hi-lo)/2;if(entries[mid].key<key)lo=mid+1;else hi=mid;}')
            self.emit('  return lo<sizeof(entries)/sizeof(entries[0])&&entries[lo].key==key?entries[lo].function:nullptr; }')
            return '\n'.join(self.lines) + '\n', keys

    def document(records, name):
        result = dict(header)
        result.pop('record_type', None)
        result['functions'] = [unit(records, name)]
        result['instruction_count'] = len(records)
        return result

    def flush(records):
        name = 'native_' + str(len(modules)).zfill(5)
        code = [r for r in records if number(r['address']) not in DATA_PCS]
        if not code:
            return
        text, keys = ModuleGenerator(document(code, name)).module(code, name)
        (output / (name + '.cpp')).write_text(text)
        modules.append({'name': name, 'first_key': keys[0], 'last_key': keys[-1]})
        if len(modules) % 200 == 0:
            log('codegen: %d modules' % len(modules))

    records = merged(stream, supplemental)
    header = next(records)
    pending, prior, processed = [], -1, 0
    for record in records:
        key = record_key(record)
        if key <= prior:
            raise RuntimeError('instruction order changed')
        prior = key
        verify_bytes(record, image)
        pending.append(record)
        if len(pending) == SHARD or processed + len(pending) in STAGE_CUTS:
            flush(pending)
            processed += len(pending)
            pending = []
    flush(pending)

    layout = lift.Generator(dict(header, functions=[]))
    write_program(output, modules, layout.register_size, layout.pc_offset)
    log('codegen: %d modules written' % len(modules))
    return modules


ABI_FINGERPRINT = '1c80fe5c2eb7ddf38d5b63ee026a9c4d5714b6379c160631fa80745ec7dbc840'


def write_program(output, modules, register_size, pc_offset):
    lines = ['#include "../runtime/native_program.hpp"', 'using namespace as6aot;',
             '#define AS6_STREAM_API __attribute__((visibility("default")))']
    for module in modules:
        lines.append(f'extern "C" NativeFunction as6_aot_lookup_{module["name"]}(std::uint32_t,bool);')
    lines.append('static constexpr NativeModule modules[] = {')
    for module in modules:
        lines.append(f'  {{{module["first_key"]}ULL,{module["last_key"]}ULL,as6_aot_lookup_{module["name"]}}},')
    lines += ['};', 'extern "C" AS6_STREAM_API const NativeProgram *AS6NativeProgram() {',
              f'  static const NativeProgram program(modules,{len(modules)},{register_size},{pc_offset});',
              '  return &program; }',
              'extern "C" AS6_STREAM_API std::uint32_t as6_stream_context_size(){return sizeof(Context);}',
              f'extern "C" AS6_STREAM_API std::uint32_t as6_stream_register_size(){{return {register_size};}}',
              'extern "C" AS6_STREAM_API bool as6_stream_has(std::uint32_t pc,bool mode){return AS6NativeProgram()->lookup(pc,mode)!=nullptr;}',
              'extern "C" AS6_STREAM_API std::uint32_t as6_stream_execute(Context *ctx,std::uint32_t pc,std::uint32_t mode){return ctx?AS6NativeProgram()->execute(*ctx,pc,mode):InvalidState;}']
    lines.append('extern "C" AS6_STREAM_API const char *as6_stream_abi_fingerprint(){return "' + ABI_FINGERPRINT + '";}')
    (output / 'program.cpp').write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    # python lower.py STREAM IMAGE SUPPLEMENTAL.json[,MORE.json] OUTPUT
    # Each JSON is a recovery document ({"functions": [{"instructions": [...]}]}).
    stream, image, inputs, output = sys.argv[1:5]
    extra = []
    for path in inputs.split(','):
        document = json.loads(Path(path).read_text())
        extra += [i for f in document['functions'] for i in f['instructions']]
    generate(Path(stream), Path(image), extra, Path(output), log=lambda m: print('[buildGame] ' + m, flush=True))
