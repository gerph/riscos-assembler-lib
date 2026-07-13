# AGENTS.md

Guidance for AI agents (and humans) working on this repository.

## What this is

`Assemble` is a RISC OS library providing **line-at-a-time assemblers** for
several CPU instruction sets, all built against one shared interface. It is
built as a `command` type project (`riscos-project create --type command`);
the resulting `Assemble` binary's `main()` currently just runs the self-test
suites for every backend and exits with a non-zero status on failure. There
is no BASIC integration yet — the library is designed to be callable from a
future BASIC inline-assembler patch (or any other caller), one source line
at a time, but nothing currently wires it into BASIC itself.

Five backends exist today:

| Backend      | Files                                    | Instruction set(s)              |
|--------------|-------------------------------------------|----------------------------------|
| 6502         | `h/assemble_6502`, `c/assemble_6502`       | 6502, 65C02, 65C816 (dialect via OPT bits) |
| 6809         | `h/assemble_6809`, `c/assemble_6809`       | 6809 (single dialect)            |
| x86-64       | `h/assemble_x86_64`, `c/assemble_x86_64`   | x86-64, limited (see below)      |
| Z80          | `h/assemble_z80`, `c/assemble_z80`         | Z80, including common undocumented forms |
| ARM32        | `h/assemble_arm32`, `c/assemble_arm32`     | base ARM (ARMv4-ARMv8 AArch32 subset) + legacy FPA + classic VFP scalar + partial NEON/SIMD (dialect via OPT bits, see below) |

Shared infrastructure lives in `h/assemble_common` / `c/assemble_common`.

## Building and testing

```
riscos-amu                # 32-bit build
riscos-amu BUILD64=1      # 64-bit build

riscos-build-run aif32 --command "run aif32.Assemble"          # run all self-tests, 32-bit (aarch32)
riscos-build-run --64 aif64 --command "run aif64.Assemble"     # run all self-tests, 64-bit (aarch64)
```

`riscos-build-run` defaults to an aarch32 (32-bit) system, which can't
execute a 64-bit AIF — pass `--64`/`--64bit` (shorthand for `--arch
aarch64`) to run one on an aarch64 system instead. Both architectures run
the full test suite and should show identical pass counts; run both when
changing anything that could plausibly behave differently by word size
(pointer-sized types, the no-64-bit-integer workarounds below, etc).

There is no separate test runner — `c/main` calls `run_tests()` /
`run_tests_6809()` / `run_tests_x86_64()` in sequence and returns the total
failure count as the exit code. Each backend's test file prints a one-line
`passed/failed` summary. Add a new backend's tests the same way: a
`run_tests_<name>()` entry point declared in `h/tests`, called from
`c/main`, with its object added to `OBJS` in `Makefile,fe1`.

## Architecture

### `assemble_context_t` (h/assemble_common)

Every backend exposes a single entry point shaped like
`assemble_<name>_line(assemble_context_t *context, const uint8_t *line, size_t line_length)`,
called **once per source line** (never a whole `[...]` block at once — the
caller loops over lines and drives multi-pass assembly). The context
carries:

- `buffer` / `buffer_length` — destination for assembled bytes, or
  `buffer_length == -1` for a size-only pass (`buffer` may be NULL then).
  Callers advance `buffer`/`address` by `bytes_used` themselves before the
  next call.
- `address` — the logical address (P%) this line assembles for; distinct
  from `buffer`, since code can be assembled somewhere and executed
  elsewhere.
