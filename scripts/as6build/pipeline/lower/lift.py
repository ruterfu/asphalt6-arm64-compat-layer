#!/usr/bin/env python3
"""Offline raw-SLEIGH-pcode to fixed C++ control flow; never an interpreter.

Unsupported operations and non-dominating temporary reads reject generation.
This first stage translates selected exact functions, not a complete game.
"""
from __future__ import annotations
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path


class Refused(ValueError):
    pass


def number(value):
    return int(value, 0) if isinstance(value, str) else int(value)


def span(node):
    start = number(node['offset'])
    return set(range(start, start + node['size']))


def signed_constant(node):
    bits = node['size'] * 8
    value = number(node['offset']) & ((1 << bits) - 1)
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def arm32_address(value, length=1):
    address = number(value)
    if length <= 0 or not 0 <= address < 1 << 32 or address + length > 1 << 32:
        raise Refused('address interval is outside ARM32 RAM')
    return address


def verify_temporary_definitions(instruction):
    """Definite assignment on the micro-op CFG, independently per instruction."""
    ops = instruction['pcode']
    count = len(ops)
    edges = {}
    for index, op in enumerate(ops):
        name = op['name']
        successors = [] if name in {'RETURN', 'BRANCHIND', 'CALLIND', 'CALL'} else [index + 1]
        if name in {'BRANCH', 'CBRANCH'}:
            destination = op['inputs'][0]
            target = index + signed_constant(destination) if destination['space'] == 'const' else None
            if target is not None and not 0 <= target <= count:
                raise Refused(f"invalid micro-op branch at {instruction['address']}:{index}")
            if target is not None and target <= index:
                raise Refused(f"micro-op backedge needs explicit bounded lowering at {instruction['address']}:{index}")
            successors = ([target] if target is not None else []) + ([index + 1] if name == 'CBRANCH' else [])
        edges[index] = successors
    incoming = {0: set()}
    work = [0] if ops else []
    while work:
        index = work.pop()
        if index == count:
            continue
        available = incoming[index].copy()
        output = ops[index].get('output')
        if output and output['space'] == 'unique':
            available |= span(output)
        for successor in edges[index]:
            updated = incoming[successor] & available if successor in incoming else available.copy()
            if successor not in incoming or updated != incoming[successor]:
                incoming[successor] = updated
                work.append(successor)
    for index, op in enumerate(ops):
        if index not in incoming:
            continue
        for node in op['inputs']:
            if node['space'] == 'unique' and not span(node) <= incoming[index]:
                raise Refused(f"temporary read without dominating definition at {instruction['address']}:{index}")


