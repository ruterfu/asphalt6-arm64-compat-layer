#!/usr/bin/env python3
"""Block-structured register promotion for the frozen AOT modules.

Each generated module holds one translated function in which every original
instruction is a resumable entry: it stores pc, checks the stop target, the
ARM/Thumb mode and the budget, and keeps all ARM state in ctx.registers.
Guest data stores may alias Context, so none of that traffic can be removed by
the compiler. This rewrite emits, next to the unchanged original (renamed
`<fn>_exact`), a fast function with the same signature:

* Basic blocks start at every in-module branch target, at every direct branch
  target in another module (a loop may span two modules), after every exit,
  branch or mode write, and at the first instruction. Only block leaders are
  entries of the fast function; every other entry calls the exact function.
* A leader checks once that the mode is the module's, the budget covers the
  whole block and no stop target lies in it, then charges the whole block.
  Otherwise state is written back and the exact function continues from that
  instruction, so stop/mode/budget results are the original ones.
* An exit inside a block refunds the budget of its unexecuted instructions,
  a constant per exit site, so ctx.budget is exact on every exit.
* ARM registers live in a local copy only within one block: a leader loads
  the bytes its block reads or writes, and every edge leaving the block (to
  another block or to an exit) writes back the bytes the block can write.
  Between blocks the state is in ctx.registers, so no value stays live across
  the whole function. pc, budget and mode stay in locals until the exit.
* `if (ctx.status != Returned) return ctx.status;` remains only after helpers
  that take ctx or after a status write: nothing else changes status, and the
  fast function is entered with status == Returned (else: exact function).

* A boundary hook the layer inserted in an instruction's prologue, before its
  budget decrement (`if (...as6_*_boundary::tryDirect/shouldSuspend(ctx...))
  return X;`), makes that instruction a leader. After the leader's checks the
  fast function writes pc, mode and budget to ctx exactly as the exact
  prologue has them there, with every register already in ctx, and runs the
  hook unchanged; if it declines (hooks only read ctx then), the block runs
  fast.

The transform refuses a module whose shape differs from these assumptions; such
a module is emitted unchanged.

usage: promote_registers.py SOURCE_DIR OUTPUT_DIR [--only native_00721.cpp ...]
"""
import argparse
import re
import sys
from pathlib import Path

SIGNATURE = re.compile(r'^static Status (fn_[0-9a-f]+_m\d+)\(Context &ctx, bool legacy, '
                       r'std::uint32_t stop_pc, bool stop_thumb\) \{$', re.M)
INSTRUCTION = re.compile(r'^(ins_([0-9a-f]+)): ([^\n]*)$', re.M)
PROLOGUE = ['    ctx.next_pc = 0x{pc}u;',
            '    write_bytes(ctx.registers, 92, 4, Word(ctx.next_pc));',
            '    if (!legacy && ctx.next_pc == stop_pc && ctx.isa_thumb == stop_thumb) return Returned;',
            '    if (ctx.isa_thumb != false) return UnresolvedTarget;',
            '    if (ctx.budget == 0) return BudgetExhausted;',
            '    --ctx.budget;']
TRANSITION = re.compile(r'\{ ctx\.next_pc = 0x[0-9a-f]+u; write_bytes\(ctx\.registers, 92, 4, '
                        r'Word\(ctx\.next_pc\)\); if \(ctx\.isa_thumb == false\) goto (ins_[0-9a-f]+); '
                        r'return legacy \? UnresolvedTarget : Dispatch; \}')
REGISTER_ACCESS = re.compile(r'\b(read|write)_bytes\(ctx\.registers, (\d+), (\d+)')
STATUS_CHECK = 'if (ctx.status != Returned) return ctx.status;'
CTX_HELPERS = ('load', 'store', 'load_exclusive', 'store_exclusive', 'memory_barrier',
               'clear_exclusive', 'signed_divide', 'atomic_swap')