- `opt` — the BASIC `OPT` value. Bits 0-1 have the standard BASIC meaning
  (list / stop-on-error) and are the caller's concern, not the assembler's —
  every backend treats `OPT` itself as a no-op that just validates/consumes
  its expression. CPU-specific dialect bits (eg 6502's 65C02/65816 select)
  start at bit 4 and are documented in that backend's header.
- `resolve_expr` / `assign_var` — callbacks into the host's expression
  evaluator and variable table. `resolve_expr` returns a tagged
  `assemble_value_t` (integer/float/string); `assign_var` is how `.label`
  definitions and (where supported) `EQU` write back.
- `bytes_used` — set by the call to the number of bytes written (or that
  would have been written on a size-only pass).

### Error reporting

Errors are returned as `_kernel_oserror *` (NULL on success), pointing at a
**static** per-backend error block — safe because RISC OS is single-threaded
and there's never more than one live error. The `errnum` is packed via
`ASSEMBLE_ERRNUM(cpu_class, type, variant)`:

- byte 3 (MS): `assemble_cpu_class_t` — which backend raised it
- byte 2: `assemble_error_type_t` — coarse, shared-across-backends category
  (bad mnemonic, bad operand, size mismatch, range, syntax, ...)
- byte 1: reserved, always 0
- byte 0 (LS): a backend-specific `assemble_<name>_error_variant_t` value,
  or 0 if the coarse type is precise enough on its own

This lets a caller handle an error as generically or as specifically as it
needs, without every backend inventing its own scheme. Extend the shared
`assemble_error_type_t` enum sparingly (it's meant to generalise across
CPUs); put backend-specific detail in that backend's own variant enum.

### Emission helpers (h/assemble_common)

`assemble_emit_byte/word/tribyte/dword` (little-endian) and
`assemble_emit_word_be/dword_be` (big-endian, added for 6809) both exist —
pick whichever matches the target CPU's own encoding, not the host's.
`assemble_emit_qword` exists for 64-bit immediates but **sign-extends a
32-bit `int32_t`** rather than taking a true 64-bit value — see the
"no 64-bit integer" note below.

### Platform constraint: no 64-bit integer type

The 32-bit Norcroft compiler (`riscos-cc`) has **no `long long`, `int64_t` or
`uint64_t`** — confirmed by direct compiler test, not assumed. (The 64-bit
compiler does have `int64_t`, but code here targets both from one source
tree, so it can't be used.) `assemble_value_t.value.as_integer` is `int32_t`
throughout the whole library for this reason. When porting source that uses
a genuine 64-bit value (eg x86-64's packed SIB register/scale info, or a
64-bit immediate), either split it across two `uint32_t` halves (see
`sib_add()`/`sib_nibble()` in `c/assemble_x86_64`) or sign-extend a 32-bit
value at the point of use — don't reach for `long long`.

### Test harness pattern

Each `c/tests_<name>` file is self-contained and follows the same shape:

- a small fixed-size symbol table (`test_state_t`) with linear lookup
- a minimal expression evaluator (`test_resolve_expr`) supporting decimal
  and `&hex` literals, symbol references, and `+`/`-`
- `test_assign_var` writing into the symbol table
- a table-driven `test_case_t` list: description, source line(s), expected
  bytes (or `expect_error`), run through `run_case()`
- multi-line cases thread `address`/`buffer` forward between lines
  themselves (each backend's harness does this identically — copy the
  pattern rather than trying to share it, since the three copies have
  drifted slightly and reconciling them isn't worth the churn)

When adding tests, prefer at least one **independently verifiable** case
before scaling up (a well-known encoding you can check by hand or against a
reference) — see "Lessons from the x86-64 port" below for why this matters.

## Backend-specific notes

### 6502 (`assemble_6502`)

Reverse-engineered from `Basic6502,ffb` (a tokenised BASIC program by John
Kortink that binary-patches the running BASIC V module to add a 6502
assembler — not source we could reuse directly, but its addressing-mode
grammar, register conventions and error cases were traced from the
detokenised ARM disassembly). Dialect (6502/65C02/65C816) is selected via
`context->opt` bits 0x10/0x20, matching that patch's convention. Full flat
opcode table (one row per mnemonic+addressing-mode), verified against the
standard NMOS/WDC opcode matrices.

### 6809 (`assemble_6809`)

Same author, same technique, `Basic6809,ffb`. Turned out simpler than 6502:
every 6809 mnemonic (`ADCA`, `LDX`, `ANDCC`, `LBSR`, `SWI2`, `PSHS`...) is a
complete self-contained word, so it reuses the flat-table approach. The
genuinely new piece was the indexed-addressing postbyte generator
(`,R` / `,R+` / `,R++` / `,-R` / `,--R` / `A,R`/`B,R`/`D,R` / 5-8-16-bit
`n,R` / `n,PCR` / indirect `[...]` / extended indirect `[nnnn]`) — see
`finish_indexed_*` in `c/assemble_6809`. The whole ISA is big-endian.

### x86-64 (`assemble_x86_64`)

**Ported**, not reverse-engineered, from real source:
`riscos64-rtrussell-bbcbasic/src/bbasmb_x86_64.c` (Richard Russell's BBC
BASIC assembler). That source is data-table-driven: `instructions[]` is a
sorted array of 6-byte `(prefix, opcode, flags×2, mnemonic-index)` rows,
searched by packed sort key with a "vertical/horizontal promotion" scheme
that tries 8/16/32/64-bit register variants of the same table row. The
`mnemonics[]`/`specials[]`/`special[]`/`operands[]`/`instructions[]` arrays
were copied **byte-for-byte** (verified with `diff` against the source, not
retyped) since `instructions[]` must stay in exactly that sorted order for
the binary search to work; only the surrounding algorithm was rewritten
against this library's calling convention.

Known, deliberate gap versus the original: `MOV reg64, name` resolving a
BASIC/OS routine name to its address needs a live runtime function
registry this library has no equivalent of. That specific form raises
`ASSEMBLE_X86_64_ERR_SYSTEM_CALL_UNSUPPORTED` instead of silently doing
nothing. Embedding a string literal's raw bytes as immediate data (a
different feature, no runtime registry needed) still works.

#### Lessons from the x86-64 port, if you touch it again

- **Never hand-convert a `0b...` binary literal to hex.** Norcroft doesn't
  support binary literals, so every one in the original had to be
  converted. Doing this by eye produced two wrong values on the first pass
  (`0x00012000` vs the correct `0x00102000` — a swapped nibble). Use
  `bash`'s `$((2#...))` arithmetic (or equivalent) mechanically, then
  cross-check the *count and order* of converted values against the
  original with a script, not by rereading the diff yourself.
- **Don't cast an arbitrary byte offset to a wider integer pointer and
  dereference it** (`*(unsigned int *)(arr + n)`) — the original does this
  for its binary-search sort key and for reading the 16-bit flags field.
  It's undefined behaviour and risks faulting on strict-alignment ARM.
  Replicate the exact same comparison using explicit little-endian byte
  assembly instead (`read_sortkey()`/`read_flags()` in `c/assemble_x86_64`)
  — same result, no unaligned access.
- Test against your own independently-known-correct encodings before
  trusting the port's output as an oracle for trickier cases. The very
  first test (`MOV RAX,RBX` → `48 89 D8`) passing first time was a good
  sign, but subsequent hand-derived expectations for `SUB RAX,1` and
  `DB 1,2,3` turned out to be *my* wrong assumptions, not bugs — always
  re-check against the true original source (`grep`/`sed`), not memory of
  it, before deciding which side is wrong.

### ARM32 (`assemble_arm32`)

**Ported**, not reverse-engineered, from `ROOLBASIC/s/Assembler` (BBC
BASIC's own inline ARM assembler, itself written in ARM assembly — a
self-hosted assembler assembling its own host CPU's instruction set).
Unlike the other backends, base ARM32 encoding is standard, well-documented
ARM architecture and was implemented directly from that knowledge, cross-
checked against the original source for syntax conventions, error
taxonomy, and the trickier ARMv6/v7 media instructions (parallel add/
subtract family, SBFX/UBFX, SDIV/UDIV/USAD8/USADA8, RBIT, PKH, UMAAL,
RFE/SRS/ERET/SETEND/SETPAN) where bit-level fidelity to the original
mattered and was verified by tracing the actual handler code, not
assumed from memory.

A quirk worth remembering if this backend is extended: uniquely among ARM
mnemonics, LDR/STR/LDM/STM/SWP/the long-multiply family (UMULL/UMLAL/
SMULL/SMLAL)/CDP/MCR/MRC/LDC/STC all write their size or mode suffix
**after** the condition code (`LDREQB`, not `LDRBEQ`), so they're matched
on a fixed 3-character root and handed to a dedicated parser in
`c/assemble_arm32` rather than going through the generic
root+condition+[S] mnemonic table used for everything else. The legacy
FPA arithmetic/load-store mnemonics (see below) follow the same pattern,
but with *two* extra suffixes after the condition: a mandatory precision
letter and an optional rounding-mode letter, eg `ADFEQDP`. VFP mnemonics
(see further below) are the odd one out in the *other* direction: UAL
syntax separates the condition from the `.F32`/`.F64` datatype suffix
with a literal `.`, so `read_token` naturally stops there and VFP
mnemonics go through the *ordinary* generic mnemonic table after all —
each VFP family encoder just parses its own `.` suffix from the operand
text that follows.

Known, deliberate gaps in base ARM32 (not silently dropped — each raises
"Mnemonic not recognised"): the ARMv5TE/v6 'xy' DSP multiply family
(SMLABB/SMLAWx/SMUAD/SMLAD/SMLALD and friends) and SMMLA/SMMLS/SMMUL;
MRRC/MCRR; the ARMv8 LDA/STL/LDAEX/STLEX load-acquire/store-release
family; and the banked-register form of MSR/MRS used for hypervisor-mode
register access.

FPA (coprocessor 1, `ADF`/`MUF`/`SUF`/.../`LDF`/`STF` and friends) is
implemented, gated by `ASSEMBLE_ARM32_OPT_FPA` — 39 of the original's 41
FPA mnemonics. `LFM`/`SFM` (multiple-register stack transfer) are a
deliberate gap: their real encoding packs the register count together
with a P/U/offset-clearing rule that couldn't be verified to the same
confidence as the rest of this port from the available source fragments,
so they were omitted rather than risking a wrong encoding. LDF/STF use
the same word-aligned ±1020-byte addressing shape as the generic
coprocessor LDC/STC (a separate, structurally similar parse in each of
`encode_fpa_ldf_stf` and `handle_coprocessor` — not literally shared
code, since the "bare `[Rn]`" pre/post-indexed distinction was a bug
fixed in both places together; see the git history if extending either).
Classic VFPv2/VFPv3 scalar (`VMOV`/`VADD`/`VSUB`/`VMUL`/`VMLA`/`VMLS`/
`VNMLA`/`VNMLS`/`VNMUL`/`VDIV`/`VABS`/`VNEG`/`VSQRT`/`VCMP`/`VCMPE`/`VLDR`/
`VSTR`/`VLDMIA`/`VLDMDB`/`VSTMIA`/`VSTMDB`/`VPUSH`/`VPOP`/`VMRS`/`VMSR`) is
implemented, gated by `ASSEMBLE_ARM32_OPT_VFP` — the `mnemonic_entry_t`
table gained a `requires_opt` field for this (0 for everything not
dialect-gated), checked once in `assemble_arm32_line` right after
`match_mnemonic()` succeeds, alongside the FPA dialect check. `VMOV` is
special: it's the *same* literal root for both the register-register
form (`VMOV.F64 Dd,Dm`, needs a `.`) and the ARM-core-register transfer
form (`VMOV Sn,Rt`/`VMOV Rt,Sn`, no `.`), so a single table entry maps to
`encode_vfp_mov_reg`, which peeks for a following `.` and delegates to
`encode_vfp_mov_core` if there isn't one — two table entries sharing one
root would silently shadow each other in `match_mnemonic()`'s
longest-match logic, since both roots are identical length.

Known, deliberate gaps in VFP (not silently dropped): `VCVT` (all forms
— integer/fixed-point/half-precision conversions) is omitted because its
real encoding packs signedness and rounding-mode selection across
non-adjacent bits in a way that couldn't be pinned down to the same
confidence as the rest of this port without a live reference; so are the
`VMOV`-immediate and two-core-register (`VMOV Rt,Rt2,Sm,Sm+1`) forms.
`VLDR`/`VSTR` use the same word-aligned ±1020-byte addressing shape as
the generic coprocessor LDC/STC and FPA LDF/STF (see above) — a third
structurally similar but separate parse, in `encode_vfp_ldr_str`. The
ARMv8-only VFP additions (`VRINT*`, `VSEL*`, `VMAXNM`/`VMINNM`,
directed-rounding `VCVT`) are also not yet implemented.

### NEON/Advanced SIMD

NEON is a much larger follow-on piece than base ARM32+FPA+VFP scalar
combined: a 2026-07 reconnaissance pass over `VFPLib/VFPLib`'s ~540
generated syntax patterns found roughly 83% of the full VFP+NEON+ARMv8
pattern count is NEON/SIMD, spread across an estimated 75-90 "instruction
family" implementations versus the ~20 covered by VFP scalar. Unlike the
rest of this backend (hand-derived from architecture knowledge and
cross-checked against known reference encodings), `VFPLib/VFPLib` turned
out to itself be a declarative table — `PROCvfp_addlookup` syntax
patterns naming an encoding, plus `PROCvfp_addencoding` bitstrings like
`"1111001U[0]0Vd[4]size[10]Vn[3210]Vd[3210]1000Vn[4]Q[0]Vm[4]0Vm[3210]"`
giving every field's exact bit position — so this piece is being ported
by mechanically extracting that table (bit position per named field,
MSB-first, matching the standard ARM architecture reference manual
diagrams) rather than re-deriving encodings from memory, which removes
most of the nibble-position risk that bit the x86-64 backend early on.

So far this covers the "three registers of the same length" family
(ARM DDI 0406C A7.4.1/A7.4.4/A7.4.5) — every NEON mnemonic of the shape
`{Dd|Qd},{Dn|Qn},{Dm|Qm}`, listed in the README's ARM32 section. A few
design points worth knowing before extending this further:

- NEON data-processing instructions are unconditional (cond field fixed
  to `0xF`) and never take an `S` suffix, unlike every other family in
  this backend — `encode_neon_three_same` and friends explicitly reject
  a parsed condition code rather than silently ignoring it.
- `VADD`/`VSUB`/`VMUL`/`VMLA`/`VMLS` each have *both* a scalar VFP form
  (`{S|D}d,{S|D}n,{S|D}m`, needs `F32`/`F64` dt, optional condition code)
  and a NEON three-same form (`Dd/Qd`, any dt, unconditional) — the same
  "two entries can't share one root" constraint as `VMOV` above, solved
  the same way: `encode_vfp_or_neon_arith3` parses the dt and peeks at
  the following register (`Sd`, or `Dd` with dt `F64`, means scalar;
  anything else means NEON) and dispatches accordingly, delegating the
  scalar case to the existing `encode_vfp_arith3` via a small shim table
  translating its tag (0=ADD..4=MLS) into that function's opc1/opc3
  param convention.
- Several mnemonics (`VABD`, `VCEQ`, `VCGE`, `VCGT`, `VMAX`, `VMIN`,
  `VPMAX`, `VPMIN`, `VPADD`) have *both* an integer/S/U-dt three-same
  form and an F32-only one, selected by the parsed datatype rather than
  by register class — `encode_neon_three_same` (the generic handler
  behind `FAMILY_NEON_3SAME`) branches on `dt.kind == 'F'` and reads
  whichever of `param1` (integer form) / `param2` (float form) applies;
  a mnemonic missing one form sets that param's `has_int`/`has_float`
  flag bit to 0 and any attempt to use it raises
  `ASSEMBLE_ARM32_ERR_BAD_DATATYPE`.
- `VCLE`/`VCLT`/`VACLE`/`VACLT` don't have their own encodings — per
  VFPLib's syntax table they assemble as `VCGE`/`VCGT`/`VACGE`/`VACGT`
  with operands 2 and 3 swapped (`VCLE Vd,Vn,Vm` ≡ `VCGE Vd,Vm,Vn`).
  The swap is a property of the *mnemonic*, not of which encoding form
  (integer or float) ends up being used, so it's a single `param1` bit
  checked once before the integer/float branch, not duplicated per form
  — an earlier draft got this wrong by putting the swap flag only on
  the float-form param and missed that the integer form needs it too.
- `VAND`/`VBIC`/`VORR`/`VORN`/`VEOR`/`VBSL`/`VBIT`/`VBIF` (`FAMILY_
  NEON_3SAME_LOGICAL`) are size-independent — their optional `.<size>`
  suffix is parsed (to accept real syntax like `VAND.I32`) and then
  discarded, since it has no effect on the encoding.
- Anonymous `struct { ... }` typed identically in two different local
  declarations are *not* the same type to the Norcroft C89 compiler
  (`'=': implicit cast of pointer to non-equal pointer`), which
  surfaced when a small per-tag constant lookup table and the pointer
  into it were declared with separately-spelled-out anonymous struct
  types; fixed by using a plain `uint32_t [5][N]` array indexed
  directly instead of a struct pointer.

The second batch covers the "two registers misc" shape (ARM DDI 0406C
A7.4.6, `{Dd|Qd},{Dm|Qm}`) — `VCLS`, `VCLZ`, `VCNT`, `VMVN`, `VQABS`,
`VQNEG`, `VRECPE`, `VRSQRTE`, `VREV16`/`VREV32`/`VREV64`, `VSWP`, `VTRN`,
`VUZP`, `VZIP` — plus `VABS`/`VNEG` (which, like the arith3 group, have
both a scalar and a NEON form and need the same merged-dispatch
treatment via `encode_vfp_or_neon_monadic2`) and the `,#0` comparison
form of `VCEQ`/`VCGE`/`VCGT`/`VCLE`/`VCLT` (a *different* encoding shape
to those mnemonics' three-same register form covered in batch one, but
sharing the same mnemonic-table row, so it's handled as a third branch
inside `encode_neon_three_same` that fires when a `#` follows the second
operand instead of a third register). More design notes:

- The F32-vs-integer selector bit in this shape isn't always at the same
  bit position (`VABS`/`VNEG`/the `#0` comparisons put it at bit 10;
  `VRECPE`/`VRSQRTE` put it at bit 8) — `assemble_neon_two_reg_misc`
  takes an explicit `f_bit_pos` parameter (0 meaning "this mnemonic has
  no F32 form at all") rather than assuming one fixed position.
- `VUZP`/`VZIP` with D-register (not Q) operands and 32-bit lanes are
  architecturally identical to `VTRN` and are encoded using `VTRN`'s
  opcode — `encode_neon_uzp_zip` checks for that specific combination
  and substitutes the opcode; every other width/register-class
  combination uses the mnemonic's own encoding.
- `VMVN`/`VSWP`'s `{.<size>}` suffix is optional and, when present, is
  parsed but has no effect on the encoding (the size field is always 0)
  — real syntax like `VMVN.I32 Qd,Qm` is accepted, just ignored.
- Throughout this backend's NEON pieces, the datatype *kind* letter
  (`I`/`S`/`U`/bare) is validated only where it changes the encoding
  (deriving the sign bit for `VQADD`-style "either S or U" mnemonics,
  or selecting the scalar-vs-NEON/int-vs-float branch); where the
  architecture restricts a mnemonic to a narrower kind set than what's
  accepted here (e.g. `VRECPE` is architecturally `U32`/`F32` only, but
  `S32`/`I32`/bare `32` are also accepted since the encoding is
  identical), that narrower restriction isn't separately enforced — a
  deliberate simplification in the same spirit as the width/kind
  leniency already documented for the three-same family, to keep this
  port's scope bounded without producing incorrect encodings.

The third batch covers shift-by-immediate (ARM DDI 0406C A7.4.7/A7.4.9)
— `VSHR`, `VSRA`, `VRSHR`, `VRSRA`, `VSRI`, `VSLI`, `VQSHLU`, `VSHRN`,
`VRSHRN`, `VQSHRN`, `VQSHRUN`, `VQRSHRN`, `VQRSHRUN`, `VSHLL`, plus
`VSHL`/`VQSHL` (which, like `VADD` etc, need merged dispatch — here
between two *different NEON* shapes rather than scalar-vs-NEON, since
each has both a three-same register form, already covered in batch one,
and a shift-immediate form). This was flagged during reconnaissance as
the highest-risk piece so far, because of how the shift amount and
element size share one bitfield:

- For a shift instruction, the element size (8/16/32/64) and the shift
  amount are encoded together in a single 6-bit (`imm6`) or 7-bit
  (`L:imm6`) field, recovered by hardware from the position of the
  field's *leading 1 bit* — not two separate subfields. The encoding
  formula is `element_size + shift_amount` for a left shift, or
  `2*element_size - shift_amount` for a right shift; both give the same
  field range `[size, 2*size-1]`, which is what makes the leading-bit
  trick work for either direction. `assemble_neon_shift_imm` takes the
  final `imm6`/`L` values already computed by the caller rather than
  trying to encapsulate the formula itself, since narrowing shifts (see
  below) use the same field but a different effective size.
- Narrowing shifts (`VSHRN`, `VRSHRN`, `VQSHRN`, `VQSHRUN`, `VQRSHRN`,
  `VQRSHRUN`) take a datatype describing the *source* (e.g. `I16` for a
  16-to-8-bit narrow), but the field formula uses the *destination*
  size (`dt.width/2`) — which, conveniently, is exactly
  `dt.width - shift_amount` (i.e. the general right-shift formula
  `2*(dt.width/2) - shift_amount` simplifies to that), so no separate
  "compute the destination width" step is needed.
- `VSHLL` has two forms sharing one root but *not* needing merged
  dispatch the way `VADD`/`VSHL` do: a general immediate form, and a
  dedicated "shift by exactly the element size" form with a completely
  different, simpler encoding (no `imm6` field at all, just a 2-bit
  size) that real syntax and hardware both use when the shift amount
  happens to equal the width — `encode_neon_vshll` just checks
  `shift_amount == dt.width` and picks the matching encoding, no
  mnemonic-table dispatch needed.
- Not every mnemonic in this family has a genuine Q-vs-D register-class
  choice at the bit position that would normally hold it: narrowing
  shifts are always `Dd,Qm` (fixed shape) and `VSHLL` is always
  `Qd,Dm`, so that bit position is repurposed as a fixed 0/1
  discriminator between mnemonic pairs (`VSHRN` vs `VRSHRN`, `VQSHRN`
  vs `VQRSHRN`) rather than a real register-class selector —
  `assemble_neon_shift_imm`'s `q` parameter is passed that fixed value
  in those cases rather than an actual derived Q bit.
- The `,#0` collapses to `VMOV`/`VMOVN`/`VQMOVN`/`VQMOVUN` that VFPLib's
  syntax table documents for `VSHR`/`VRSHR`/`VSHRN`/`VRSHRN`/`VQSHRN`-
  family mnemonics with a zero shift amount are deliberately **not**
  implemented yet — a shift amount of 0 on a right-shift mnemonic
  currently just raises the ordinary "bad shift" range error rather
  than being silently accepted or mis-encoded. `VMOVN`/`VQMOVN`/
  `VQMOVUN` now exist (fourth batch, below) so writing them out
  directly works; only the register form of plain `VMOV` (an alias for
  `VORR Vd,Vm,Vm`) is still missing, needed for `VSHR`/`VRSHR ,#0`.

The fourth batch covers long/wide/narrow arithmetic (ARM DDI 0406C
A7.4.3/A7.4.4/A7.4.5) — `VADDL`, `VADDW`, `VSUBL`, `VSUBW`, `VADDHN`,
`VSUBHN`, `VRADDHN`, `VRSUBHN`, `VABAL`, `VABDL`, `VMLAL`, `VMLSL`,
`VMULL`, `VQDMLAL`, `VQDMLSL`, `VQDMULL`, `VMOVL`, `VMOVN`, `VQMOVN`,
`VQMOVUN`, `VPADAL`, `VPADDL`. More design notes:

- This family has three distinct operand shapes sharing closely related
  encodings: "long"/widening ops are `Qd,Dn,Dm` (`VADDL` etc) except
  `VADDW`/`VSUBW`, which are `Qd,Qn,Dm` (one operand already wide) —
  `encode_neon_long` validates `Vn`'s register class from a param1 flag
  rather than assuming it; "halving narrow" ops are `Dd,Qn,Qm` (both
  sources wide, `VADDHN` etc); the various move forms are two-operand
  (`VMOVL` widens `Dm` to `Qd`, `VMOVN`/`VQMOVN`/`VQMOVUN` narrow `Qm`
  to `Dd`).
- VFPLib's own variable names distinguish `size` (the plain 2-bit
  0..3 encoding of 8/16/32/64) from `size1`, defined in its header
  comment as `size1 = size - 1` — used by the halving-narrow and
  narrowing-move mnemonics, whose *source* datatype (e.g. `I16` for a
  16-to-8-bit narrow) needs that adjustment to land in the right field.
  Conflating the two would silently shift every encoding by one lane
  size, so `neon_dt_size2(dt.width) - 1u` appears explicitly at each
  call site that needs it rather than being folded into a shared helper
  that might get reused somewhere `size` (unadjusted) is wanted instead.
- `VMULL` is deliberately its own dedicated encoder rather than a
  `FAMILY_NEON_LONG` table entry like its siblings, because of the P8
  (polynomial) special case: opcode/`U`/size are all fixed constants
  for `VMULL.P8`, not derived from an S/U datatype the way every other
  `FAMILY_NEON_LONG` mnemonic works — trying to force that through the
  generic derivation logic would have made the shared path harder to
  follow for no real code reuse (the P8 branch and the normal branch
  share nothing but the final `assemble_neon_long` call).
- `VPADAL`/`VPADDL` looked at first glance like they'd fit the existing
  `encode_neon_two_reg_misc` helper (two operands, same register class,
  a real `U`/`Q` pair) but don't: their opcode field sits one bit
  higher (bits 11:8, not 10:7) and `U` occupies the position
  `encode_neon_two_reg_misc` treats as an always-0 literal. Cross-
  checking the exact bit offsets against VFPLib's bitstring (rather
  than assuming "this looks like the same shape as X") caught the
  mismatch before it became a wrong encoding — see `encode_neon_padal`,
  which packs the *entire* fixed skeleton into `param1` per mnemonic
  instead of trying to share a skeleton constant that turned out not to
  be shared.

The fifth batch covers the "by scalar" `Dm[x]` operand form (ARM DDI
0406C A7.3, A7.4.2, A7.4.4) of `VMUL`, `VMLA`, `VMLS`, `VMLAL`, `VMLSL`,
`VMULL`, `VQDMULH`, `VQRDMULH`, `VQDMULL`, `VQDMLAL` and `VQDMLSL` —
not new mnemonic roots, but a third (or second) operand shape bolted
onto ten mnemonics already implemented in earlier batches, each
requiring its own bit of dispatch surgery:

- The physical register+index encoding is genuinely interleaved, not
  two clean subfields: for a 16-bit element the scalar register is
  limited to `D0`-`D7` (3 bits) and the 2-bit lane index occupies the
  register's own would-be bit 3 plus the `M` extension bit; for a
  32-bit element the register uses the full 4-bit field and the 1-bit
  index occupies `M` alone. `neon_scalar_vmx` implements this once;
  every dispatch site calls it rather than re-deriving the bit split.
- Every mnemonic in this batch already had a working plain-register (or
  scalar-VFP) encoder from an earlier batch, so this piece is entirely
  about adding a peek-ahead branch to *existing* functions rather than
  writing new ones: `peek_neon_scalar_operand` (does the upcoming
  operand look like `Dm[` rather than a bare register?) gates a new
  branch in `encode_vfp_or_neon_arith3` (for `VMUL`/`VMLA`/`VMLS`,
  guarded to exclude `VADD`/`VSUB`, which have no by-scalar form),
  `encode_neon_three_same` (for `VQDMULH`/`VQRDMULH`), `encode_neon_long`
  (for `VMLAL`/`VMLSL`/`VQDMLAL`/`VQDMLSL`/`VQDMULL`) and
  `encode_neon_vmull` (for `VMULL`, excluding its P8 case, which has no
  by-scalar form either).
- The same-width mnemonics (`VMUL`/`VMLA`/`VMLS`/`VQDMULH`/`VQRDMULH`)
  and the "long"/widening ones (`VMULL`/`VMLAL`/`VMLSL`/`VQDMULL`/
  `VQDMLAL`/`VQDMLSL`) share one word shape but differ in what bit 24
  means: a genuine Q/D register-class selector for the former (since
  `Vd`/`Vn` can be either both `Q` or both `D`) versus the `U` sign bit
  for the latter (destination is always `Q`, so there's no register
  class left to select) — `assemble_neon_by_scalar`'s `topbit` parameter
  is deliberately generic about which meaning the caller is using it
  for, since the bit position is identical either way.
- Retrofitting `param1`/`param2` on already-shipped mnemonic-table rows
  (rather than only ever adding brand new rows) needed care to avoid
  reusing a bit a family's generic encoder already reads with a
  different meaning: `VQDMULH`/`VQRDMULH`'s new `param2` "has scalar
  form" flag and opcode deliberately went in bits 30/19:16 rather than
  reusing `FAMILY_NEON_3SAME`'s existing `param2` bit 31 (`has_float`)
  and bits 11:8 (float opcode) — those two mnemonics have no float
  three-same form, but setting `has_float` anyway to steal its opcode
  bits would have made `VQDMULH.F32 ...` silently attempt (and
  mis-encode) a float three-same read instead of being rejected.

The sixth batch covers move-immediate (`VMOV`/`VMVN`), `VDUP`, `VEXT`
and `VTBL`/`VTBX`. `VMOV`/`VMVN`'s immediate `cmode` table was flagged
during reconnaissance as meaningfully higher-risk than anything ported
before it, so rather than re-deriving the cmode/imm8 encoding from
architecture recall, this piece was ported by reading VFPLib's own
`DEF FNvfp_parseop` byte-decomposition logic (the `"#c"` 32-bit
immediate case) directly and translating it into C — which also
resolved what first looked like a contradiction: cross-checking the
"x" wildcard bits in VFPLib's `opcmode` restriction strings against
real ARM architecture cmode values seemed to disagree at first, until
re-reading the source showed the wildcards get resolved by combining
constraints from *two* separate pattern strings (the byte-decompose
shape's pattern and the specific mnemonic's restriction list), not by
either one alone — a reminder to verify a "this doesn't add up" moment
against the actual source rather than either giving up or trusting a
half-formed guess.

- Given a (possibly dt-replicated) 32-bit value, VFPLib decomposes it
  into 4 bytes and matches against a fixed, priority-ordered set of
  shapes (byte-position 32-bit, halfword-position 16-bit, uniform
  8-bit) to find both the `cmode` and the 8-bit immediate to encode —
  `encode_neon_mov_mvn_imm_impl` ports that decomposition and matching
  logic directly (including the priority order, which matters: eg an
  all-zero value matches the first, "byte 0" shape rather than any
  other shape that could also technically apply).
- Deliberately not supported: `I64` (per-bit expansion) and `F32`
  (floating-point immediate) datatypes, and the "ones-fill" `cmode`
  1100/1101 shapes. Unlike most gaps documented in this project, these
  aren't a case of "ran out of time to verify" — VFPLib's own opcmode
  restriction lists for `VMOV`/`VMVN` specifically never reach any of
  them (they're reachable from `VORR`/`VBIC` instead, which aren't
  implemented in this backend at all), so there is nothing to port for
  these two mnemonics; skipping them doesn't remove any coverage
  VFPLib itself provided here.
- A more surprising consequence of the same fact: a uniform-byte
  (`VMVN.I8`) immediate is *rejected* here, matching a real limitation
  in VFPLib itself — its byte-decompose code hardcodes `op=0` for that
  shape regardless of which mnemonic is assembling, which can never
  match `VMVN`'s restriction list (`op=1` throughout), so VFPLib's own
  `FNvfp_parseop` would fail to assemble `VMVN.I8` too. This is called
  out explicitly in `encode_neon_mov_mvn_imm_impl`'s comment so it
  doesn't look like an accidental omission on a future read.
- `VMOV`/`VMVN` already had mnemonic-table rows from earlier batches
  (`VMOV` shares scalar-VFP dispatch, `VMVN` shares `VSWP`'s family),
  so the immediate form couldn't be a new table row — it's a peek-ahead
  branch retrofitted into `encode_vfp_mov_reg` and
  `encode_neon_mvn_swp` respectively (the same technique as the
  by-scalar retrofits in the previous batch), calling a shared
  `encode_neon_mov_mvn_imm_impl` helper. That helper takes an explicit
  `is_mvn` parameter rather than reading it from `entry->param1`,
  because the two callers' `param1` values don't agree on what 0 means
  (`VMOV`'s table row has no tag at all, while `VMVN`'s row uses
  `param1==0` to mean "this is the `VMVN` half of the `VMVN`/`VSWP`
  shared family") — threading that through `entry->param1` would have
  silently done the wrong thing for one of the two callers.
- `VDUP`'s two forms are structurally unrelated, not just differently
  encoded: the scalar form (`Dd,Dm[x]`) is unconditional NEON, but the
  ARM-core-register form (`Dd,Rt`) is a genuinely older, conditional
  encoding (real `cond` field, not the fixed `0xF` every other NEON
  instruction in this backend uses) — `VDUP`'s mnemonic-table row sets
  `allows_cond`, and `encode_neon_vdup` explicitly rejects a non-`AL`
  condition when it determines the scalar form applies, rather than
  silently accepting (and discarding) one.
- `VEXT`'s immediate is specified by the user in dt-sized elements but
  encoded as a plain byte offset — converting between the two is a
  left-shift by `log2(dt.width/8)`, the same "shift factor" idea
  VFPLib's own `#sN` syntax convention uses elsewhere (see the
  shift-by-immediate batch's imm6 notes).
- `VTBL`/`VTBX`'s register-list operand (`(Dn,Dn+1,...)`, 1-4
  consecutive `D` registers) is a genuinely new parsing shape not
  needed by anything else in this backend; `encode_neon_tbl` accepts
  both comma- and dash-separated spellings and validates the run is
  consecutive starting at the first register, reusing the existing
  `error_bad_register_list` helper (previously only used by
  `LDM`/`STM`) rather than inventing a parallel one.

Everything else NEON — load/store (`VLD1`-`VLD4`/`VST1`-`VST4`, all
alignment/lane/multiple-structure forms) and the convert/ARMv8-only
additions (`VCVT` all forms, `VCVTB`/`VCVTT`, `VRINT*`, `VSEL*`,
`VMAXNM`/`VMINNM`) — remain a follow-on. Datatype-conditional
structure-load alignment is meaningfully higher-risk to get bit-exact
than anything ported so far.

## Source material handling

Reference material lives alongside the project but is **not part of the
build and not tracked in git**: `6502/`, `6809/` (the tokenised `.ffb`
patches and their `Guide,fff` docs) and `riscos64-rtrussell-bbcbasic/` (a
full clone of the BBC BASIC source this port is based on). Don't add these
to git, and don't treat anything under `/riscos-built/Sources` as canonical
(per the global project instructions) — if you need to re-examine the
6502/6809 patches, detokenise with `riscos-basicdetokenise -i <file>`
first (see the `using-bbcbasic` skill).

## Coding conventions

Standard project conventions apply (see `writing-c` skill): C89, 4-space
indent, braces on their own line, function prologue comments in headers, no
trailing whitespace. A few conventions specific to this library, established
across all three backends and worth keeping consistent if you add a fourth:

- One `assemble_<name>_line()` entry point per backend, handling `.label`
  definitions (assigning the current address) and falling through to parse
  a real instruction on the same line if there's more after the label.
- `EQU` (where a backend supports it) requires a preceding `.label` on the
  same line and assigns the expression's *value*, not the address.
- `OPT <expr>` is always a no-op that just validates/consumes its
  expression — pass/listing control is the caller's responsibility.
- Pseudo-ops that emit raw data (`DCB`/`DCW`/`DCD` for 6502/6809, or
  `DB`/`DW`/`DD`/`DQ`/`EQUB`/`EQUD`/`EQUQ`/`EQUW` for x86-64, which are
  ordinary table-driven mnemonics there, not special-cased) use the
  backend's native endianness.

## Git workflow

Feature branches only — never commit directly to `master`. This repo now
has a real GitHub remote (`origin` → `gerph/riscos-assembler-lib`); nothing
should be pushed without being explicitly asked to. Keep commits scoped to
one backend/feature per commit where practical (see the existing history:
one commit per backend added).
