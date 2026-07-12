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

Three backends exist today:

| Backend      | Files                                    | Instruction set(s)              |
|--------------|-------------------------------------------|----------------------------------|
| 6502         | `h/assemble_6502`, `c/assemble_6502`       | 6502, 65C02, 65C816 (dialect via OPT bits) |
| 6809         | `h/assemble_6809`, `c/assemble_6809`       | 6809 (single dialect)            |
| x86-64       | `h/assemble_x86_64`, `c/assemble_x86_64`   | x86-64, limited (see below)      |

Shared infrastructure lives in `h/assemble_common` / `c/assemble_common`.

## Building and testing

```
riscos-amu                # 32-bit build
riscos-amu BUILD64=1      # 64-bit build (compile-check only in this
                           # environment; 64-bit AIFs aren't runnable here)
riscos-build-run aif32 --command "run aif32.Assemble"   # run all self-tests
```

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
