"""Build-time-only admission of the one verified original undefined trap."""
import hashlib
import json
from pathlib import Path

RECORD_FIELDS = ('address', 'size', 'bytes', 'source_file_offset', 'original_bytes_match',
                 'context', 'pcode', 'fallthrough', 'flows', 'mnemonic', 'asm', 'flow_type')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


class TrapPlanner:
    def __init__(self, document, refused):
        self.refused = refused
        self.document = document
        root = Path(__file__).resolve().parent
        data = (root / 'verified-trap-records.json').read_bytes()
        lock = json.loads((root / 'trap-dependencies.lock.json').read_text())
        if (lock.get('schema_version') != 1 or
                hashlib.sha256(data).hexdigest() != lock.get('registry_sha256') or
                hashlib.sha256(Path(__file__).read_bytes()).hexdigest() != lock.get('planner_sha256') or
                hashlib.sha256((root / 'runtime/aot_support.hpp').read_bytes()).hexdigest() != lock.get('status_header_sha256')):
            raise refused('original trap build dependencies differ from verified lock')
        self.registry = json.loads(data)
        if (self.registry.get('schema_version') != 1 or
                self.registry.get('canonical_fields') != list(RECORD_FIELDS) or
                set(self.registry.get('instructions', {})) != {'0x2ff610:0'} or
                document['image_sha256'] != self.registry.get('image_sha256') or
                hashlib.sha256(canonical(document['registers'])).hexdigest() != self.registry.get('registers_sha256')):
            raise refused('original trap image/register/registry schema mismatch')

    def plan(self, instruction):
        mode = instruction.get('context', {}).get('TMode')
        if mode != '0x0':
            raise self.refused('original trap ISA mode is not in the exact verified registry')
        key = hex(int(instruction['address'], 0)) + ':' + str(int(mode, 0))
        reference = self.registry['instructions'].get(key)
        digest = hashlib.sha256(canonical({f: instruction.get(f) for f in RECORD_FIELDS})).hexdigest()
        if (not reference or digest != reference.get('canonical_sha256') or
                key != '0x2ff610:0' or instruction.get('size') != 4 or
                instruction.get('bytes') != 'fedeffe7' or mode != '0x0'):
            raise self.refused('original trap exact (PC, mode, bytes, raw semantics) record is not verified')
        # The canonical raw P-code includes the exact software_udf immediate,
        # exception PC and computed exception transfer. It is wholly replaced
        # at build time, never iterated or decoded by generated runtime code.
        return {'address': 0x2ff610, 'kind': 'original_undefined_instruction'}
