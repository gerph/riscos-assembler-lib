# AGENTS.md

Guidance for AI agents (and humans) working on this repository.

## What this is

`Assemble` is a RISC OS library providing **line-at-a-time assemblers** for
several CPU instruction sets, all built against one shared interface. There
is no BASIC integration yet — the library is designed to be callable from a
future BASIC inline-assembler patch (or any other caller), one source line
at a time, but nothing currently wires it into BASIC itself.

The project builds as three separate pieces, each with its own Makefile:

| Makefile             | Type      | Produces                                              |
|-----------------------|-----------|--------------------------------------------------------|
| `MakefileLib,fe1`     | `LibExport` | `libAssemble` — the backends themselves, plus exported headers |
| `MakefileTests,fe1`   | `command` (`aif`) | `AssembleTest` — `c/tests` calls each backend's `run_tests_<name>()` in sequence and returns the total failure count as the exit code |
| `Makefile,fe1`        | `command` (`aif`) | `Assemble` — a real `*Assemble -cpu <cpu> -input <source> -output <binary>` command-line tool, linking against the built `libAssemble` |

Seven backends exist today:

| Backend      | Files                                    | Instruction set(s)              |
|--------------|-------------------------------------------|----------------------------------|
| 6502         | `h/assemble_6502`, `c/assemble_6502`       | 6502, 65C02, 65C816 (dialect via OPT bits) |
| 6809         | `h/assemble_6809`, `c/assemble_6809`       | 6809 (single dialect)            |
| x86-64       | `h/assemble_x86_64`, `c/assemble_x86_64`   | x86-64, limited (see below)      |
| Z80          | `h/assemble_z80`, `c/assemble_z80`         | Z80, including common undocumented forms |
| ARM32        | `h/assemble_arm32`, `c/assemble_arm32`     | base ARM (ARMv4-ARMv8 AArch32 subset) + legacy FPA + classic VFP scalar + partial NEON/SIMD (dialect via OPT bits, see below) |
| RISC-V       | `h/assemble_riscv`, `c/assemble_riscv`     | RV32I base integer ISA + Zicsr (single dialect, see below) |
| m68k         | `h/assemble_m68k`, `c/assemble_m68k`       | Motorola MC68000 base instruction set (single dialect for instructions, one OPT bit for directive syntax, see below) |

Shared infrastructure lives in `h/assemble_common` / `c/assemble_common`.
A directory of every backend -- for enumeration and by-class/by-name lookup,
so a caller doesn't need to know the backend list in advance -- lives in
`h/assemble_registry` / `c/assemble_registry` (see "Backend registry" below).

## Building and testing

```
riscos-amu -f MakefileLib                # build the library, 32-bit
riscos-amu -f MakefileLib BUILD64=1      # build the library, 64-bit
riscos-amu -f MakefileTests              # build the self-test AIF (needs the library built first)
riscos-amu -f Makefile                   # build the *Assemble command tool (needs the library built first)

riscos-build-run aif32 --command "run aif32.AssembleTest"       # run all self-tests, 32-bit (aarch32)
riscos-build-run --64 aif64 --command "run aif64.AssembleTest"  # run all self-tests, 64-bit (aarch64)
```

`riscos-build-run` defaults to an aarch32 (32-bit) system, which can't
execute a 64-bit AIF — pass `--64`/`--64bit` (shorthand for `--arch
aarch64`) to run one on an aarch64 system instead. Both architectures run
the full test suite and should show identical pass counts; run both when
changing anything that could plausibly behave differently by word size
(pointer-sized types, the no-64-bit-integer workarounds below, etc).

Each backend's test file prints a one-line `passed/failed` summary. Add a
new backend's tests the same way: a `run_tests_<name>()` entry point
declared in `h/tests`, called from `c/tests`, with `o.<name>` and
`o.tests_<name>` added to `MakefileTests,fe1`'s `OBJS` (and `o.<name>`
plus an `EXPORTS`/export-rule line added to `MakefileLib,fe1`).

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

### Backend registry (`h/assemble_registry`, `c/assemble_registry`)

A static table (`assemble_interfaces[]`, one row per backend, exposed via
`assemble_get_interfaces()`/`assemble_find_by_class()`/
`assemble_find_by_name()`) so a caller — the `*Assemble` command-line tool's
`-cpu` handling and `-list` output, in `c/main`, are the first real callers —
doesn't need to `#include` every backend header or hard-code the backend
list itself. Each row carries the backend's `assemble_cpu_class_t`,
canonical name, one-line description, `assemble_<name>_line` function
pointer, `max_instruction_length`, and an array of CPU-specific OPT-bit
descriptors (name + bit + description) for backends that have any.

This file necessarily sits *above* the backend layer (it's the one place in
the library that `#include`s every backend header at once), unlike every
other shared-infrastructure file, which the backends themselves depend on.
Keep it that way round — a backend header must never include
`assemble_registry.h`.

- `max_instruction_length` is the worst case for a genuine fixed-shape
  instruction or pseudo-instruction, deliberately excluding pseudo-ops that
  take an unbounded comma-separated list (`DCB`/`DCW`/`DCD`, `DEFM`) or a
  string-literal operand (which have no fixed upper bound) — see the README
  table for the six current figures and the specific case that achieves
  each one. Getting this number right needed an actual audit of each
  backend's addressing modes/opcode tables, not a guess from the
  architecture's typical instruction width — eg 6809's 5-byte maximum
  (a page-2-prefixed 2-byte opcode plus a 16-bit indexed offset) is easy to
  miss if you only think about its "normal" 1-2 byte opcodes, and ARM32's
  Thumb mode still tops out at 4 bytes (not 2), because `BL`/`BLX label`
  emits its two-halfword pair from a single `assemble_arm32_line()` call.
  If you add a backend or extend an existing one's addressing modes, check
  whether this number needs revisiting rather than assuming it's still
  right.