CTX_CALL = re.compile(r'\b(\w+)\(ctx\s*[,)]')
STATUS_WRITE = re.compile(r'\bctx\.status\s*=(?!=)')
THUMB_WRITE = re.compile(r'\bctx\.isa_thumb\s*=(?!=)')
RESERVED = re.compile(r'(?<!ctx\.)\b(next_pc|budget|isa_thumb|regs|as6_\w*exit\w*|entry_ins_\w+)\b')
RETURN = re.compile(r'\breturn ([^;]+);')
ALLOWED_CTX = {'registers', 'next_pc', 'budget', 'isa_thumb', 'status'}
# An instruction's comment names a direct branch target: `b 0x...`, `bne 0x...`.
HOOK = re.compile(r'^    if ?\((!legacy && )?as6_\w+_boundary::(tryDirect|shouldSuspend)\(ctx(, ?\w+)*\)\) return \w+;$')
DIRECT_BRANCH = re.compile(r'^ins_[0-9a-f]+: // (?!bic)b\w*\s+0x([0-9a-f]+)\s*$', re.M)
REGISTER_FILE_SIZE = 1024
SLOW = 'static_cast<Status>(0xff)'


class Refused(Exception):
    pass


def intervals(pairs):
    merged = []
    for start, end in sorted((offset, offset + width) for offset, width in pairs):
        # Merge only overlapping accesses: one copy per register or flag
        # lets the compiler promote each to a scalar.
        if merged and start < merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged


def check_function(body):
    fields = set(re.findall(r'\bctx\.(\w+)', body))
    if not fields <= ALLOWED_CTX:
        raise Refused('unexpected Context field: ' + ', '.join(sorted(fields - ALLOWED_CTX)))
    if 'ctx.registers' in REGISTER_ACCESS.sub('', body):
        raise Refused('register file used outside constant read/write_bytes')
    if re.search(r'\[[&=]', body) or RESERVED.search(body):
        raise Refused('lambda or reserved name present')
    unknown = {name for name in CTX_CALL.findall(body) if name not in CTX_HELPERS}
    if unknown:
        raise Refused('unreviewed helper receives ctx: ' + ', '.join(sorted(unknown)))


def prune_status_checks(lines):
    out, pending = [], False
    for line in lines:
        if line.strip() == STATUS_CHECK:
            if not pending:
                continue
            pending = False
        elif any(name in CTX_HELPERS for name in CTX_CALL.findall(line)) or STATUS_WRITE.search(line):
            pending = True
        out.append(line)
    return out


def branch_targets(sources):
    """Every direct branch target in the program (pc values)."""
    targets = set()
    for path in sources:
        targets.update(int(t, 16) for t in DIRECT_BRANCH.findall(path.read_text()))
    return frozenset(targets)


