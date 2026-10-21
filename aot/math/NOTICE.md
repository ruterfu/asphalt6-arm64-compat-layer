# Retained source and derivative notices

This is an experimental derivative of the hash-pinned local QEMU SoftFloat
mathematical sources listed in `vendor-inputs.lock.json`. It is not a Unicorn,
CPU, instruction-decoder, TCG, interpreter, or JIT library. The original project
and all upstream files are unchanged.

The six retained mathematical source/header files preserve their complete
original copyright, disclaimer, derivative-work, SoftFloat-2a, BSD and
GPL-v2-or-later notices. Their own notices govern their respective portions.
`vendor/licenses/COPYING`, `COPYING.LIB` and `QEMU-LICENSE` retain the local QEMU
license texts and source-file licensing guidance. The retained mathematical
unit is **not** represented as uniformly BSD, SoftFloat-only or permissively
licensed. No new license is purported to override a retained-source license.

The only retained-source edits are recorded verbatim in `vendor-manifest.json`:

1. Replace the QEMU omnibus include with independent integer/system support.
2. Remove the QEMU bitops include; implement the required tiny integer helpers
   independently in `support/as6_math_support.h`.
3. Require an explicit pure-software build and force `QEMU_NO_HARDFLOAT=1`.
4. Route the separately guarded f32-to-f64 widening shortcut through its
   existing software function as well.

A prominent derivative notice is prepended to the modified math source. The
unmodified specialization fragment retains `TARGET_ARM` NaN selection rules.
The independent ARM bit-pattern wrappers, support, fatal routine, tools and
tests are provided in source here to make this candidate auditable and
rebuildable; they do not import the upstream ARM CPU helper translation unit.

Any distribution of a retained-source derivative must preserve the applicable
file-level notices and source/license obligations. This research candidate is
not a completed application or a distribution-license determination for the
original game.
