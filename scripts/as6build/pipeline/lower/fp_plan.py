"""Build-time-only recognition of verified whole ARM floating instructions.

Capstone and the original bytes/p-code registry never enter generated runtime.
Unknown forms or changed original semantics reject generation.
"""
import hashlib
import json
from pathlib import Path

import capstone
from capstone import arm as arm


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()


RECORD_FIELDS = ('address', 'size', 'bytes', 'source_file_offset', 'original_bytes_match',
                 'context', 'pcode', 'fallthrough', 'flows', 'mnemonic', 'asm', 'flow_type')


class FPPlanner:
    def __init__(self, document, refused):
        self.refused = refused
        self.document = document
        root = Path(__file__).resolve().parent
        data = (root / 'verified-fp-records.json').read_bytes()
        lock = json.loads((root / 'fp-dependencies.lock.json').read_text())
        if hashlib.sha256(data).hexdigest() != lock['fp_registry_sha256']:
            raise refused('verified floating instruction registry hash mismatch')
        self.registry = json.loads(data)
        if document['image_sha256'] != self.registry['image_sha256']:
            raise refused('floating source image differs from verified registry')
        if hashlib.sha256(canonical(document['registers'])).hexdigest() != self.registry['registers_sha256']:
            raise refused('floating register/alias layout differs from verified registry')
        self.registers = {r['name']: r for r in document['registers'] if r['space'] == 'register'}
        self.decoder = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM | capstone.CS_MODE_LITTLE_ENDIAN)
        self.decoder.detail = True
        self.plans = []

    def register(self, name, size):
        node = self.registers.get(name)
        if not node or node['size'] != size or node['bit_length'] != size * 8:
            raise self.refused('floating register has an unsupported storage layout: ' + name)
        return {'name': name, 'space': 'register', 'offset': node['offset'], 'size': size}

    def authenticate(self, instruction):
        key = hex(int(instruction['address'], 0))
        if self.registry.get('schema_version') == 2:
            if self.registry.get('canonical_fields') != list(RECORD_FIELDS):
                raise self.refused('hashed floating registry canonical-field schema mismatch')
            mode = int(instruction['context']['TMode'], 0)
            reference = self.registry['instructions'].get(key + ':' + str(mode))
            digest = hashlib.sha256(canonical({f: instruction.get(f) for f in RECORD_FIELDS})).hexdigest()
            if not reference or digest != reference.get('canonical_sha256'):
                raise self.refused('floating exact (PC, mode) record hash is not verified')
        else:
            reference = self.registry['instructions'].get(key)
            fields = RECORD_FIELDS[:9]
            if not reference or any(canonical(instruction.get(f)) != canonical(reference.get(f)) for f in fields):
                raise self.refused('floating instruction bytes/raw semantics are not in the verified registry')
        return key


    def transport_plan(self, instruction, decoded, condition, key):
        name = decoded.insn_name()
        suffix = decoded.mnemonic.split('.', 1)[-1]
        plan = {'address': key, 'condition': condition, 'original_bytes': instruction['bytes'],
                'decoded': decoded.mnemonic + ' ' + decoded.op_str,
                'fpscr': self.register('fpscr', 4), 'pc': self.register('pc', 4),
                'flags': [self.register(n, 1) for n in ('NG', 'ZR', 'CY', 'OV')],
                'fallthrough': int(instruction['fallthrough'], 0), 'function': None,
                'inputs': [], 'destination': None}
        if name == 'fmstat':
            regs = [decoded.reg_name(op.reg) for op in decoded.operands if op.type == arm.ARM_OP_REG]
            if condition != 14 or regs != ['apsr_nzcv', 'fpscr']:
                raise self.refused('only verified VMRS APSR_nzcv,FPSCR form is supported')
            plan['kind'] = 'fpscr_to_apsr'
        elif name in ('vmov', 'fconsts', 'fconstd') and suffix in ('f32', 'f64'):
            if condition == 15 or len(decoded.operands) != 2 or decoded.operands[0].type != arm.ARM_OP_REG:
                raise self.refused('unsupported scalar VMOV transport form')
            destination = decoded.reg_name(decoded.operands[0].reg)
            prefix, size = ('s', 4) if suffix == 'f32' else ('d', 8)
            if not destination.startswith(prefix) or not destination[1:].isdigit():
                raise self.refused('scalar VMOV destination precision mismatch')
            plan['kind'] = 'bit_copy'
            plan['destination'] = self.register(destination, size)
            source = decoded.operands[1]
            if source.type == arm.ARM_OP_REG:
                source_name = decoded.reg_name(source.reg)
                if not source_name.startswith(prefix) or not source_name[1:].isdigit():
                    raise self.refused('scalar VMOV source precision mismatch')
                plan['inputs'] = [self.register(source_name, size)]
            elif source.type == arm.ARM_OP_FP:
                # VFPExpandImm, using only encoded integers (no host float).
                raw = int.from_bytes(bytes.fromhex(instruction['bytes']), 'little')
                imm8 = ((raw >> 16) & 15) << 4 | (raw & 15)
                exponent_bits, fraction_bits = (8, 23) if size == 4 else (11, 52)
                b6 = (imm8 >> 6) & 1
                exponent = ((1 - b6) << (exponent_bits - 1)) | (((1 << (exponent_bits - 3)) - 1) * b6 << 2) | ((imm8 >> 4) & 3)
                bits = ((imm8 >> 7) << (size * 8 - 1)) | (exponent << fraction_bits) | ((imm8 & 15) << (fraction_bits - 4))
                plan['inputs'] = [{'space': 'const', 'offset': hex(bits), 'size': size}]
            else:
                raise self.refused('unsupported scalar VMOV operand')
        else:
            return None
        if any(op['name'].startswith('FLOAT') or op['name'] in ('CALLOTHER', 'LOAD', 'STORE', 'TRUNC', 'INT2FLOAT') for op in instruction['pcode']):
            raise self.refused('state/transport source contains arithmetic or side effects')
        self.plans.append(plan)
        return plan


    def plan(self, instruction):
        raw = bytes.fromhex(instruction['bytes'])
        decoded = list(self.decoder.disasm(raw, int(instruction['address'], 0), count=1))
        ids = {arm.ARM_INS_VADD, arm.ARM_INS_VSUB, arm.ARM_INS_VMUL, arm.ARM_INS_VDIV,
               arm.ARM_INS_VSQRT, arm.ARM_INS_VNEG, arm.ARM_INS_VABS,
               arm.ARM_INS_VCMP, arm.ARM_INS_VCMPE, arm.ARM_INS_VCVT,
               arm.ARM_INS_VMLA, arm.ARM_INS_VMLS, arm.ARM_INS_VNMLA,
               arm.ARM_INS_VNMLS, arm.ARM_INS_VNMUL}
        has_fp = any(op['name'].startswith('FLOAT') or op['name'] in {'TRUNC', 'INT2FLOAT'} or
                     (op.get('userop_name') or '').startswith(('FloatVector', 'VectorSignedToFloat', 'VectorUnsignedToFloat'))
                     for op in instruction['pcode'])
        transport = bool(decoded and (decoded[0].insn_name() == 'fmstat' or
                         decoded[0].insn_name() in {'vmov', 'fconsts', 'fconstd'} and
                         decoded[0].mnemonic.split('.', 1)[-1] in {'f32', 'f64'}))
        if not has_fp and not transport and (not decoded or decoded[0].id not in ids):
            if instruction.get('mnemonic', '').lower().startswith(('vmrs', 'vmsr')):
                raise self.refused('unverified FPSCR system transport is unsupported')
            if any(kind in instruction.get('mnemonic', '').lower() for kind in ('.f16', '.f32', '.f64')):
                raise self.refused('unsupported whole floating instruction form or missing raw semantics')
            return None
        if instruction['context'].get('TMode') != '0x0' or len(raw) != 4 or len(decoded) != 1 or decoded[0].size != 4:
            raise self.refused('floating candidate supports verified ARM-mode instructions only')
        key = self.authenticate(instruction)
        decoded = decoded[0]
        condition = int.from_bytes(raw, 'little') >> 28
        if condition != 15 and decoded.cc != condition + 1:
            raise self.refused('decoded ARM condition disagrees with original encoding')
        if instruction['fallthrough'] is None or int(instruction['fallthrough'], 0) != int(instruction['address'], 0) + 4 or instruction['flows']:
            raise self.refused('floating instruction has unexpected architectural flow')
        transport_result = self.transport_plan(instruction, decoded, condition, key) if transport else None
        if transport_result:
            return transport_result
        compare_zero = (decoded.id in {arm.ARM_INS_VCMP, arm.ARM_INS_VCMPE} and len(decoded.operands) == 2 and
                        decoded.operands[0].type == arm.ARM_OP_REG and decoded.operands[1].type == arm.ARM_OP_IMM and decoded.operands[1].imm == 0)
        if decoded.id not in ids or (not compare_zero and any(op.type != arm.ARM_OP_REG for op in decoded.operands)):
            raise self.refused('unsupported whole floating instruction form')
        regs = [decoded.reg_name(op.reg) for op in decoded.operands if op.type == arm.ARM_OP_REG]
        kinds = [name[:1] for name in regs]
        suffix = decoded.mnemonic.split('.', 1)[1] if '.' in decoded.mnemonic else ''
        condition = int.from_bytes(raw, 'little') >> 28
        if condition != 15 and decoded.cc != condition + 1:
            raise self.refused('decoded ARM condition disagrees with original encoding')
        binary = {arm.ARM_INS_VADD: 'add', arm.ARM_INS_VSUB: 'sub', arm.ARM_INS_VMUL: 'mul', arm.ARM_INS_VDIV: 'div'}
        unary = {arm.ARM_INS_VSQRT: 'sqrt', arm.ARM_INS_VNEG: 'neg', arm.ARM_INS_VABS: 'abs'}
        destination, inputs, function = None, [], None
        if decoded.id in binary and len(regs) == 3:
            if suffix == 'f32' and kinds == ['d', 'd', 'd'] and decoded.id in {arm.ARM_INS_VADD, arm.ARM_INS_VSUB, arm.ARM_INS_VMUL}:
                if condition != 15:
                    raise self.refused('NEON candidate requires its original unconditional encoding')
                function = 'as6_neon_' + binary[decoded.id] + '_2f32'
            elif condition != 15 and ((suffix == 'f64' and kinds == ['d'] * 3) or (suffix == 'f32' and kinds == ['s'] * 3)):
                if suffix == 'f32' and decoded.id != arm.ARM_INS_VDIV:
                    raise self.refused('scalar f32 add/sub/mul remain unsupported')
                function = 'as6_vfp_' + binary[decoded.id] + '_' + suffix
            destination, inputs = regs[0], regs[1:]
        elif decoded.id in unary and len(regs) == 2 and condition != 15 and suffix in {'f32', 'f64'}:
            if kinds == [('s' if suffix == 'f32' else 'd')] * 2:
                function = 'as6_vfp_' + unary[decoded.id] + '_' + suffix
            destination, inputs = regs[0], regs[1:]
        elif decoded.id in {arm.ARM_INS_VCMP, arm.ARM_INS_VCMPE} and (len(regs) == 2 or compare_zero) and condition != 15 and suffix in {'f32', 'f64'}:
            if kinds == [('s' if suffix == 'f32' else 'd')] * (1 if compare_zero else 2):
                function = 'as6_vfp_' + ('cmpe' if decoded.id == arm.ARM_INS_VCMPE else 'cmp') + '_' + suffix
            inputs = regs
        elif decoded.id == arm.ARM_INS_VCVT and len(regs) == 2 and condition != 15:
            conversions = {'f64.f32': ('f32_to_f64', ['d', 's']), 'f32.f64': ('f64_to_f32', ['s', 'd']),
                           'f32.s32': ('s32_to_f32', ['s', 's']), 'f32.u32': ('u32_to_f32', ['s', 's']),
                           's32.f32': ('f32_to_s32_rtz', ['s', 's']),
                           'f64.s32': ('s32_to_f64', ['d', 's']), 'f64.u32': ('u32_to_f64', ['d', 's']),
                           's32.f64': ('f64_to_s32_rtz', ['s', 'd']), 'u32.f32': ('f32_to_u32_rtz', ['s', 's']),
                           'u32.f64': ('f64_to_u32_rtz', ['s', 'd'])}
            if suffix in conversions and kinds == conversions[suffix][1]:
                function = 'as6_vfp_' + conversions[suffix][0]
            destination, inputs = regs[0], regs[1:]
        elif decoded.id in {arm.ARM_INS_VMLA, arm.ARM_INS_VMLS, arm.ARM_INS_VNMLA,
                            arm.ARM_INS_VNMLS, arm.ARM_INS_VNMUL} and len(regs) == 3 and condition != 15:
            forms = {(arm.ARM_INS_VMLA, 'f64'): 'mla_f64',
                     (arm.ARM_INS_VMLS, 'f32'): 'mls_f32', (arm.ARM_INS_VMLS, 'f64'): 'mls_f64',
                     (arm.ARM_INS_VNMLA, 'f32'): 'nmla_f32', (arm.ARM_INS_VNMLS, 'f64'): 'nmls_f64',
                     (arm.ARM_INS_VNMUL, 'f32'): 'nmul_f32'}
            form = forms.get((decoded.id, suffix))
            if form and kinds == [('s' if suffix == 'f32' else 'd')] * 3:
                function = 'as6_vfp_' + form
                destination = regs[0]
                # The old destination is an ordered input to non-fused MACs.
                # The owned helper performs both rounding stages and flags.
                inputs = regs[1:] if decoded.id == arm.ARM_INS_VNMUL else regs
        if not function:
            raise self.refused('unsupported whole floating instruction operands/precision')
        if instruction['fallthrough'] is None or int(instruction['fallthrough'], 0) != int(instruction['address'], 0) + 4 or instruction['flows']:
            raise self.refused('floating instruction has unexpected architectural flow')
        convert_reg = lambda name: self.register(name, 4 if name.startswith('s') else 8)
        plan = {'address': key, 'function': function, 'condition': condition, 'original_bytes': raw.hex(),
                'decoded': decoded.mnemonic + ' ' + decoded.op_str,
                'destination': convert_reg(destination) if destination else None,
                'inputs': [convert_reg(name) for name in inputs] + ([{'space': 'const', 'offset': '0x0', 'size': 4 if suffix == 'f32' else 8}] if compare_zero else []), 'fpscr': self.register('fpscr', 4),
                'pc': self.register('pc', 4), 'flags': [self.register(name, 1) for name in ['NG', 'ZR', 'CY', 'OV']],
                'fallthrough': int(instruction['fallthrough'], 0)}
        self.plans.append(plan)
        return plan