def promote(source, entries=frozenset()):
    match = SIGNATURE.search(source)
    if not match or len(SIGNATURE.findall(source)) != 1:
        raise Refused('expected exactly one translated function')
    name = match.group(1)
    start = match.end() + 1
    end = source.find('\n}\nstruct Entry', start)
    if end < 0:
        raise Refused('function end not found')
    body = source[start:end + 1]
    check_function('\n'.join(line for line in body.split('\n') if not HOOK.match(line)))

    switch_at = body.find('    switch (')
    switch_end = body.find('\n    }\n', switch_at)
    first = body.find('\nins_', switch_end)
    if switch_at < 0 or switch_end < 0 or first != switch_end + 6:
        raise Refused('entry switch shape')
    preamble = body[:switch_at]
    cases = re.findall(r'case (0x[0-9a-f]+)ULL: goto (ins_[0-9a-f]+);', body[switch_at:switch_end])

    text = body[first + 1:]
    heads = list(INSTRUCTION.finditer(text))
    instructions = []
    for i, head in enumerate(heads):
        chunk = text[head.end() + 1:heads[i + 1].start() if i + 1 < len(heads) else len(text)]
        lines = chunk.rstrip('\n').split('\n')
        pc = head.group(2)
        hook = None
        if len(lines) > 6 and HOOK.match(lines[5]):
            hook = lines.pop(5)
        if lines[:6] != [line.format(pc=pc) for line in PROLOGUE]:
            raise Refused('instruction prologue shape at ' + pc)
        rest = lines[6:]
        if any(HOOK.match(line) for line in rest):
            raise Refused('boundary hook not at an instruction start: ' + pc)
        instructions.append(dict(label=head.group(1), pc=int(pc, 16), comment=head.group(3), lines=rest, hook=hook))
    order = {ins['label']: i for i, ins in enumerate(instructions)}
    if len(cases) != len(instructions) or any(order.get(label) != i for i, (key, label) in enumerate(cases)):
        raise Refused('switch does not list every instruction in order')
    if any(int(key, 16) != ins['pc'] << 1 for (key, _), ins in zip(cases, instructions)):
        raise Refused('switch keys are not ARM-mode instruction addresses')

    leaders = {i for i, ins in enumerate(instructions) if i == 0 or ins['pc'] in entries or ins['hook']}
    for i, ins in enumerate(instructions):
        joined = '\n'.join(ins['lines'])
        sequential = instructions[i + 1]['label'] if i + 1 < len(instructions) else None
        targets = set(re.findall(r'goto (ins_[0-9a-f]+)', joined))
        if not targets <= set(order):
            raise Refused('branch to unknown label')
        for target in targets - {sequential}:
            leaders.add(order[target])
        rest = TRANSITION.sub('', joined)
        ends_block = targets - {sequential} or 'Dispatch' in rest or 'ctx.next_pc' in rest or THUMB_WRITE.search(joined)
        if ends_block and i + 1 < len(instructions):
            leaders.add(i + 1)
    bounds = sorted(leaders) + [len(instructions)]
    block_of = {}
    for a, b in zip(bounds, bounds[1:]):
        for i in range(a, b):
            block_of[i] = (a, b)

    block_sets = {}
    for a, b in zip(bounds, bounds[1:]):
        accessed, written = [(92, 4)], [(92, 4)]
        for ins in instructions[a:b]:
            for kind, offset, width in REGISTER_ACCESS.findall('\n'.join(ins['lines'])):
                offset, width = int(offset), int(width)
                if offset + width > REGISTER_FILE_SIZE:
                    raise Refused('register access outside layout')
                accessed.append((offset, width))
                if kind == 'write':
                    written.append((offset, width))
        block_sets[a] = (intervals(accessed), intervals(written))
    leader_labels = {instructions[i]['label'] for i in leaders}

    def flush(a):
        return ' '.join('std::memcpy(ctx.registers + %d, regs + %d, %d);' % (x, x, y - x) for x, y in block_sets[a][1])

    def localize(line):
        line = REGISTER_ACCESS.sub(lambda m: '%s_bytes(regs, %s, %s' % m.groups(), line)
        line = re.sub(r'\bctx\.next_pc\b', 'next_pc', line)
        line = re.sub(r'\bctx\.budget\b', 'budget', line)
        return re.sub(r'\bctx\.isa_thumb\b', 'isa_thumb', line)

    def exits(line, refund, block):
        add = ' budget += %d;' % refund if refund else ''
        line = RETURN.sub(lambda m: '{ as6_exit_status = %s;%s goto as6_exit_%d; }' % (m.group(1), add, block), line)
        # Leaving the block for another leader publishes this block's writes.
        return re.sub(r'goto (ins_[0-9a-f]+);', lambda m: ('{ %s goto %s; }' % (flush(block), m.group(1))
                      if m.group(1) in leader_labels else m.group(0)), line)

    fast = [f'static Status {name}(Context &ctx, bool legacy, std::uint32_t stop_pc, bool stop_thumb) {{']
    fast += preamble.rstrip('\n').split('\n')
    fast += ['    // Block-structured fast path; anything it cannot prove runs exactly.',
             '    if (ctx.status != Returned || ctx.isa_thumb) return %s_exact(ctx, legacy, stop_pc, stop_thumb);' % name,
             '    std::uint8_t regs[%d];' % REGISTER_FILE_SIZE,
             '    std::uint32_t next_pc = ctx.next_pc;',
             '    std::uint64_t budget = ctx.budget;',
             '    bool isa_thumb = false;',
             '    Status as6_exit_status;',
             '    switch (next_pc) {']
    fast += ['        case 0x%xu: goto %s;' % (instructions[i]['pc'], instructions[i]['label'])
             for i in sorted(leaders)]
    fast += ['        default: return %s_exact(ctx, legacy, stop_pc, stop_thumb);' % name, '    }']
    for i, ins in enumerate(instructions):
        a, b = block_of[i]
        position, length = i - a, b - a
        fast.append('%s: %s' % (ins['label'], ins['comment']))
        fast.append('    next_pc = 0x%xu;' % ins['pc'])
        fast.append('    write_bytes(regs, 92, 4, Word(next_pc));')
        if position == 0:
            last_pc = instructions[b - 1]['pc']
            fast.append('    if (isa_thumb || budget < %d || (!legacy && !stop_thumb && stop_pc >= 0x%xu && stop_pc <= 0x%xu))'
                        % (length, ins['pc'], last_pc))
            fast.append('        { as6_exit_status = %s; goto as6_exit; }' % SLOW)
            if ins['hook']:
                fast.append('    ctx.next_pc = 0x%xu; write_bytes(ctx.registers, 92, 4, Word(ctx.next_pc));' % ins['pc'])
                fast.append('    ctx.isa_thumb = false; ctx.budget = budget;')
                fast.append(ins['hook'])
            fast.append('    budget -= %d;' % length)
            fast += ['    std::memcpy(regs + %d, ctx.registers + %d, %d);' % (x, x, y - x) for x, y in block_sets[a][0]]
        refund = length - position - 1
        for line in prune_status_checks(ins['lines']):
            fast.append(exits(localize(line), refund, a))
    for a in bounds[:-1]:
        fast.append('as6_exit_%d: %s goto as6_exit;' % (a, flush(a)))
    fast.append('as6_exit:')
    fast += ['    ctx.next_pc = next_pc;', '    ctx.budget = budget;', '    ctx.isa_thumb = isa_thumb;',
             '    if (as6_exit_status == %s) return %s_exact(ctx, legacy, stop_pc, stop_thumb);' % (SLOW, name),
             '    return as6_exit_status;', '}']

    exact = source[match.start():end + 3].replace(f'static Status {name}(', f'static Status {name}_exact(', 1)
    header = source[:match.start()].replace('#include "as6_arm_float.h"',
                                            '#include "as6_arm_float.h"\n#include <cstring>', 1)
    return header + exact + '\n'.join(fast) + '\n' + source[end + 3:]