- A second table (`assemble_aliases[]`, via `assemble_get_aliases()`) maps a
  name that bundles a backend with a preset default OPT value — `65c02`,
  `65c816`, `arm32-fpa`, `arm32-vfp`, `arm32-thumb` — onto that backend's
  `assemble_cpu_class_t` plus the OPT value. `assemble_find_by_name()`
  checks this table before falling back to matching a backend's own
  canonical name, and returns the matched default OPT value via an
  out-parameter the caller remains free to override (eg from an explicit
  `-opt` argument) — `c/main`'s `-opt` always fully replaces whatever
  `-cpu` selected, rather than being OR'd with it, so `-cpu arm32-thumb
  -opt <n>` needs `<n>` to already include `ASSEMBLE_ARM32_OPT_THUMB` if
  the caller wants both the standard `ASSEMBLE_OPT_*` bits and the dialect.
  If you add a new dialect-preset alias, add its bit to the table alongside
  the existing ones rather than special-casing it in `c/main`.

## Backend-specific notes

### BASIC token collisions

BASIC tokenises whole keywords as single bytes (rarely two, for a handful of
BASIC V structured-programming keywords that ran out of single-byte token
space) — including as *prefixes* of longer identifiers, not just when the
keyword appears as a complete standalone word. `ANDI`, typed into a BASIC
program, is stored as the `AND` token byte followed by literal `I`, because
the tokeniser matches the longest keyword at that position regardless of
what follows. Every backend's mnemonic reader (`read_mnemonic`/`read_token`,
whatever it's called per-backend) must recognise these token bytes and
expand them back to ASCII before mnemonic lookup runs, or genuine
BASIC-tokenised source containing an affected mnemonic fails to assemble
outright (the token byte doesn't fall in `A-Z`/`a-z`, so the identifier scan
reads zero characters and lookup fails).

For years this project only handled `AND`/`EOR`/`OR` (and, once m68k needed
it, `NOT`) — the obvious arithmetic/logical-operator overlaps. An audit in
2026-08 tokenised **every** mnemonic each backend actually defines through
`riscos-basictokenise` and diffed the result against plain ASCII, rather
than assuming that four-token set was exhaustive. It wasn't: six of the
seven backends had at least one further collision, and two backends
(x86-64, ARM32) had *no* token handling at all. If you add a new backend or
a new mnemonic to an existing one, **run this audit rather than reusing the
previous backend's token list** — a new instruction set's mnemonics can
collide with completely different BASIC keywords (FPA borrowed BASIC's own
maths-function names; x86-64's `CALL`/`WAIT` are whole-word BASIC statement
keywords no other backend happens to define a mnemonic for).

Practical recipe: write one BASIC line per mnemonic root (`10 <MNEMONIC>`,
one per line number), `riscos-basictokenise` it, and check whether the first
non-space byte of each tokenised line is still plain ASCII. Any that come
back `>= 0x80` are collisions; the token's expansion is whatever prefix
match the tokeniser found (not necessarily the whole mnemonic — figure out
which real BASIC keyword it is, eg by testing the keyword alone). Confirmed
findings, per backend:

- **6502/6809/Z80/RISC-V**: already fully handled (`AND`/`EOR`/`OR`, plus
  Z80's own `CALL`/`DEFB`/`DEFM`/`DEFW` via `TOKEN_CALL`/`TOKEN_DEF`) —
  except RISC-V was missing `TOKEN_CALL` for its `CALL` pseudo-instruction,
  fixed alongside this audit.
- **m68k**: `AND`/`EOR`/`OR`/`NOT` were handled from the start; `DIV`
  (hits `DIVU`/`DIVS`), `MOVE` (hits `MOVE` itself plus every `MOVEx`
  mnemonic — `MOVEA`/`MOVEQ`/`MOVEM`/`MOVEP` and the `MOVE SR/CCR/USP`
  special forms, all via one token byte), `EXT`, `STOP` and `SWAP` were
  missing. `SWAP` is the only token anywhere in this library that tokenises
  as **two** bytes, not one (`C8 94`, an extended-page prefix) — it's a
  BASIC V structured-programming keyword that ran out of single-byte token
  space.
- **x86-64**: had no token handling at all. Found: whole-word `AND`/`DIV`/
  `OR`/`NOT`/`CALL`, the two-byte `WAIT`, and prefix collisions with
  BASIC's `FN` and `PI` keywords that lead several real mnemonics
  (`FNINIT` etc; `PINSRW`) — plus this backend's own `ANDx`/`DIVx`/`ORx`/
  `SQRTxx` families via the same `AND`/`DIV`/`OR`/`SQR` tokens. This
  backend's mnemonic reader (`schop_mnemonic`) has no separate
  "materialise an uppercase buffer first" step the way every other backend
  does — it binary-searches directly against the raw source bytes for
  speed, and its character-class test rejects any byte `>= 0x80` outright.
  Fixed with a wrapper, `schop_mnemonic_tokenised()`, that recognises a
  leading token byte, expands it plus whatever raw identifier bytes follow
  it into a small local buffer, looks the result up there, and — only on a
  match — advances the *real* source position by the number of source
  bytes consumed (not the expanded buffer's length).
- **ARM32**: also had no token handling at all, and turned up the largest
  collision set of any backend: `AND`/`EOR`/`OR` (`ORR`'s own leading `OR`
  collides just like the other backends' `ORxxx` forms), ten FPA
  maths-mnemonic collisions with BASIC's own built-in numeric functions
  (`ABS`/`ACS`/`ASN`/`ATN`/`COS`/`EXP`/`LOG`/`RND`/`SIN`/`TAN`), and NEON
  `VDUP` colliding with the `VDU` statement keyword. One further wrinkle
  here: the FPA dispatch locates a mnemonic by its first three characters
  and then reopens the source at a hardcoded `pos + 3` to parse the
  mandatory `S`/`D`/`E` precision suffix that follows the root — correct
  only when three logical characters always cost three real source bytes,
  which token expansion breaks (the `ABS` token is a single real byte
  producing three logical characters, so `pos + 3` skipped straight past
  the precision letter into the operands). Fixed by having the mnemonic
  reader (`read_token_root3()`) additionally report how many real source
  bytes the first three logical characters actually spanned, and using
  that instead of the hardcoded `3` at that one call site. If you add a
  mnemonic-dispatch path elsewhere that recomputes a source position from
  a fixed character-count assumption like this, it has the same latent bug
  for any mnemonic whose root happens to collide with a token.

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

The seventh batch covers structure load/store (ARM DDI 0406C A7.7/
A7.9) — `VLD1`/`VLD2`/`VLD3`/`VLD4`/`VST1`/`VST2`/`VST3`/`VST4` — but
only their "multiple" (register-list) addressing form, previously
flagged during reconnaissance as the most complex remaining addressing
in NEON. `VLD`/`VST` actually cover *three* structurally different
addressing shapes sharing those mnemonic names: "multiple" (a run of
1-4 `D` registers, sequential or de-interleaved), "single lane" (load/
store one lane of one or more registers, leaving the rest
untouched), and "single all lanes" (replicate one loaded element
across every lane, the same idea `VLD1 (single all)` uses for
`VDUP`-from-memory). Only "multiple" is implemented here — deliberately:
its encoding is comparatively regular (a plain 4-bit `type` field
plus 2-bit size/align fields), whereas the other two use a
datatype-and-lane-index-dependent bit-interleaved alignment field (the
same family of `bp_x[...]` VFPLib bitstring notation seen in the
by-scalar batch, but combined with *alignment* rather than just a
register+index split) that would need the same VFPLib-source-reading
rigour the `VMOV`/`VMVN` cmode table needed, and this batch was
already large enough to ship on its own. Revisit "single lane"/"single
all lanes" as their own follow-up rather than folding them in later
under time pressure.

- `VLD1`/`VLD2`/`VLD3`/`VLD4` (and their `VST` counterparts) share one
  encoding, distinguished entirely by a 4-bit `type` field derived from
  *how many registers the user wrote and whether they're consecutive or
  spaced two apart* — not by anything in the mnemonic root itself. Eg
  `VLD2.32 (D0,D1),[R1]` (consecutive pair) and `VLD2.32 (D0,D2),[R1]`
  (every-other-register pair, for de-interleaving) are the *same
  mnemonic* with different register-list shapes producing different
  `type` values (`1000` vs `1001`). `encode_neon_ldst_multiple` parses
  the list generically (`parse_neon_reglist_gap`, returning a register
  count and a gap of 1 or 2) and looks up `type` from a small
  `[struct_class][count,gap]` table per mnemonic rather than trying to
  encode this as a fixed per-mnemonic-table-row constant.
- The addressing syntax, `[Rn{@align}]{!}{,Rm}`, is a new parsing shape
  for this backend: a bracketed base register with an optional
  "@alignment-in-bits" annotation, then either a bare `!` (writeback by
  the total transfer size, encoded as `Vm=0xD`), an explicit `,Rm`
  (writeback by `Rm`, `Vm=Rm`), or neither (`Vm=0xF`, no writeback).
  `parse_neon_ldst_address` is the one place this shape is parsed;
  nothing else in NEON needs it since every other load/store-shaped
  instruction in this backend (`VLDR`/`VSTR`, the FPA/coprocessor
  `LDC`/`STC` family) uses a conventional `[Rn,#offset]` shape instead.
- Which alignment values are legal, and what 2-bit code they map to,
  depends on the register count (and, for the four-register forms of
  `VLD1`/`VLD2`, specifically on there being *four* registers rather
  than fewer) — not on datatype. Rather than a full per-mnemonic
  lookup table for something this regular, `encode_neon_ldst_multiple`
  computes `allow_128`/`allow_256` directly from `struct_class`/`count`,
  since every legal combination accepts at least `@64` and the
  boundary cases (which counts unlock `@128`/`@256`) are few enough to
  read as a couple of boolean expressions instead of another table.

### ARMv8-only VFP/NEON additions

`VMAXNM`/`VMINNM`, `VSELEQ`/`VSELGE`/`VSELGT`/`VSELVS`, the
directed-rounding `VRINT*` and `VCVTA`/`VCVTN`/`VCVTP`/`VCVTM` families,
and half-precision `VCVTB`/`VCVTT` are all implemented. General `VCVT`
(the plain integer/fixed-point conversions, everything other than
`VCVTB`/`VCVTT`) remains a deliberate gap, for the same reason given in
the classic VFP scalar section above: its real encoding packs
signedness and rounding-mode selection across non-adjacent bits in a
way that needs the same VFPLib-source-reading rigour as the `VMOV`/
`VMVN` cmode table, and this batch was already large and heterogeneous
enough (nine distinct encoding shapes across VFP scalar and NEON)
without adding a tenth.

- Most of these mnemonics have *both* a VFP-scalar form and a NEON
  form sharing one literal root: `VMAXNM`/`VMINNM`, and every
  `VRINT*`/`VCVTA`-family member except `VRINTR`. `VSELEQ`/etc and
  `VCVTB`/`VCVTT` are the exceptions — VFP-scalar only, no NEON form at
  all. Where both forms exist, the dispatch technique is the same
  peek-the-datatype-and-register-class trick as
  `encode_vfp_or_neon_arith3` from phase 3a: an `S` register is
  unambiguously scalar, an F64 datatype is unambiguously scalar (NEON
  has no F64 element type), and everything else (`D` with F32, or any
  `Q` register) is unambiguously NEON — no runtime ambiguity ever
  actually exists, it just isn't resolvable from the mnemonic root
  alone the way `match_mnemonic` normally works.
- The VFP-scalar forms are *not* all the same shape. `VMAXNM`/`VMINNM`
  and `VSEL*` and the `VRINTA`/`N`/`P`/`M`/`VCVTA`/`N`/`P`/`M` directed-
  rounding families use a new-in-ARMv8 encoding with the condition
  field forced to `1111` (genuinely unconditional, not just "always
  encoded as AL") — `allows_cond=0` in the mnemonic table for these,
  since there is no legacy conditional form to preserve. `VRINTR`,
  `VRINTZ` and `VRINTX`, by contrast, reuse VFP's *original* conditional
  encoding shape (they predate ARMv8 as conditional instructions and
  gained NEON counterparts later without losing that), so their table
  rows keep `allows_cond=1` and the encoder genuinely uses the parsed
  condition — verified by checking that only these three, of the whole
  batch, have a `cond[3:0]` field in VFPLib's raw encoding table rather
  than a fixed `1111`.
- `VRINTA`/`N`/`P`/`M`/`VCVTA`/`N`/`P`/`M`'s scalar and NEON syntax both
  double the datatype tag (`"VRINTA.F32.F32 Sd,Sm"`, not
  `"VRINTA.F32 Sd,Sm"`) — this looked like a documentation artefact of
  the table-extraction script at first, since the repeated tag is
  always redundant (both halves are always equal for `VRINT*`, and for
  `VCVT*` the first half is always `S32`/`U32`), but it is real UAL
  syntax for this instruction family specifically, confirmed by
  checking VFPLib's own lookup-table syntax strings rather than
  memory.
- `VCVTA`/`N`/`P`/`M`'s "op" (signed/unsigned) bit has **opposite
  polarity** between the VFP-scalar and NEON encodings — `S32` is
  `op=1` in the scalar `A1` table entry but `op=0` in the NEON `A1`
  entry (and `U32` the reverse). This is a real architectural quirk
  (VFP's bit means "is signed", NEON's same-position bit means "is
  unsigned"), not a typo in either this port or VFPLib's table; missing
  it would have silently swapped `VCVTA.S32`/`VCVTA.U32` for every NEON
  form while leaving the scalar form correct, so it was worth spelling
  out explicitly (`encode_vfp_or_neon_cvt_dir` computes the scalar `op`
  bit once and inverts it for the NEON branch, with a comment at the
  point of inversion rather than leaving it implicit).
- `VCVTB`/`VCVTT` (half-precision conversion) also double-tags, but
  asymmetrically: one tag must be `F16` and the other `F32`/`F64`,
  and which one is `F16` determines both the `op` bit (widening from
  half vs narrowing to half) and which of the two operand registers is
  constrained to always be single-precision (half-precision values
  always live in the bottom 16 bits of an `S` register, regardless of
  which "side" of the conversion they're on). This mnemonic has no
  NEON form at all, so it's a plain conditional scalar encoder with no
  dispatch needed.
- `VRINTR` is the one mnemonic in this batch with no NEON counterpart
  (real hardware only ever added `VRINTA`/`N`/`P`/`M`/`X`/`Z` to NEON,
  not `R`); its mnemonic-table row still carries a NEON "op" field
  slot for consistency with its `VRINTZ`/`VRINTX` siblings, set to the
  sentinel `0xFFFFFFFF` and checked explicitly in
  `encode_vfp_or_neon_rint` so writing `VRINTR.F32.F32 Qd,Qm` raises
  "NEON datatype is invalid for this mnemonic" rather than silently
  encoding something.
- The NEON forms of `VMAXNM`/`VMINNM` needed no new low-level encoding
  function at all — mechanically matching their raw bit-pattern
  against `assemble_neon_three_same`'s existing parameter layout (the
  same helper `VADD`/`VMAX`/etc already use) showed it was already
  general enough to express `U=1, opcode4=0xF, opbit=1` (the exact bits
  VFPLib's table uses for these two), so they're just two more
  mnemonic-table rows through the existing `FAMILY_NEON_3SAME`/
  `encode_neon_three_same` path. The `VRINT*`/`VCVTA`-family NEON forms
  similarly reuse `assemble_neon_two_reg_misc` (the "two registers
  misc" shape's existing low-level helper) rather than a new one --
  only the *dispatch and double-dt-tag parsing* around them is new.

### Classic 16-bit Thumb: `ASSEMBLE_ARM32_OPT_THUMB`

Ported from `armips/Archs/ARM/ThumbOpcodes.cpp` and
`CThumbInstruction.cpp` (the `@armips` reference clone alongside this
project -- see "Source material handling" below), read as ground truth
for each format's bit layout, field widths and immediate scaling/range
rules, the same discipline used for VFPLib elsewhere in this file.
Thumb is architecturally a *replacement* instruction encoding, not an
*addition* the way FPA/VFP are (many mnemonics -- `MOV`, `ADD`, `LDR`
-- exist in both dialects with completely different operand shapes and
encodings), so it is gated by its own OPT bit that is checked first,
before the base ARM32 dispatch, and hands off to a wholly separate
mnemonic table (`thumb_mnemonic_table`) and set of encoder functions;
setting `ASSEMBLE_ARM32_OPT_THUMB` makes `ASSEMBLE_ARM32_OPT_FPA`/
`ASSEMBLE_ARM32_OPT_VFP` irrelevant for that call.

- Every register operand still goes through the *same* `parse_register`
  used by base ARM32 (R0-R15, PC=15, LR=14, SP=13, or a numeric
  expression 0-15), so Thumb accepts identical register spellings.
  What's new is that most Thumb formats have a 3-bit register field,
  so `parse_thumb_lowreg` wraps `parse_register` with an explicit
  R0-R7 range check. armips itself has no equivalent check (its fields
  are set unconditionally from whatever the mask parser handed it,
  trusting the syntax already constrained the value) -- silently
  truncating an out-of-range register to 3 bits would encode a
  different, wrong instruction, so this port errors instead.
- Several mnemonics are genuinely polymorphic across multiple Thumb
  "formats" sharing one root -- `ADD`/`SUB` span four formats (THUMB.2
  register/immediate, THUMB.3 8-bit immediate, THUMB.12 PC/SP address
  generation, THUMB.13 SP adjustment), `MOV`/`CMP` span three each
  (low-immediate, low-register-as-low-ALU-op, hi-register), `LDR`/`STR`
  span up to four addressing shapes. Unlike the flat family-table
  dispatch base ARM32 uses (one fixed operand grammar per mnemonic
  root), each of these gets its own dedicated parsing function that
  decides the sub-shape from what it actually parses -- register vs
  `#imm`, presence of a further comma, whether a register is `PC`/`SP`
  -- rather than trying to force a single declarative shape onto all
  of them.
- `ADD Rd,PC/SP,#imm` (THUMB.12) and `ADD/SUB SP,SP,#imm` (THUMB.13's
  three-operand spelling) look ambiguous when `Rd` is `SP` and the
  base is also `SP` -- both nominally start "ADD SP,SP,...". They
  aren't actually ambiguous: THUMB.12's destination field is only 3
  bits wide, so it can never hold `SP` (register 13) at all. Checking
  `rd==13 && rn==13` for the THUMB.13 form *before* the general
  THUMB.12 check (which would otherwise reject a valid `rd==13` with
  "bad register" rather than falling through) resolves this cleanly by
  construction rather than by guesswork -- this was caught by
  re-deriving the ordering from the field widths rather than trusting
  a first draft.
- `MOV Rd,Rs` with both registers low has no dedicated low-register
  encoding in real Thumb at all -- like armips, it is synthesised as
  `ADD Rd,Rs,#0` (THUMB.2's *immediate* sub-form specifically, base
  encoding `0x1C00`, not the register sub-form `0x1800` a "two
  registers" reading might suggest; the second operand occupies the
  immediate form's `Rs` field with the 3-bit immediate left at zero).
- `LDRSB`/`LDRSH` (`LDSB`/`LDSH`) only have a register-offset
  addressing form (THUMB.8) -- there is no immediate-offset encoding
  for sign-extending loads anywhere in the Thumb ISA, unlike every
  other `LDR`/`STR` variant. Writing `LDRSB Rd,[Rn,#imm]` or the bare
  `LDRSB Rd,[Rn]` form raises a specific "only support register-offset
  addressing" error rather than a generic one, since this is a real
  architectural gap a user might otherwise assume is just unimplemented.
- `BLX` is two unrelated encodings sharing one mnemonic: `BLX Rm`
  (THUMB.5, register, interworking call) and `BLX label` (THUMB.19,
  the 32-bit two-halfword prefix pair, switches to ARM state). These
  are told apart by peeking whether a *named* register (`Rn`/`PC`/
  `LR`/`SP`) follows -- deliberately not reusing `parse_register`'s
  full numeric-expression fallback for this peek, since accepting a
  bare number as "a register" would make `BLX 4` ambiguous between
  "register R4" and "branch to address 4"; real Thumb assembly always
  spells the register form with a name.
- `BLX label`'s target must already be word-aligned (switching to ARM
  state requires it); unlike armips, which silently rounds an
  odd halfword-count up to the nearest word by adding `Immediate&1`,
  this port raises "Branch target ... out of range" instead of
  guessing what the caller meant. Deliberately simpler and more
  predictable than the reference at the cost of that one auto-rounding
  convenience, which in practice only matters for hand-computed
  non-symbolic BLX targets (any real function label is word-aligned
  already).
- `B`/`BL`/`BLX`/`Bcc` are dispatched by special-casing the mnemonic
  text directly in `assemble_thumb_line` (matching how base ARM32
  special-cases `LDR`/`STR`/`LDM`/`STM`/etc rather than using the flat
  table) rather than through `thumb_mnemonic_table`, because `Bcc`'s
  14 real conditions are recognised via the *same* `match_condition`/
  `cond_table` base ARM32 uses for its own condition-code suffixes
  (rejecting `AL`/`NV`, which Thumb's format16 has no encoding for --
  unconditional branches use the separate `B` mnemonic instead), and
  reusing it here means the alias spellings (`BHS`/`BCS`, `BLO`/`BCC`)
  come for free rather than needing their own table rows.
- Two deliberate, documented scope reductions, both chosen to stay
  *consistent* with base ARM32 rather than being Thumb-specific gaps:
  no `LDR Rd,=const` literal-pool pseudo-op (base ARM32's own `LDR`/
  `STR` handling has never supported literal pools, so adding one only
  for Thumb would be a new capability, not a like-for-like port), and
  no `ADR` pseudo-mnemonic (THUMB.12's PC/SP-relative address
  generation is written out explicitly as `ADD Rd,PC,#imm`/
  `ADD Rd,SP,#imm`, which is what armips' own mask strings actually
  spell it as regardless of the internal placeholder name used for it).

### RISC-V (`assemble_riscv`)

Not ported or reverse-engineered from a single source the way the other
backends are — `RISCV-RV32I-Assembler` (the reference clone alongside this
project — see "Source material handling" below) was read for instruction
coverage and general shape only; it's a teaching project implementing a
narrow subset of RV32I (no `FENCE`/`ECALL`/`EBREAK`/CSR, no
pseudo-instructions, and a non-standard three-operand comma syntax for
loads/stores/branches instead of the near-universal `rd, imm(rs1)` form).
This backend instead implements the complete RV32I base integer ISA per
the official spec, plus the six Zicsr CSR instructions, using the
standard assembly syntax real RISC-V toolchains use, and a mnemonic
table shaped like `assemble_6809`'s (one row per real mnemonic, since
unlike 6502/6809 every RV32I mnemonic has exactly one fixed operand
shape — no per-addressing-mode row multiplicity is needed).

Every encoding in `c/tests_riscv` was cross-checked against an
independent Python re-implementation of the R/I/S/B/U/J bit layouts
(not this backend's own code) before being written into the test table,
and several against well-known reference encodings (`add x1,x2,x3` =
`0x003100b3`, `addi x1,x0,5` = `0x00500093`, `ECALL` = `0x00000073`,
plain `FENCE` = `0x0ff0000f`) — the same "verify against something that
isn't the port itself" discipline as the x86-64 lessons above, applied
from the start rather than after a wrong first pass.

- RV32I has a single dialect; `context->opt` carries no CPU-specific
  bits (same convention as `assemble_6809`). There is no RV32M or
  RV64I support.
- Registers accept `x0`-`x31`, the standard ABI names (`zero`, `ra`,
  `sp`, `gp`, `tp`, `t0`-`t6`, `s0`-`s11`, `a0`-`a7`, `fp` as an alias
  for `s0`), or — matching `assemble_arm32`'s convention for computed
  register numbers — any expression evaluating to 0-31 (eg a BASIC
  variable).
- `AND`/`OR` are real three-operand RV32I mnemonics that collide with
  BASIC's own tokenised `AND`/`OR` keywords (`ANDI`/`ORI` too, since
  BASIC's tokeniser matches the keyword substring regardless of what
  follows) — handled the same way `assemble_6502`/`assemble_6809`/
  `assemble_z80` handle `AND`/`OR`/`EOR`: the token byte is expanded
  back to its ASCII spelling before the normal mnemonic reader runs.
  There's no RV32I `EOR` (it uses `XOR`), so only two tokens need this.
  `CALL` (the pseudo-instruction) collides too — a whole-word BASIC
  keyword, found later by the audit described in "BASIC token
  collisions" above, not caught by the original three-token pass.
- Loads, stores and `JALR` all share one `rd`/`rs2`, `imm(rs1)` operand
  parser (`FMT_I_MEM`/`FMT_S`), since the "paren offset" syntax and
  12-bit signed range are identical across all of them; only the
  opcode/funct3 and which register slot is the destination differ.
- Branch and jump offsets are PC-relative to *the branch/jump
  instruction's own address*, per the RV32I spec — unlike eg 6809's
  short branches, there is no "address after the instruction" fixup to
  apply, since RISC-V's `JAL`/`Bxx` offsets are defined relative to the
  instruction itself.
- `LI` and `CALL` are the only pseudo-instructions that expand to more
  than one real instruction (`LUI`+`ADDI`, `AUIPC`+`JALR`). Both always
  emit the full two-instruction (8 byte) form regardless of whether the
  value would fit in one instruction — deliberately, not an
  unoptimised port: this library assembles one source line at a time
  across multiple passes, and a line whose *size* depended on a
  forward-referenced label's eventual value would make the standard
  two-pass "size in pass 1, re-assemble in pass 2" flow unsound (the
  same reasoning that keeps `assemble_arm32` from ever supporting an
  `LDR Rd,=const` literal-pool pseudo-op). Fixing the size at 8 bytes
  regardless of value sidesteps the problem entirely, at the cost of
  never emitting the shorter 4-byte form when the value happens to fit.
- The zero-compare branch pseudo-instructions (`BEQZ`/`BNEZ`/`BGEZ`/
  `BLTZ`/`BLEZ`/`BGTZ`) are implemented as a small table mapping each
  to a real branch mnemonic plus which operand slot `x0` occupies,
  looked up via the same `find_opcode()` used for real mnemonics —
  avoids duplicating each real branch's opcode/funct3 a second time.

### m68k (`assemble_m68k`)

Not ported from a single source the way x86-64/6502/6809 are —
`m68k/` (github.com/Urethramancer/m68k, MIT-licensed, third-party Go
implementation, untracked — see "Source material handling" below) was
read for instruction coverage, addressing-mode encoding
(`assembler/helpers.go`'s `encodeEA`, the model behind
`m68k_encode_ea` here) and syntax shape. It covers the full standard
MC68000 instruction set with no 68010+/68020+/FPU/PMMU extensions,
matching this backend's own declared scope exactly. Every actual
opcode bit pattern in this backend was hand-derived from the real
MC68000 opcode map and cross-checked against known reference
encodings (`NOP`=`4E71`, `RTS`=`4E75`, and others), not copied from
that reference project's own code.

Three things the reference project got wrong or left incomplete,
found by cross-checking its own test suite and docs against each
other rather than trusting it as a single oracle (the same discipline
as the x86-64/RISC-V lessons above):

- `MOVE from CCR` (`CCR,<ea>`) is a 68010 addition, not genuine
  MC68000 — the reference implements it anyway (with its own code
  comment admitting the discrepancy), but its own `docs/instructions.txt`
  catalogue omits it while listing `MOVE to CCR` as legitimate. This
  backend rejects `MOVE from CCR` (`ASSEMBLE_M68K_ERR_NOT_ON_MC68000`)
  and implements `MOVE to CCR`, `MOVE to/from SR` and `MOVE to/from USP`.
- `CMPM` is listed in the reference's own instruction catalogue but has
  no implementation anywhere in its code — its encoding was derived
  and verified independently, not ported.
- `ROXL`/`ROXR` have opcode-table entries in the reference but are
  never actually wired into its mnemonic dispatch (dead table rows) —
  the opcode bits were trustworthy to reuse, the encoder wiring and
  test vectors needed deriving fresh.

Design points specific to this backend, beyond the general
addressing-mode/registry/directive conventions above:

- Real MC68000 opcodes are bit-field encoded from EA/register/size,
  not one row per mnemonic+mode the way 6809/6502 use — so
  `m68k_mnemonics[]` carries a `family` tag and a per-family encoder
  function does the real work, the same shape `assemble_arm32` uses,
  rather than a flat literal opcode table.
- `ADD`/`SUB`/`CMP`/`AND`/`OR` auto-detect which real opcode shape
  their operands require (plain register form, the `ADDA`/`CMPA`-
  shaped address-register-destination form, or the `ADDI`/`CMPI`-
  shaped immediate-to-memory form) from the parsed operands'
  addressing modes — this is *not* the same kind of relaxation
  `MOVEQ`/`ADDQ`/`SUBQ`'s deliberate non-auto-selection avoids (see
  `h/assemble_m68k`'s deficiencies comment): only one of those
  encodings is ever legal for a given combination of addressing
  modes, so there's no genuine choice being made, unlike shortening
  `MOVE.L #imm,Dn` to `MOVEQ` based on the immediate's *value*.
- `Bcc`/`BRA`/`BSR` require an explicit `.S`/`.W` displacement-size
  suffix (no relaxation, same reasoning as RISC-V's `LI`/`CALL`
  always emitting their fixed-size form); the displacement is always
  computed against the address of the extension word that would
  follow the opcode (`context->address + 2`, plus a `pc_bias` for a
  second operand's own PC-relative extension), not the opcode's own
  address, matching real MC68000 timing.
- `Bcc`/`Scc`/`DBcc` (46 mnemonics: 14 real `Bcc` conditions + `BRA` +
  `BSR`, 16 `Scc`, 16 `DBcc`) are recognised structurally — a
  `B`/`S`/`DB` prefix or root plus a condition-code suffix matched
  against the 16 standard conditions (`CC`/`HS` and `CS`/`LO`
  accepted as synonyms) — rather than as 46 separate mnemonic-table
  rows, the same technique `assemble_arm32` uses for its own
  condition-code suffix mnemonics. This is tried only after an exact
  `find_mnemonic()` lookup fails, so it can never shadow a real table
  entry.
- `MOVEM`'s register-list mask is bit-reversed for a predecrement
  destination (`m68k_reverse_movem_mask`) — verified algebraically
  that `predecrement_bit(Rn) = 15 - normal_bit(Rn)` holds for both the
  `D0`-`D7` and `A0`-`A7` register groups, rather than assumed from a
  half-remembered convention.
- `AND`/`OR`/`EOR`/`NOT` collide with BASIC's tokenised keywords
  (`&80`/`&84`/`&82`/`&AC`, confirmed directly against
  `riscos-basictokenise`'s own token table), handled the same way
  `assemble_6809`/`assemble_z80`/`assemble_riscv` handle their own
  colliding keywords — `NOT` is a new fourth case none of those
  backends needed, since none of them has a bare `NOT` mnemonic
  (`assemble_6809` has `COM`, `assemble_riscv` has `XOR` not `EOR`/`NOT`).
  A later audit (see "BASIC token collisions" above) found this backend
  has five *more* collisions the initial pass missed: `DIV` (hits
  `DIVU`/`DIVS`), `MOVE` (hits `MOVE` itself plus every `MOVEx`
  mnemonic — `MOVEA`/`MOVEQ`/`MOVEM`/`MOVEP` and the `MOVE SR/CCR/USP`
  special forms, all via one token byte), `EXT`, `STOP`, and `SWAP`
  (the only token in this library that's two bytes, not one — a BASIC V
  structured-programming keyword, `C8 94`).
- Directive syntax is selectable via `ASSEMBLE_M68K_OPT_NATIVE_DIRECTIVES`
  (bit 4): clear (default) gives the shared `DCB`/`DCW`/`DCD`
  convention (matching 6502/6809/RISC-V); set gives idiomatic 68k
  `DC.B`/`DC.W`/`DC.L`/`DS.B`/`DS.W`/`DS.L`. `read_mnemonic()` gains a
  special case scoped to just the `DC`/`DS` roots to consume a
  trailing `.`+size-letter as part of the mnemonic token itself —
  every other mnemonic's size suffix is parsed separately by
  `parse_size_suffix()`, after the mnemonic root. Unlike the reference
  project, `DC.B`/`DCB` don't auto-pad odd lengths to an even boundary
  (matching every other backend's `DCB` convention here) — this
  matters more on m68k than elsewhere, since an odd-addressed
  word/long access raises a genuine Address Error exception on real
  MC68000 hardware.

## The Assembler module (`module/`)

A separate RISC OS **module** component, `Assembler`, lives in its own
`module/` subtree with its own `Makefile,fe1`, `VersionNum`, `cmhg/modhead`,
PRM-in-XML docs (`module/prminxml/Assembler.xml`) and smoke test
(`module/tests/test-assembler,fd1`) — it is versioned independently of the
top-level `Assemble` library (currently 0.02 vs the library's 0.05) and gets
its own `riscos-vmanage inc` when it changes. It wraps the Assemble library's
line-at-a-time backends in a **stateful** SWI interface (`Assemble_Create`,
`Destroy`, `BeginPass`, `AssembleLine`, `Value`, `Evaluate`, `Capabilities`,
`LastError`) — a context owns a symbol table and pass/address state across
many `Assemble_AssembleLine` calls, which the library's own `assemble_context_t`
has no notion of (that's just one call's inputs/outputs).

**RISC OS Open allocation status**: the registration request
(`module/allocations/Assembler-allocation.yaml`/`,fb0`/`-email.txt`, sent to
`allocate@riscosopen.org` on 2026-08-14, cc'd to Charles Ferguson) has now
been answered, and `module/cmhg/modhead` carries the real allocated values —
SWI chunk `&5AD80` (was the placeholder `&C0000`) and error base `&822E00`
(was `&840000`), both marked `ALLOCATED` in comments in place of the old
`UNALLOCATED` warnings. One thing to note if you touch this again: the
allocated SWI prefix is `Assemble`, not `Assembler` as the request itself
asked for — `swi-decoding-table`'s first field changed along with the
numbers, so every SWI is `Assemble_Create`/`Assemble_Destroy`/
`Assemble_BeginPass`/`Assemble_AssembleLine`/`Assemble_Value`/
`Assemble_Evaluate`/`Assemble_Capabilities`/`Assemble_LastError`
(`&5AD80`-`&5AD87`) even though the module's own `title-string`/
`help-string`/`*Command` name is still `Assembler`. The SWI/error numbers
are now final; there's no longer a reason on this account to withhold public
release. See the `allocating-resources` skill for the registration process
and the `sending-email` skill for how the email itself was sent.

Build order matters: `module/Makefile,fe1` has `INCLUDES = C:Assemble.` and
`LIBS = C:Assemble.o.libAssemble`, so the top-level `MakefileLib,fe1` must be
built *and exported* (`riscos-amu -f MakefileLib export_hdr export_libs`)
before the module will build against current headers/objects — building the
module against a stale export after a library change fails or silently uses
old behaviour, it doesn't re-export automatically. Build with
`riscos-amu -f Makefile,fe1` from `module/`; run the smoke test with
`riscos-amu -f Makefile,fe1 test` (its `.PHONY: test` target does the
`riscos-build-run rm32/Assembler,ffa tests/test-assembler,fd1 --command
"RMLoad Assembler" --command "Run test-assembler"` dance for you).

`module/c/module` used to hand-maintain its own `cpu_assembler()`
switch-per-backend and its own `Assemble_Capabilities` CPU/OPT bitmasks,
duplicating the backend registry (`h/assemble_registry` — see "Backend
registry" above) that now exists for exactly this purpose. It has been
converted to use the registry instead:

- `cpu_assembler()` is one call to `assemble_find_by_class()`. This relies on
  the module's own public `assembler_cpu_t` enum (`module/h/assembler`) being
  numbered **identically** to the library's `assemble_cpu_class_t` — the SWI's
  CPU ID is cast straight across with no translation table. If you add a
  backend to the registry and want the module to expose it, add the matching
  value to `assembler_cpu_t` with the *same number*, not just any unused one.
  This is exactly how RISC-V (`ASSEMBLE_CPU_RISCV = 6`) was wired up as
  `ASSEMBLER_CPU_RISCV = 6` — a two-line change, not a new switch case.
- `Assemble_Capabilities` (SWI `&5AD86`) builds its CPU bitmask (query 0) and
  per-CPU OPT-bit mask (query 1) by walking `assemble_get_interfaces()` and
  each entry's `opt_flags`, rather than hard-coding them. This isn't just
  smaller code: the hard-coded version had actually drifted out of date
  before this change (it reported ARM32's OPT mask as `&30`, FPA+VFP only,
  missing the `&40` Thumb bit added when classic Thumb support was ported) —
  the sort of thing that's easy to miss by hand and impossible to miss once
  it's derived from the same table the backends themselves are dispatched
  through. Converting a hard-coded mirror of shared state into a live query
  against the real source of truth is worth doing on sight, not just when
  asked, if you notice one drifting like this elsewhere.
- The registry's `assemble_line_fn` function-pointer typedef replaced a
  private, identically-shaped `assembler_fn` typedef the module used to
  declare for itself — another small duplication the registry made
  unnecessary.

## Source material handling

Reference material lives alongside the project but is **not part of the
build and not tracked in git**: `6502/`, `6809/` (the tokenised `.ffb`
patches and their `Guide,fff` docs), `riscos64-rtrussell-bbcbasic/` (a
full clone of the BBC BASIC source this port is based on), `armips/`
(a clone of the armips cross-assembler, whose `Archs/ARM/ThumbOpcodes.cpp`/
`CThumbInstruction.cpp` were read as ground truth for the classic Thumb
backend), `RISCV-RV32I-Assembler` (a teaching RV32I assembler read
for instruction coverage and general shape, not syntax — see the
RISC-V section above), and `m68k/` (a third-party Go 68000 assembler/
disassembler/VM, read for instruction coverage and addressing-mode
encoding shape, not ported directly — see the m68k section above).
Don't add these to git, and don't treat anything under
`/riscos-built/Sources` as canonical (per the global project instructions)
— if you need to re-examine the 6502/6809 patches, detokenise with
`riscos-basicdetokenise -i <file>` first (see the `using-bbcbasic` skill).

## Coding conventions

Standard project conventions apply (see `writing-c` skill): C89, 4-space
indent, braces on their own line, function prologue comments in headers, no
trailing whitespace. A few conventions specific to this library, established
across the existing backends and worth keeping consistent if you add another:

- One `assemble_<name>_line()` entry point per backend, handling `.label`
  definitions (assigning the current address) and falling through to parse
  a real instruction on the same line if there's more after the label.
- `EQU` (where a backend supports it) requires a preceding `.label` on the
  same line and assigns the expression's *value*, not the address.
- `OPT <expr>` is always a no-op that just validates/consumes its
  expression — pass/listing control is the caller's responsibility.
- Pseudo-ops that emit raw data (`DCB`/`DCW`/`DCD` for 6502/6809/RISC-V/
  m68k, or `DB`/`DW`/`DD`/`DQ`/`EQUB`/`EQUD`/`EQUQ`/`EQUW` for x86-64,
  which are ordinary table-driven mnemonics there, not special-cased)
  use the backend's native endianness (little-endian for
  6502/x86-64/RISC-V, big-endian for 6809/m68k).
- Every header (`h/assemble_common` and every backend/registry header) has
  a "Known deficiencies"/"Known limitation(s)" comment, placed right after
  the `#include`s and before the main type declarations, stating plainly
  what the file doesn't do rather than leaving a gap for a reader to
  discover the hard way (eg x86-64's missing privileged/SSSE3/SSE4/AVX
  coverage, ARM32's omitted DSP-multiply/banked-MSR/FPA-LFM-SFM
  instructions, RISC-V's missing RV32M/RV32A/RV32F/RV32D/RV32C/RV64 and
  LI/CALL never relaxing to a shorter encoding, the registry's static
  compiled-in-only backend/alias tables). A backend with nothing currently
  known to be missing still gets the comment, saying so explicitly (eg
  6502, 6809) — add one when you add a header, and update it when you
  learn of (or deliberately accept) a new gap, rather than letting the
  gap go undocumented until someone hits it.

## Git workflow

Feature branches only — never commit directly to `master`. This repo now
has a real GitHub remote (`origin` → `gerph/riscos-assembler-lib`); nothing
should be pushed without being explicitly asked to. Keep commits scoped to
one backend/feature per commit where practical (see the existing history:
one commit per backend added).