class Generator:
    def __init__(self, document):
        self.doc = document
        if document.get('schema_version') != 1 or document.get('byte_order') != 'little':
            raise Refused('unsupported export schema/byte order')
        if document.get('pcode_source') != 'Instruction.getPcode()':
            raise Refused('raw instruction pcode is required')
        if not document.get('lang', '').startswith('ARM:LE:32:'):
            raise Refused('an explicit little-endian ARM32 source language is required')
        self.spaces = {number(s['id']): s for s in document['address_spaces']}
        ram_spaces = [space for space in self.spaces.values() if space['name'] == 'ram']
        if len(ram_spaces) != 1 or ram_spaces[0].get('size_bits') != 32 or ram_spaces[0].get('addressable_unit_size') != 1:
            raise Refused('RAM must be a 32-bit byte-addressed space')
        if any(space.get('addressable_unit_size') != 1 for space in self.spaces.values()
               if space['name'] in {'register', 'unique', 'const'}):
            raise Refused('non-byte varnode storage is unsupported')
        self.userops = {u['id']: u['name'] for u in document['userops']}
        self.register_size = max(number(r['offset']) + r['size'] for r in document['registers']
                                 if r['space'] == 'register')
        pc_registers = [r for r in document['registers'] if r['name'] == 'pc' and
                        r['space'] == 'register' and r['size'] == 4 and r['bit_length'] == 32]
        if len(pc_registers) != 1:
            raise Refused('one exact architectural ARM32 PC register is required')
        self.pc_offset = number(pc_registers[0]['offset'])
        self.lines = []
        self.unique = {}
        self.addresses = set()
        self.address_modes = {}
        self.trap_planner = None
        self.trap_plans = {}
        self.fp_planner = None
        self.fp_plans = {}
        self.atomic_planner = None
        self.atomic_plans = {}
        # Build-time recognition only. A single ARM load/store data abort does
        # not commit its base-register writeback, even when raw SLEIGH P-code
        # assigns that base before the faulting memory operation.
        self.writeback_offset = None
        self.writeback_offsets = {}
        decoder = None
        aliases = {'r13': 'sp', 'r14': 'lr', 'r15': 'pc', 'ip': 'r12',
                   'sb': 'r9', 'sl': 'r10', 'fp': 'r11'}
        registers = {r['name']: r for r in document['registers'] if r['space'] == 'register'}
        for function in document['functions']:
            for instruction in function['instructions']:
                if instruction['context'].get('TMode') != '0x0':
                    continue
                raw = bytes.fromhex(instruction['bytes'])
                if len(raw) != 4:
                    continue
                word = int.from_bytes(raw, 'little')
                single = (word & 0x0c000000) == 0x04000000
                extra = (word & 0x0e000090) == 0x00000090 and bool(word & 0x60)
                if word >> 28 == 15 or not (single or extra) or ((word >> 24) & 1 and not (word >> 21) & 1):
                    continue
                # Keep plain integer-only builds free of a new dependency.
                # Capstone is needed only to confirm a raw WB candidate.
                if decoder is None:
                    import capstone
                    from capstone import arm
                    decoder = capstone.Cs(capstone.CS_ARCH_ARM, capstone.CS_MODE_ARM)
                    decoder.detail = True
                    loads = {arm.ARM_INS_LDR, arm.ARM_INS_LDRB, arm.ARM_INS_LDRH,
                             arm.ARM_INS_LDRSB, arm.ARM_INS_LDRSH}
                    stores = {arm.ARM_INS_STR, arm.ARM_INS_STRB, arm.ARM_INS_STRH}
                decoded = list(decoder.disasm(raw, number(instruction['address']), count=1))
                if not decoded or not decoded[0].writeback or decoded[0].id not in loads | stores:
                    continue
                decoded = decoded[0]
                memory = [o for o in decoded.operands if o.type == arm.ARM_OP_MEM]
                if len(memory) != 1:
                    raise Refused('single-transfer writeback has unexpected addressing')
                base = aliases.get(decoded.reg_name(memory[0].mem.base), decoded.reg_name(memory[0].mem.base))
                destination = aliases.get(decoded.reg_name(decoded.operands[0].reg), decoded.reg_name(decoded.operands[0].reg))
                if base == 'pc' or base not in registers or registers[base]['size'] != 4 or base == destination:
                    raise Refused('unpredictable single-transfer writeback base/operand overlap')
                self.writeback_offsets[(number(instruction['address']), 0)] = number(registers[base]['offset'])

    def emit(self, line=''):
        if self.writeback_offset is not None and 'if (ctx.status != Returned) return ctx.status;' in line:
            line = line.replace('if (ctx.status != Returned) return ctx.status;',
                f'if (ctx.status != Returned) {{ if (ctx.status == MemoryFault) write_bytes(ctx.registers, {self.writeback_offset}, 4, writeback_base); return ctx.status; }}')
        self.lines.append(line)

    def check_node(self, node):
        if not 1 <= node['size'] <= 16:
            raise Refused(f"unsupported value width: {node}")
        if node['space'] not in {'const', 'unique', 'register', 'ram'}:
            raise Refused(f"unsupported data address space: {node['space']}")
        offset = number(node['offset'])
        space = next(s for s in self.spaces.values() if s['name'] == node['space'])
        if not 0 <= offset < 1 << space['size_bits']:
            raise Refused('varnode offset is outside its declared address space')
        if node['space'] == 'const' and offset >= 1 << (8 * node['size']):
            raise Refused('constant exceeds its declared value width')
        if node['space'] != 'const' and offset + node['size'] > 1 << space['size_bits']:
            raise Refused('varnode interval exceeds its declared address space')
        if node['space'] == 'register' and number(node['offset']) + node['size'] > self.register_size:
            raise Refused('register outside exported layout')

    def read(self, node):
        self.check_node(node)
        offset, size, space = number(node['offset']), node['size'], node['space']
        if space == 'const':
            value = offset & ((1 << (8 * size)) - 1)
            return f'(Word(0x{value >> 64:x}ULL) << 64 | Word(0x{value & ((1<<64)-1):x}ULL))'
        if space == 'register':
            return f'read_bytes(ctx.registers, {offset}, {size})'
        if space == 'unique':
            return f'read_bytes(unique, {self.unique[offset]}, {size})'
        raise Refused('direct RAM data varnodes require explicit lowering; use verified LOAD')

    def write(self, node, expression='value'):
        self.check_node(node)
        offset, size, space = number(node['offset']), node['size'], node['space']
        if space == 'register':
            self.emit(f'    write_bytes(ctx.registers, {offset}, {size}, {expression});')
        elif space == 'unique':
            self.emit(f'    write_bytes(unique, {self.unique[offset]}, {size}, {expression});')
        elif space == 'ram':
            raise Refused('direct RAM data outputs require explicit lowering; use verified STORE')
        else:
            raise Refused('constant output is forbidden')

    def branch(self, node, index, instruction):
        if node['space'] == 'const':
            return f'goto op_{number(instruction["address"]):x}_{index + signed_constant(node)};'
        if node['space'] != 'ram':
            raise Refused('direct branch must contain an address or micro-op displacement')
        self.check_node(node)
        target = arm32_address(node['offset'])
        transfer = f'ctx.next_pc = 0x{target:x}u; write_bytes(ctx.registers, {self.pc_offset}, 4, Word(ctx.next_pc)); '
        if target in self.addresses:
            mode = str(self.address_modes[target]).lower()
            return f'{{ {transfer}if (ctx.isa_thumb == {mode}) goto ins_{target:x}; return legacy ? UnresolvedTarget : Dispatch; }}'
        return f'{{ {transfer}return legacy ? UnresolvedTarget : Dispatch; }}'

    def expression(self, op):
        name, inputs = op['name'], op['inputs']
        values = [self.read(node) for node in inputs]
        left = values[0] if values else None
        right = values[1] if len(values) > 1 else None
        width = inputs[0]['size'] if inputs else None
        output_size = op['output']['size']
        unary = {'COPY': left, 'INT_ZEXT': left, 'INT_NEGATE': f'~({left})',
                 'INT_2COMP': f'-({left})', 'BOOL_NEGATE': f'!({left})'}
        if name in unary:
            return unary[name]
        binary = {'INT_ADD': '+', 'INT_SUB': '-', 'INT_MULT': '*', 'INT_XOR': '^',
                  'INT_AND': '&', 'INT_OR': '|', 'INT_EQUAL': '==', 'INT_NOTEQUAL': '!=',
                  'INT_LESS': '<', 'INT_LESSEQUAL': '<=', 'BOOL_AND': '&&', 'BOOL_OR': '||'}
        if name in binary:
            return f'(({left}) {binary[name]} ({right}))'
        if name == 'BOOL_XOR':
            return f'(bool({left}) != bool({right}))'
        helpers = {'INT_LEFT': 'shift_left', 'INT_RIGHT': 'shift_right',
                   'INT_SRIGHT': 'shift_signed_right', 'INT_CARRY': 'carry',
                   'INT_SCARRY': 'signed_carry', 'INT_SBORROW': 'signed_borrow',
                   'INT_SLESS': 'signed_less'}
        if name in helpers:
            return f'{helpers[name]}({left}, {right}, {width})'
        if name == 'INT_SLESSEQUAL':
            return f'!signed_less({right}, {left}, {width})'
        if name == 'INT_SEXT':
            return f'sign_extend({left}, {width}, {output_size})'
        if name == 'SUBPIECE':
            return f'shift_right({left}, ({right}) * 8, {width})'
        if name == 'PIECE':
            if inputs[0]['size'] + inputs[1]['size'] > 16:
                raise Refused('PIECE wider than 128 bits')
            return f'(({left}) << {inputs[1]["size"] * 8} | ({right}))'
        if name in {'INT_SDIV', 'INT_SREM'}:
            return f'signed_divide(ctx, {left}, {right}, {width}, {str(name == "INT_SREM").lower()})'
        if name in {'POPCOUNT', 'LZCOUNT'}:
            helper = 'population_count' if name == 'POPCOUNT' else 'leading_zero_count'
            return f'{helper}({left}, {width})'
        # Unsigned division must not execute a native undefined division by 0.
        if name in {'INT_DIV', 'INT_REM'}:
            symbol = '/' if name == 'INT_DIV' else '%'
            self.emit(f'    if (({right}) == 0) return ArithmeticFault;')
            return f'(({left}) {symbol} ({right}))'
        raise Refused(f'unsupported pcode operation: {name}')

    def operation(self, op, index, instruction):
        name, inputs = op['name'], op['inputs']
        if name in {'BRANCH', 'CBRANCH'}:
            branch = self.branch(inputs[0], index, instruction)
            self.emit(f'    if ({self.read(inputs[1])}) {branch}' if name == 'CBRANCH' else f'    {branch}')
            return
        if name in {'RETURN', 'BRANCHIND', 'CALLIND'}:
            self.emit(f'    value = {self.read(inputs[0])};')
            self.emit('    if (ctx.status != Returned) return ctx.status;')
            self.emit('    ctx.next_pc = std::uint32_t(value);')
            self.emit(f'    write_bytes(ctx.registers, {self.pc_offset}, 4, Word(ctx.next_pc));')
            self.emit(f'    return legacy ? {"Returned" if name == "RETURN" else "UnresolvedTarget"} : Dispatch;')
            return
        if name == 'CALL':
            if inputs[0]['space'] != 'ram':
                raise Refused('CALL requires an original RAM target, not a micro-op jump')
            self.emit(f'    {self.branch(inputs[0], index, instruction)}')
            return
        if name == 'CALLOTHER':
            userop = number(inputs[0]['offset'])
            if self.userops.get(userop) != 'setISAMode' or op.get('userop_name') != 'setISAMode' or len(inputs) != 2 or op.get('output'):
                raise Refused(f'unsupported user operation: {op.get("userop_name")}')
            # ARM.sinc SetThumbMode and Ghidra's ArmPcodeUseropLibraryFactory:
            # override the execution context from TB; this is not a no-op.
            self.emit(f'    ctx.isa_thumb = bool({self.read(inputs[1])});')
            return
        if name in {'LOAD', 'STORE'}:
            space = self.spaces.get(number(inputs[0]['offset']))
            if inputs[0]['space'] != 'const' or not space or space['name'] != 'ram':
                raise Refused('LOAD/STORE requires verified RAM address-space ID')
            self.emit(f'    address = {self.read(inputs[1])};')
            if name == 'LOAD':
                self.emit(f'    value = load(ctx, address, {op["output"]["size"]});')
                self.emit('    if (ctx.status != Returned) return ctx.status;')
                self.write(op['output'])
            else:
                self.emit(f'    value = {self.read(inputs[2])};')
                self.emit('    if (ctx.status != Returned) return ctx.status;')
                self.emit(f'    store(ctx, address, {inputs[2]["size"]}, value);')
                self.emit('    if (ctx.status != Returned) return ctx.status;')
            return
        if not op.get('output'):
            raise Refused(f'operation lacks required output: {name}')
        self.emit(f'    value = {self.expression(op)};')
        self.emit('    if (ctx.status != Returned) return ctx.status;')
        self.write(op['output'])

    def validate_operation(self, op):
        name, inputs, output = op['name'], op['inputs'], op.get('output')
        for node in inputs + ([output] if output else []):
            self.check_node(node)
        unary_same = {'COPY', 'INT_2COMP', 'INT_NEGATE'}
        binary_same = {'INT_ADD', 'INT_SUB', 'INT_MULT', 'INT_XOR', 'INT_AND', 'INT_OR',
                       'INT_DIV', 'INT_SDIV', 'INT_REM', 'INT_SREM'}
        comparisons = {'INT_EQUAL', 'INT_NOTEQUAL', 'INT_LESS', 'INT_LESSEQUAL',
                       'INT_SLESS', 'INT_SLESSEQUAL', 'INT_CARRY', 'INT_SCARRY', 'INT_SBORROW'}
        shifts = {'INT_LEFT', 'INT_RIGHT', 'INT_SRIGHT'}
        boolean = {'BOOL_AND', 'BOOL_OR', 'BOOL_XOR', 'BOOL_NEGATE'}
        if name in unary_same | binary_same | comparisons | shifts | boolean | {
                'INT_ZEXT', 'INT_SEXT', 'PIECE', 'SUBPIECE', 'POPCOUNT', 'LZCOUNT'}:
            arity = 1 if name in unary_same | {'BOOL_NEGATE', 'INT_ZEXT', 'INT_SEXT', 'POPCOUNT', 'LZCOUNT'} else 2
            if len(inputs) != arity or not output:
                raise Refused(f'invalid arity/output for {name}')
            widths = [node['size'] for node in inputs]
            out = output['size']
            if name in unary_same | binary_same and (len(set(widths + [out])) != 1):
                raise Refused(f'inconsistent integer widths for {name}')
            if name in comparisons and (widths[0] != widths[1] or out != 1):
                raise Refused(f'invalid comparison widths for {name}')
            if name in shifts and widths[0] != out:
                raise Refused('shift output width differs from value width')
            if name in boolean and any(size != 1 for size in widths + [out]):
                raise Refused('boolean varnodes must be one byte')
            if name in {'INT_ZEXT', 'INT_SEXT'} and widths[0] > out:
                raise Refused('integer extension may not truncate')
            if name == 'PIECE' and sum(widths) != out:
                raise Refused('PIECE output must match concatenated width')
            if name == 'SUBPIECE' and (inputs[1]['space'] != 'const' or
                    number(inputs[1]['offset']) + out > widths[0]):
                raise Refused('SUBPIECE must select an in-bounds constant byte range')
            return
        if name in {'BRANCH', 'CBRANCH', 'CALL', 'CALLIND', 'BRANCHIND', 'RETURN'}:
            if output or len(inputs) != (2 if name == 'CBRANCH' else 1):
                raise Refused(f'invalid control-flow shape for {name}')
            if name in {'BRANCH', 'CBRANCH'} and inputs[0]['space'] not in {'const', 'ram'}:
                raise Refused('direct control-flow target has the wrong space')
            if name == 'CALL' and inputs[0]['space'] != 'ram':
                raise Refused('CALL cannot be a micro-op jump')
            micro_target = name in {'BRANCH', 'CBRANCH'} and inputs[0]['space'] == 'const'
            if not micro_target and inputs[0]['size'] != 4:
                raise Refused('ARM32 control-flow target must be 32 bits')
            if name == 'CBRANCH' and inputs[1]['size'] != 1:
                raise Refused('branch condition must be one byte')
            return
        if name in {'LOAD', 'STORE'}:
            if len(inputs) != (2 if name == 'LOAD' else 3) or (bool(output) != (name == 'LOAD')):
                raise Refused(f'invalid memory operation shape for {name}')
            if inputs[0]['space'] != 'const' or inputs[1]['size'] != 4:
                raise Refused('memory access needs a constant space selector and ARM32 address')
            return
        if name == 'CALLOTHER':
            if len(inputs) != 2 or output or inputs[0]['space'] != 'const' or inputs[1]['size'] != 1:
                raise Refused('only explicit Boolean setISAMode is supported')
            return
        raise Refused(f'unsupported operation: {name}')

    def floating_plan(self, instruction):
        mnemonic = instruction.get('mnemonic', '').lower()
        surface = any(kind in mnemonic for kind in ('.f16', '.f32', '.f64'))
        bit_transport = mnemonic.startswith(('vmov', 'vldr', 'vstr', 'vldm', 'vstm', 'vpush', 'vpop'))
        floating = any(op['name'].startswith('FLOAT') or op['name'] in {'TRUNC', 'INT2FLOAT'} or
                       (op.get('userop_name') or '').startswith(
                           ('FloatVector', 'VectorSignedToFloat', 'VectorUnsignedToFloat'))
                       for op in instruction['pcode'])
        scalar_transport = mnemonic.startswith('vmov') and any(t in mnemonic for t in ('.f32', '.f64'))
        state_transport = mnemonic.startswith(('vmrs', 'vmsr'))
        raw = bytes.fromhex(instruction['bytes'])
        # Actual VFP coprocessor bytes remain owned even if a caller changes
        # the untrusted mnemonic to hide the transport from this router.
        scalar_vfp_encoding = (instruction.get('context', {}).get('TMode') == '0x0' and len(raw) == 4 and
                               int.from_bytes(raw, 'little') & 0x0f000e00 == 0x0e000a00)
        if not floating and not (surface and not bit_transport) and not scalar_transport and not state_transport and not scalar_vfp_encoding:
            return None
        if self.fp_planner is None:
            path = Path(__file__).resolve().with_name('fp_plan.py')
            spec = importlib.util.spec_from_file_location('as6_build_time_fp_plan', path)
            module = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(module)
            except ModuleNotFoundError as error:
                raise Refused(f'unsupported floating build environment; missing {error.name}') from error
            self.fp_planner = module.FPPlanner(self.doc, Refused)
        return self.fp_planner.plan(instruction)


    def original_trap_plan(self, instruction):
        raw = bytes.fromhex(instruction['bytes'])
        encoded = (instruction.get('context', {}).get('TMode') == '0x0' and len(raw) == 4 and
                   int.from_bytes(raw, 'little') & 0xfff000f0 == 0xe7f000f0)
        surface = instruction.get('mnemonic', '').lower().startswith('udf') or any(
            op.get('userop_name') == 'software_udf' or op.get('userop_id') == 17
            for op in instruction['pcode'])
        if not encoded and not surface:
            return None
        if self.trap_planner is None:
            path = Path(__file__).resolve().with_name('trap_plan.py')
            spec = importlib.util.spec_from_file_location('as6_build_time_trap_plan', path)
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            self.trap_planner = module.TrapPlanner(self.doc, Refused)
        return self.trap_planner.plan(instruction)

    def atomic_plan(self, instruction):
        mnemonic = instruction.get('mnemonic', '').strip().lower()
        userops = {op.get('userop_name') for op in instruction['pcode']}
        raw = bytes.fromhex(instruction['bytes'])
        word = int.from_bytes(raw, 'little')
        # Build-time admission also recognizes ARMv7 exclusive/barrier bits.
        # Removing the mnemonic cannot disguise LDREX's deficient LOAD-only
        # raw P-code as an ordinary integer memory access.
        encoded = instruction.get('context', {}).get('TMode') == '0x0' and len(raw) == 4 and (
            (word & 0x0f900fff) == 0x01900f9f or
            (word & 0x0f900ff0) == 0x01800f90 or
            (word & 0x0fb00ff0) == 0x01000090 or
            (word & 0xfffffff0) in {0xf57ff010, 0xf57ff040, 0xf57ff050, 0xf57ff060})
        if not encoded and not mnemonic.startswith(('ldrex', 'strex', 'swp', 'ldaex', 'stlex', 'ldax', 'stlx', 'clrex', 'dmb', 'dsb', 'isb')) and not \
           userops.intersection({'hasExclusiveAccess', 'setExclusiveAccess', 'clearExclusiveAccess',
                                'DataMemoryBarrier', 'DataSynchronizationBarrier', 'InstructionSynchronizationBarrier'}):
            return None
        if self.atomic_planner is None:
            path = Path(__file__).resolve().with_name('atomic_plan.py')
            spec = importlib.util.spec_from_file_location('as6_build_time_atomic_plan', path)
            module = importlib.util.module_from_spec(spec)
            try:
                spec.loader.exec_module(module)
            except ModuleNotFoundError as error:
                raise Refused(f'unsupported atomic build environment; missing {error.name}') from error
            self.atomic_planner = module.AtomicPlanner(self.doc, Refused)
        return self.atomic_planner.plan(instruction)

    def emit_atomic_instruction(self, plan):
        self.emit('    {')
        flags = ', '.join(f'bool({self.read(node)})' for node in plan['flags'])
        self.emit(f'      if (arm_condition_passed({plan["condition"]}, {flags})) {{')
        if plan['kind'] == 'barrier':
            self.emit(f'        memory_barrier(ctx, {plan["option"]});')
            self.emit('        if (ctx.status != Returned) return ctx.status;')
        else:
            self.emit(f'        address = {self.read(plan["base"])};')
            if plan['kind'] == 'load':
                self.emit(f'        value = load_exclusive(ctx, std::uint32_t(address), {plan["width"]});')
            else:
                self.emit(f'        const auto atomic_value = std::uint64_t({self.read(plan["source"])});')
                helper = 'atomic_swap' if plan['kind'] == 'swap' else 'store_exclusive'
                self.emit(f'        value = {helper}(ctx, std::uint32_t(address), {plan["width"]}, atomic_value);')
            self.emit('        if (ctx.status != Returned) return ctx.status;')
            self.write(plan['destination'])
        self.emit('      }')
        self.emit('    }')

    def emit_floating_instruction(self, plan):
        self.emit('    {')
        flags = ', '.join(f'bool({self.read(node)})' for node in plan['flags'])
        self.emit(f'      if (arm_condition_passed({plan["condition"]}, {flags})) {{')
        if plan.get('kind') == 'fpscr_to_apsr':
            self.emit(f'        const auto fp_fpscr = std::uint32_t({self.read(plan["fpscr"])});')
            for node, bit in zip(plan['flags'], (31, 30, 29, 28)):
                self.write(node, f'(fp_fpscr >> {bit}) & 1u')
            self.emit('      }')
            self.emit('    }')
            return
        if plan.get('kind') == 'bit_copy':
            # VFP VMOV register/immediate also participates in legacy short
            # vectors. Refuse before writes, after the ARM predicate passes.
            self.emit(f'        const auto fp_fpscr = std::uint32_t({self.read(plan["fpscr"])});')
            self.emit('        if (fp_fpscr & ((7u << 16) | (3u << 20))) return UnsupportedSemantics;')
            self.emit(f'        const Word fp_bits = {self.read(plan["inputs"][0])};')
            self.write(plan['destination'], 'fp_bits')
            self.emit('      }')
            self.emit('    }')
            return
        arguments = []
        for index, node in enumerate(plan['inputs']):
            kind = 'std::uint32_t' if node['size'] == 4 else 'std::uint64_t'
            self.emit(f'        const {kind} fp_arg_{index} = {kind}({self.read(node)});')
            arguments.append(f'fp_arg_{index}')
        self.emit(f'        const auto fp_fpscr = std::uint32_t({self.read(plan["fpscr"])});')
        self.emit('        as6_fp_result fp_result{};')
        self.emit(f'        const auto fp_status = {plan["function"]}({", ".join(arguments)}, fp_fpscr, &fp_result);')
        self.emit('        if (fp_status != AS6_FP_OK || fp_result.reserved != 0) return UnsupportedSemantics;')
        if plan['destination']:
            self.write(plan['destination'], 'fp_result.bits')
        self.write(plan['fpscr'], 'fp_result.fpscr')
        self.emit('      }')
        self.emit('    }')

        # The common native control-flow path advances both PC fields only
        # after success or a false predicate; failed mathematics stays here.

    def function(self, function):
        instructions = function['instructions']
        arm32_address(function['entry'])
        self.addresses = {arm32_address(i['address'], i['size']) for i in instructions}
        self.address_modes = {number(i['address']): i.get('context', {}).get('TMode') == '0x1' for i in instructions}
        if len(self.addresses) != len(instructions):
            raise Refused('duplicate instruction addresses')
        used_unique = set()
        for instruction in instructions:
            if not instruction['original_bytes_match']:
                raise Refused('original bytes not verified')
            mnemonic = instruction.get('mnemonic')
            if not isinstance(mnemonic, str) or not mnemonic.strip():
                raise Refused('explicit original mnemonic is required for semantic admission')
            if instruction.get('context', {}).get('TMode') not in {'0x0', '0x1'}:
                raise Refused('instruction ISA mode unknown')
            thumb = instruction['context']['TMode'] == '0x1'
            if instruction['size'] not in ({2, 4} if thumb else {4}) or number(instruction['address']) % (2 if thumb else 4):
                raise Refused('instruction length/alignment disagrees with its ISA mode')
            if len(bytes.fromhex(instruction['bytes'])) != instruction['size']:
                raise Refused('instruction byte count disagrees with declared length')
            if instruction.get('fallthrough') is not None:
                arm32_address(instruction['fallthrough'])
            for target in instruction.get('flows', []):
                arm32_address(target)
            trap_plan = self.original_trap_plan(instruction)
            if trap_plan:
                self.trap_plans[(number(instruction['address']), thumb)] = trap_plan
                continue
            atomic_plan = self.atomic_plan(instruction)
            if atomic_plan:
                self.atomic_plans[(number(instruction['address']), thumb)] = atomic_plan
                continue
            fp_plan = self.floating_plan(instruction)
            if fp_plan:
                self.fp_plans[(number(instruction['address']), thumb)] = fp_plan
                continue
            for op in instruction['pcode']:
                self.validate_operation(op)
            verify_temporary_definitions(instruction)
            for op in instruction['pcode']:
                for node in op['inputs'] + ([op['output']] if op.get('output') else []):
                    if node['space'] == 'unique':
                        used_unique |= span(node)
        self.unique = {offset: index for index, offset in enumerate(sorted(used_unique))}
        entry = number(function['entry'])
        if entry not in self.addresses:
            raise Refused('exact function entry has no decoded instruction')
        self.emit(f'// Original function {function["name"]!r} at 0x{entry:x}; fixed native translation.')
        entry_mode = int(self.address_modes[entry])
        self.emit(f'static Status fn_{entry:x}_m{entry_mode}(Context &ctx, bool legacy, std::uint32_t stop_pc, bool stop_thumb) {{')
        self.emit(f'    std::uint8_t unique[{max(len(self.unique), 1)}] = {{}};')
        self.emit('    Word value = 0, address = 0, writeback_base = 0;')
        self.emit('    switch ((std::uint64_t(ctx.next_pc) << 1) | std::uint64_t(ctx.isa_thumb)) {')
        for instruction in instructions:
            pc = number(instruction['address'])
            key = (pc << 1) | int(self.address_modes[pc])
            self.emit(f'        case 0x{key:x}ULL: goto ins_{pc:x};')
        self.emit('        default: return UnresolvedTarget;')
        self.emit('    }')
        for instruction in instructions:
            address = number(instruction['address'])
            expected_thumb = instruction['context']['TMode'] == '0x1'
            comment = instruction['asm'].replace('\n', '\\n').replace('\r', '\\r')
            self.emit(f'ins_{address:x}: // {comment}')
            self.emit(f'    ctx.next_pc = 0x{address:x}u;')
            self.emit(f'    write_bytes(ctx.registers, {self.pc_offset}, 4, Word(ctx.next_pc));')
            self.emit('    if (!legacy && ctx.next_pc == stop_pc && ctx.isa_thumb == stop_thumb) return Returned;')
            self.emit(f'    if (ctx.isa_thumb != {str(expected_thumb).lower()}) return UnresolvedTarget;')
            self.emit('    if (ctx.budget == 0) return BudgetExhausted;')
            self.emit('    --ctx.budget;')
            self.writeback_offset = self.writeback_offsets.get((address, int(expected_thumb)))
            if self.writeback_offset is not None:
                self.emit(f'    writeback_base = read_bytes(ctx.registers, {self.writeback_offset}, 4);')
            fp_plan = self.fp_plans.get((address, expected_thumb))
            atomic_plan = self.atomic_plans.get((address, expected_thumb))
            trap_plan = self.trap_plans.get((address, expected_thumb))
            if trap_plan:
                self.emit(f'    ctx.fault_address = 0x{trap_plan["address"]:x}u;')
                self.emit('    return ctx.status = OriginalTrap;')
            elif atomic_plan:
                self.emit_atomic_instruction(atomic_plan)
            elif fp_plan:
                self.emit_floating_instruction(fp_plan)
            else:
                for index, op in enumerate(instruction['pcode']):
                    self.emit(f'op_{address:x}_{index}: ;')
                    self.operation(op, index, instruction)
            self.emit(f'op_{address:x}_{len(instruction["pcode"])}: ;')
            target = instruction.get('fallthrough')
            if target is None:
                self.emit('    return InvalidState; // no implicit fallthrough may be invented')
            else:
                self.emit('    ' + self.branch({'space': 'ram', 'offset': target, 'size': 4}, 0, instruction))
        self.emit('}')

    def generate(self):
        module_targets = {}
        entry_targets = {}
        for function in self.doc['functions']:
            entry = arm32_address(function['entry'])
            entry_ins = next((i for i in function['instructions'] if number(i['address']) == entry), None)
            if entry_ins is None or entry_ins.get('context', {}).get('TMode') not in {'0x0', '0x1'}:
                raise Refused('function entry requires an exact decoded instruction and mode')
            entry_mode = int(entry_ins['context']['TMode'] == '0x1')
            entry_key = (entry << 1) | entry_mode
            name = f'fn_{entry:x}_m{entry_mode}'
            if entry_key in entry_targets:
                raise Refused('duplicate module function entry (PC, mode)')
            entry_targets[entry_key] = name
            for instruction in function['instructions']:
                if instruction.get('context', {}).get('TMode') not in {'0x0', '0x1'}:
                    raise Refused('module instruction mode is unknown')
                pc = arm32_address(instruction['address'], instruction['size'])
                key = (pc << 1) | int(instruction['context']['TMode'] == '0x1')
                if key in module_targets:
                    raise Refused('duplicate module instruction target (PC, mode)')
                module_targets[key] = name
        if not module_targets:
            raise Refused('empty native module')
        self.emit('// Generated offline from verified original SLEIGH semantics. Do not edit.')
        self.emit('#include "../runtime/aot_support.hpp"')
        math_include = len(self.lines)
        self.emit('')
        self.emit('using namespace as6aot;')
        for function in self.doc['functions']:
            self.function(function)
        if self.fp_plans:
            self.lines[math_include] = '#include "as6_arm_float.h"'
        self.emit('using NativeFunction = Status (*)(Context &, bool, std::uint32_t, bool);')
        self.emit('struct NativeEntry { std::uint64_t key; NativeFunction function; };')
        self.emit('static constexpr NativeEntry module_entries[] = {')
        for key, name in sorted(module_targets.items()):
            self.emit(f'    {{0x{key:x}ULL, {name}}},')
        self.emit('};')
        self.emit('static NativeFunction module_lookup(std::uint32_t pc, bool thumb) {')
        self.emit('    const std::uint64_t key = (std::uint64_t(pc) << 1) | std::uint64_t(thumb);')
        self.emit('    std::size_t lo = 0, hi = sizeof(module_entries) / sizeof(module_entries[0]);')
        self.emit('    while (lo < hi) {')
        self.emit('        const std::size_t mid = lo + (hi - lo) / 2;')
        self.emit('        if (module_entries[mid].key < key) lo = mid + 1; else hi = mid;')
        self.emit('    }')
        self.emit('    return lo < sizeof(module_entries) / sizeof(module_entries[0]) && module_entries[lo].key == key ? module_entries[lo].function : nullptr;')
        self.emit('}')
        self.emit('static bool valid_context(const Context &ctx) {')
        self.emit(f'    return ctx.registers && ctx.register_size >= {self.register_size} && (ctx.data_access ? (ctx.data_access->state && ctx.data_access->read && ctx.data_access->write) : (ctx.memory && ctx.memory_size <= 0x100000000ULL - ctx.memory_base));')
        self.emit('}')
        self.emit('extern "C" std::uint32_t as6_aot_register_size() { return ' + str(self.register_size) + '; }')
        self.emit('extern "C" std::uint32_t as6_aot_context_size() { return sizeof(Context); }')
        self.emit('extern "C" std::uint32_t as6_aot_context_version() { return 2; }')
        self.emit('extern "C" std::uint32_t as6_aot_execute(Context *ctx, std::uint32_t stop_pc, std::uint32_t stop_thumb) {')
        self.emit('    if (!ctx) return InvalidState;')
        self.emit('    if (!valid_context(*ctx) || stop_thumb > 1 || (stop_pc & (stop_thumb ? 1u : 3u))) return ctx->status = InvalidState;')
        self.emit('    if (ctx->status != Returned && ctx->status != BudgetExhausted) {')
        self.emit('        if (ctx->status == UnresolvedTarget || ctx->status == MemoryFault || ctx->status == InvalidState || ctx->status == ArithmeticFault || ctx->status == UnsupportedSemantics || ctx->status == OriginalTrap) return ctx->status;')
        self.emit('        return ctx->status = InvalidState; // Dispatch is internal, not a caller state.')
        self.emit('    }')
        self.emit('    ctx->status = Returned; ctx->fault_address = 0;')
        self.emit('    for (;;) {')
        self.emit(f'        write_bytes(ctx->registers, {self.pc_offset}, 4, Word(ctx->next_pc));')
        self.emit('        if (ctx->next_pc == stop_pc && ctx->isa_thumb == bool(stop_thumb)) return ctx->status = Returned;')
        self.emit('        NativeFunction target = module_lookup(ctx->next_pc, ctx->isa_thumb);')
        self.emit('        if (!target) return ctx->status = UnresolvedTarget;')
        self.emit('        const Status result = target(*ctx, false, stop_pc, bool(stop_thumb));')
        self.emit('        if (result != Dispatch) return ctx->status = result;')
        self.emit('    }')
        self.emit('}')
        self.emit('extern "C" std::uint32_t as6_aot_run_context(Context *ctx, std::uint32_t stop_pc, std::uint32_t stop_thumb) {')
        self.emit('    return as6_aot_execute(ctx, stop_pc, stop_thumb);')
        self.emit('}')
        self.emit('extern "C" std::uint32_t as6_aot_run(std::uint32_t entry, std::uint8_t *registers,')
        self.emit('    std::size_t register_size, std::uint8_t *memory, std::uint32_t memory_base,')
        self.emit('    std::uint64_t memory_size, std::uint64_t budget, std::uint32_t thumb,')
        self.emit('    std::uint32_t *next_pc, std::uint32_t *next_thumb, std::uint32_t *fault_address) {')
        self.emit(f'    if (!registers || register_size < {self.register_size} || !memory || !next_pc || !next_thumb || !fault_address || thumb > 1 || memory_size > 0x100000000ULL - memory_base) return InvalidState;')
        self.emit('    Context ctx{registers, register_size, memory, memory_base, memory_size, budget, entry, 0, Returned, bool(thumb)};')
        self.emit('    Status result = UnresolvedTarget;')
        self.emit('    switch ((std::uint64_t(entry) << 1) | thumb) {')
        for key, name in sorted(entry_targets.items()):
            self.emit(f'        case 0x{key:x}ULL: result = {name}(ctx, true, 0, false); break;')
        self.emit('    }')
        self.emit('    *next_pc = ctx.next_pc; *next_thumb = ctx.isa_thumb; *fault_address = ctx.fault_address;')
        self.emit('    return result;')
        self.emit('}')
        return '\n'.join(self.lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('export', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    document = json.loads(args.export.read_text())
    generated = Generator(document).generate()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated)
    manifest = {'image_sha256': document['image_sha256'],
                'export_sha256': hashlib.sha256(args.export.read_bytes()).hexdigest(),
                'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                'generated_sha256': hashlib.sha256(generated.encode()).hexdigest(),
                'functions': [{'entry': f['entry'], 'name': f['name'], 'instructions': len(f['instructions'])}
                              for f in document['functions']],
                'runtime_instruction_decoder': False, 'runtime_pcode_executor': False,
                'jit': False, 'full_game_converted': False}
    args.output.with_suffix('.manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(f'Generated {len(document["functions"])} fixed functions, {document["instruction_count"]} source instructions.')


if __name__ == '__main__':
    try:
        main()
    except (Refused, KeyError, TypeError, ValueError) as error:
        raise SystemExit(f'Static conversion refused: {error}')
