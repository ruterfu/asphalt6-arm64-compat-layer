"""Build-time-only admission of exact original whole atomic instructions."""
import hashlib
import json
from pathlib import Path

import capstone
from capstone import arm


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


class AtomicPlanner:
    def __init__(self, document, refused):
        self.refused = refused
        root = Path(__file__).resolve().parent
        lock = json.loads((root / 'atomic-dependencies.lock.json').read_text())
        data = (root / 'verified-atomic-records.json').read_bytes()
        if hashlib.sha256(data).hexdigest() != lock['registry_sha256']:
            raise refused('atomic instruction registry differs from frozen dependency')
        if hashlib.sha256((root / 'runtime/arm_atomic.hpp').read_bytes()).hexdigest() != lock['primitive_sha256']:
            raise refused('atomic memory primitive differs from verified dependency')
        self.registry = json.loads(data)
        if document['image_sha256'] != self.registry['image_sha256'] or \
           hashlib.sha256(canonical(document['registers'])).hexdigest() != self.registry['registers_sha256']:
            raise refused('atomic source image/register layout mismatch')
        self.registers = {r['name']: r for r in document['registers'] if r['space'] == 'register'}
        self.decoder = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM | capstone.CS_MODE_LITTLE_ENDIAN)
        self.decoder.detail = True

    def register(self, name, size=4):
        name = {'ip': 'r12', 'sb': 'r9', 'sl': 'r10', 'fp': 'r11',
                'r13': 'sp', 'r14': 'lr', 'r15': 'pc'}.get(name, name)
        node = self.registers.get(name)
        if not node or node['size'] != size or node['bit_length'] != size * 8:
            raise self.refused('unsupported atomic register storage: ' + name)
        return {'space': 'register', 'offset': node['offset'], 'size': size, 'name': name}

    def plan(self, instruction):
        fields = ('address', 'size', 'bytes', 'source_file_offset', 'original_bytes_match',
                  'context', 'pcode', 'fallthrough', 'flows')
        reference = self.registry['instructions'].get(hex(int(instruction['address'], 0)))
        if self.registry.get('schema_version') == 2:
            if self.registry.get('exact_fields') != list(fields):
                raise self.refused('unsupported atomic exact-field registry schema')
            valid = reference == hashlib.sha256(canonical({k: instruction.get(k) for k in fields})).hexdigest()
        elif self.registry.get('schema_version', 1) == 1:
            valid = bool(reference) and all(canonical(instruction.get(k)) == canonical(reference.get(k)) for k in fields)
        else:
            raise self.refused('unsupported atomic exact registry schema')
        if not valid:
            raise self.refused('atomic bytes/raw semantics are not in the exact verified registry')
        raw = bytes.fromhex(instruction['bytes'])
        if instruction['context'].get('TMode') != '0x0' or len(raw) != 4:
            raise self.refused('only exact verified ARM-mode atomic instructions are supported')
        decoded = list(self.decoder.disasm(raw, int(instruction['address'], 0), count=1))
        if len(decoded) != 1 or decoded[0].size != 4:
            raise self.refused('atomic instruction decoding mismatch')
        decoded = decoded[0]
        word = int.from_bytes(raw, 'little')
        condition = word >> 28
        plan = {'address': instruction['address'], 'condition': condition,
                'flags': [self.register(n, 1) for n in ['NG', 'ZR', 'CY', 'OV']]}
        if decoded.id == arm.ARM_INS_DMB:
            if word & 0xfffffff0 != 0xf57ff050 or (word & 15) not in {2, 3, 6, 7, 10, 11, 14, 15}:
                raise self.refused('unsupported original DMB encoding/scope')
            plan.update(kind='barrier', option=word & 15)
        elif decoded.id in {arm.ARM_INS_LDREX, arm.ARM_INS_STREX, arm.ARM_INS_SWP, arm.ARM_INS_SWPB}:
            store = decoded.id == arm.ARM_INS_STREX
            swap = decoded.id in {arm.ARM_INS_SWP, arm.ARM_INS_SWPB}
            expected_types = [arm.ARM_OP_REG] * (2 if store or swap else 1) + [arm.ARM_OP_MEM]
            if condition == 15 or decoded.cc != condition + 1 or decoded.writeback or \
               [o.type for o in decoded.operands] != expected_types:
                raise self.refused('unsupported exclusive condition/operand form')
            registers = [decoded.reg_name(o.reg) for o in decoded.operands[:-1]]
            memory = decoded.operands[-1].mem
            base = decoded.reg_name(memory.base)
            if memory.index or memory.disp or base == 'pc' or 'pc' in registers:
                raise self.refused('unsupported exclusive address/register form')
            if store and registers[0] in {base, registers[1]}:
                raise self.refused('unpredictable exclusive status register overlap')
            if swap and base in registers:
                raise self.refused('unpredictable swap address register overlap')
            if swap and word & 0x0fb00ff0 != 0x01000090:
                raise self.refused('unsupported SWP encoding')
            if store and word & 0x0ff00ff0 != 0x01800f90:
                raise self.refused('unsupported STREX encoding')
            if not store and not swap and word & 0x0ff00fff != 0x01900f9f:
                raise self.refused('unsupported LDREX encoding')
            plan.update(kind='swap' if swap else 'store' if store else 'load',
                        width=1 if decoded.id == arm.ARM_INS_SWPB else 4,
                        base=self.register(base), destination=self.register(registers[0]))
            if store or swap:
                plan['source'] = self.register(registers[1])
        else:
            raise self.refused('atomic instruction needs separately verified whole-instruction semantics')
        if instruction.get('flows') or instruction.get('fallthrough') is None or \
           int(instruction['fallthrough'], 0) != int(instruction['address'], 0) + 4:
            raise self.refused('atomic instruction has unexpected architectural flow')
        return plan