def relocatable(text):
    # The frozen stream includes its runtime by relative path; the output
    # directory resolves it through the aot/runtime include directory.
    return text.replace('#include "../runtime/', '#include "')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--only', nargs='*')
    parser.add_argument('--quiet', action='store_true', help='progress bar instead of per-module notes')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    names = args.only or sorted(p.name for p in args.source.glob('native_*.cpp'))
    entries = branch_targets(sorted(args.source.glob('native_*.cpp')))
    refused = 0
    if args.quiet:
        from tqdm import tqdm
        names = tqdm(names, unit='module', desc='      promoting registers', smoothing=0.05)
    for name in names:
        source = (args.source / name).read_text()
        try:
            text = promote(source, entries)
        except Refused as error:
            refused += 1
            if not args.quiet:
                print(f'{name}: kept unpromoted ({error})', file=sys.stderr)
            text = source
        text = relocatable(text)
        target = args.output / name
        if not target.exists() or target.read_text() != text:
            target.write_text(text)
    if not args.only:
        for extra in args.source.glob('*.cpp'):
            if not extra.name.startswith('native_'):
                (args.output / extra.name).write_text(relocatable(extra.read_text()))
    if not args.quiet:
        print(f'{len(names) - refused} promoted, {refused} kept', file=sys.stderr)


if __name__ == '__main__':
    main()
