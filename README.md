# Assemble

A RISC OS library providing **line-at-a-time assemblers** for several CPU
instruction sets, all built against one shared interface. It is intended to
be driven one source line at a time by a host such as a BASIC inline
assembler, assembling a `[...]` block line-by-line across one or more
passes.

The library itself builds as a `command` type project; the resulting
`Assemble` binary's `main()` runs the self-test suite for every backend and
exits with a non-zero status if any test fails. There is currently no BASIC
integration — nothing wires this into BASIC's own inline assembler — but the
interface is designed to make that straightforward for a future caller.

## Backends

| Backend | Header             | Source               | Instruction set(s)                          |
|---------|--------------------|-----------------------|----------------------------------------------|
| 6502    | `h.assemble_6502`  | `c.assemble_6502`     | 6502, 65C02, 65C816 (dialect via `opt` bits) |
| 6809    | `h.assemble_6809`  | `c.assemble_6809`     | 6809                                          |
| x86-64  | `h.assemble_x86_64`| `c.assemble_x86_64`   | x86-64 (limited subset, see below)            |
| Z80     | `h.assemble_z80`   | `c.assemble_z80`      | Z80 (including common undocumented forms)     |
| ARM32   | `h.assemble_arm32` | `c.assemble_arm32`    | Base ARM (ARMv4 through the AArch32 subset of ARMv8) + legacy FPA + classic VFP scalar + partial NEON/SIMD (dialect via `opt` bits, see below) |

Shared infrastructure (the assembly context, error reporting, byte/word
emission helpers) lives in `h.assemble_common` / `c.assemble_common`.

## Building and testing

```
riscos-amu                # 32-bit build
riscos-amu BUILD64=1      # 64-bit build
```

Run the self-tests (all backends, one combined pass/fail count):

```
riscos-build-run aif32 --command "run aif32.Assemble"          # 32-bit
riscos-build-run --64 aif64 --command "run aif64.Assemble"     # 64-bit
```

## Using a backend

Every backend exposes a single entry point, called once per source line:

```c
_kernel_oserror *assemble_<name>_line(assemble_context_t *context,
                                       const uint8_t *line,
                                       size_t line_length);
```

for example `assemble_6502_line`, `assemble_6809_line`,
`assemble_x86_64_line` and `assemble_z80_line`.

A call assembles exactly one line — it never sees a whole `[...]` block at
once. The caller is responsible for looping over the source lines and for
driving multiple passes (eg an undefined-length pass to size the output,
followed by a real pass once addresses are known).

### The assembly context

```c
typedef struct assemble_context
{
    uint8_t  *buffer;           /* Destination for assembled bytes, or NULL if buffer_length < 0 */
    int32_t   buffer_length;    /* Capacity of buffer in bytes, or -1 if undefined */
    uint32_t  address;          /* Logical address (P%) being assembled for */
    uint32_t  opt;              /* BASIC OPT setting; see ASSEMBLE_OPT_* and the CPU backend's header */

    assemble_resolve_expr_fn resolve_expr;
    assemble_assign_var_fn   assign_var;
    void                     *user_data; /* Passed through to the callbacks above, untouched */

    uint32_t  bytes_used;       /* [[out]] Bytes written, or that would have been written */
} assemble_context_t;
```

- `buffer` / `buffer_length` — where assembled bytes are written. Set
  `buffer_length` to `-1` (with `buffer` optionally `NULL`) for a
  size-only pass; `bytes_used` still comes back with the number of bytes
  that *would* have been written.
- `address` — the logical address (BASIC's `P%`) the line assembles for.
  This is distinct from `buffer`, since code can be assembled in one place
  and intended to run in another (`P%` vs `O%` in BASIC terms).
- `opt` — the BASIC `OPT` value. Bits 0–1 (`ASSEMBLE_OPT_LIST`,
  `ASSEMBLE_OPT_ERROR`) carry the standard BASIC meaning and are the
  caller's concern; the assembler itself just validates and consumes an
  `OPT <expr>` line without acting on it. CPU-specific dialect bits start
  at bit 4 (eg 6502's 65C02/65C816 selection — see below); backends with a
  single dialect (6809, x86-64, Z80) don't use any extra bits.
- `resolve_expr` / `assign_var` — callbacks into the host's own expression
  evaluator and variable table (see signatures below). `resolve_expr`
  parses an expression at the start of a source fragment and returns a
  tagged `assemble_value_t` (integer, float or string) plus how many bytes
  it consumed. `assign_var` is how `.label` definitions (and, where
  supported, `EQU`) write a value back to the host.
- `bytes_used` — filled in by the call with the number of bytes written
  (or that would have been written on a size-only pass). The caller must
  advance `buffer` and `address` by this amount itself before the next
  call.

```c
typedef assemble_result_t (*assemble_resolve_expr_fn)(void *user_data,
                                                        const uint8_t *text,
                                                        size_t length,
                                                        assemble_value_t *value,
                                                        size_t *consumed,
                                                        _kernel_oserror **error);

typedef assemble_result_t (*assemble_assign_var_fn)(void *user_data,
                                                      const char *name,
                                                      size_t name_length,
                                                      const assemble_value_t *value,
                                                      _kernel_oserror **error);
```

### Minimal example

```c
#include "assemble_common.h"
#include "assemble_6502.h"

assemble_context_t context = {0};
uint8_t code[256];
_kernel_oserror *error;

context.buffer        = code;
context.buffer_length = sizeof(code);
context.address       = 0x8000;
context.opt           = ASSEMBLE_OPT_LIST | ASSEMBLE_OPT_ERROR;
context.resolve_expr  = my_resolve_expr;
context.assign_var    = my_assign_var;
context.user_data     = my_state;

error = assemble_6502_line(&context, (const uint8_t *) "LDA #&FF", 8);
if (error != NULL)
{
    /* error->errmess is human readable; ASSEMBLE_ERRNUM_* macros in
       assemble_common.h decode error->errnum for programmatic handling */
}
else
{
    context.buffer  += context.bytes_used;
    context.address += context.bytes_used;
}
```

### 6502 dialect selection

The 6502 backend supports three dialects, selected via `opt` bits, matching
the convention used by the historical `Basic6502` patch this backend was
reverse-engineered from:

```c
#define ASSEMBLE_6502_OPT_65C02  (1u << 4)  /* 0x10 */
#define ASSEMBLE_6502_OPT_65C816 (1u << 5)  /* 0x20 */
```

Neither bit set selects plain 6502; `65C816` implies `65C02` too.

### Pseudo-ops

- `.label` on its own (optionally followed by an instruction on the same
  line) assigns the current address to a label.
- `EQU` (6502, 6809) requires a preceding `.label` on the same line and
  assigns the expression's *value* rather than the address. The x86-64 and
  Z80 backends have no `EQU`.
- `OPT <expr>` is always a no-op that validates/consumes its expression;
  pass and listing control is the caller's responsibility, not the
  assembler's.
- Data pseudo-ops emit raw bytes in the target CPU's own endianness:
  `DCB`/`DCW`/`DCD` (6502, 6809, big-endian on 6809); `DEFB`/`DB`,
  `DEFW`/`DW`, `DEFM`/`DM` (Z80, little-endian); `DB`/`DW`/`DD`/`DQ`/
  `EQUB`/`EQUD`/`EQUQ`/`EQUW` (x86-64, ordinary table-driven mnemonics
  there, little-endian).

### Error reporting

Errors come back as a `_kernel_oserror *` (`NULL` on success) pointing at a
static, per-backend error block, safe because RISC OS is single-threaded and
there is never more than one live error at a time. `errnum` is packed so a
caller can inspect it as generically or as specifically as needed:

```c
#define ASSEMBLE_ERRNUM(cpu_class, type, variant) ...

ASSEMBLE_ERRNUM_CPU_CLASS(errnum)   /* assemble_cpu_class_t  - which backend */
ASSEMBLE_ERRNUM_TYPE(errnum)        /* assemble_error_type_t - coarse, shared category */
ASSEMBLE_ERRNUM_VARIANT(errnum)     /* backend-specific detail, or 0 */
```

`assemble_error_type_t` (bad mnemonic, bad operand, unsupported on this
variant, expression error, bad label, buffer overflow, range, syntax,
internal) is shared across all backends; each backend also has its own
`assemble_<name>_error_variant_t` enum for finer detail, documented in that
backend's header.

### Known limitation: x86-64

The x86-64 backend is a limited subset, matching the BBC BASIC source it was
ported from: no privileged instructions, no SSSE3/SSE4/AVX. `MOV reg64,
name`, resolving a BASIC/OS routine name to its address, needs a live
runtime function registry this library has no equivalent of, and raises
`ASSEMBLE_X86_64_ERR_SYSTEM_CALL_UNSUPPORTED` instead. Embedding a string
literal's raw bytes as immediate data still works.

### Known limitation: ARM32

Base ARM32, legacy FPA and classic VFP scalar are implemented. NEON/SIMD
is being added incrementally, gated by the same `ASSEMBLE_ARM32_OPT_VFP`
bit as classic VFP scalar (NEON extends the same dialect rather than
adding a new one); so far this covers:

* the "three registers of the same length" family — `VADD`, `VSUB`,
  `VMUL`, `VMLA`, `VMLS`, `VAND`, `VBIC`, `VORR`, `VORN`, `VEOR`, `VBSL`,
  `VBIT`, `VBIF`, `VQADD`, `VQSUB`, `VRSHL`, `VQSHL`, `VQRSHL`, `VHADD`,
  `VHSUB`, `VRHADD`, `VABA`, `VABD`, `VCEQ`, `VCGE`, `VCGT`, `VCLE`,
  `VCLT`, `VTST`, `VQDMULH`, `VQRDMULH`, `VACGE`, `VACGT`, `VACLE`,
  `VACLT`, `VMAX`, `VMIN`, `VPMAX`, `VPMIN`, `VPADD`;
* the "two registers misc" family — `VABS`, `VNEG`, `VCLS`, `VCLZ`,
  `VCNT`, `VMVN`, `VQABS`, `VQNEG`, `VRECPE`, `VRSQRTE`, `VREV16`,
  `VREV32`, `VREV64`, `VSWP`, `VTRN`, `VUZP`, `VZIP`, plus the `#0`
  comparison form of `VCEQ`/`VCGE`/`VCGT`/`VCLE`/`VCLT`;
* shift-by-immediate — `VSHL`, `VSHR`, `VSRA`, `VRSHR`, `VRSRA`, `VSRI`,
  `VSLI`, `VQSHL`, `VQSHLU`, `VSHLL`, `VSHRN`, `VRSHRN`, `VQSHRN`,
  `VQSHRUN`, `VQRSHRN`, `VQRSHRUN`;
* long/wide/narrow arithmetic — `VADDL`, `VADDW`, `VSUBL`, `VSUBW`,
  `VADDHN`, `VSUBHN`, `VRADDHN`, `VRSUBHN`, `VABAL`, `VABDL`, `VMLAL`,
  `VMLSL`, `VMULL`, `VQDMLAL`, `VQDMLSL`, `VQDMULL`, `VMOVL`, `VMOVN`,
  `VQMOVN`, `VQMOVUN`, `VPADAL`, `VPADDL`;
* the "by scalar" `Dm[x]` operand form of `VMUL`, `VMLA`, `VMLS`,
  `VMLAL`, `VMLSL`, `VMULL`, `VQDMULH`, `VQRDMULH`, `VQDMULL`,
  `VQDMLAL` and `VQDMLSL`;
* move-immediate (`VMOV`/`VMVN`, byte/halfword/per-byte-replicate
  forms only — see the ARM32 section of `AGENTS.md` for what's
  deliberately not covered), `VDUP` (from a scalar lane or an ARM core
  register), `VEXT` and `VTBL`/`VTBX`;
* structure load/store — `VLD1`/`VLD2`/`VLD3`/`VLD4`/`VST1`/`VST2`/
  `VST3`/`VST4`, "multiple" (register-list) addressing only — the
  "single lane" and "single all lanes" (replicate) addressing forms
  are not implemented (see `AGENTS.md`).

Everything else NEON (the two structure load/store forms above, and
convert/ARMv8-only additions such as `VRINT*`, `VSEL*`, `VMAXNM`/
`VMINNM` and directed-rounding `VCVT`) remains a follow-on. Within
base ARM32, the ARMv5TE/v6 'xy' DSP
multiply family (`SMLABB`, `SMLAWx`, `SMUAD`, `SMLAD`, `SMLALD` and
friends), `SMMLA`/`SMMLS`/`SMMUL`, `MRRC`/`MCRR`, the ARMv8 `LDA`/`STL`/
`LDAEX`/`STLEX` load-acquire/store-release family, and the banked-register
form of `MSR`/`MRS` (hypervisor-mode register access) are not yet
implemented and raise "Mnemonic not recognised". Within FPA, `LFM`/`SFM`
(multiple-register stack transfer) are omitted for the same reason.
Within VFP, `VCVT` (all forms) and the `VMOV`-immediate and two-core-
register transfer forms are omitted — see `AGENTS.md` for detail on all
of these.

A syntax quirk worth knowing: unlike every other ARM mnemonic, `LDR`,
`STR`, `LDM`, `STM`, `SWP`, the long-multiply family (`UMULL`/`UMLAL`/
`SMULL`/`SMLAL`), the generic coprocessor instructions (`CDP`, `MCR`,
`MRC`, `LDC`, `STC`) and the FPA mnemonics all write their size,
addressing-mode or precision suffix **after** the condition code —
`LDREQB`, not `LDRBEQ`; `ADFEQDP`, not `ADFDPEQ`. VFP mnemonics instead
separate the condition from a `.F32`/`.F64` datatype suffix with a dot,
following normal UAL syntax — `VADDEQ.F64`, not `VADD.F64EQ`.

### FPA dialect: `ASSEMBLE_ARM32_OPT_FPA`

FPA mnemonics (`ADF`, `MUF`, `SUF`, ..., `LDF`, `STF` — the legacy
floating-point coprocessor instruction set, superseded by VFP decades
ago but still assembleable code some RISC OS software targets) are only
recognised when `context->opt` has `ASSEMBLE_ARM32_OPT_FPA` (bit 4) set;
using one without the bit set raises `ASSEMBLE_ERROR_TYPE_UNSUPPORTED_ON_VARIANT`
rather than "mnemonic not recognised", so a caller can distinguish
"this needs the FPA dialect enabled" from a genuine typo. FPA registers
are written `F0`-`F7`. Arithmetic mnemonics need a mandatory precision
suffix (`S`/`D`/`E` for single/double/extended) and accept an optional
rounding-mode suffix (`P`/`M`/`Z` for round to +infinity/-infinity/zero,
default is round to nearest) — eg `ADFD F0,F1,F2`, `ADFDP F0,F1,F2`.
`LDF`/`STF` take the same precision letters plus `P` (packed decimal).
Immediate operands (`#imm`) must be exactly one of the 8 constants the
hardware supports: `0, 1, 2, 3, 4, 5, 0.5, 10`.

### VFP dialect: `ASSEMBLE_ARM32_OPT_VFP`

Classic VFPv2/VFPv3 scalar mnemonics (`VMOV`, `VADD`, `VSUB`, `VMUL`,
`VMLA`, `VMLS`, `VNMLA`, `VNMLS`, `VNMUL`, `VDIV`, `VABS`, `VNEG`, `VSQRT`,
`VCMP`, `VCMPE`, `VLDR`, `VSTR`, `VLDMIA`/`VLDMDB`/`VSTMIA`/`VSTMDB`,
`VPUSH`, `VPOP`, `VMRS`, `VMSR`) are only recognised when `context->opt`
has `ASSEMBLE_ARM32_OPT_VFP` (bit 5) set, with the same
"UNSUPPORTED_ON_VARIANT vs mnemonic-not-recognised" distinction as FPA.
VFP registers are written `S0`-`S31` (single-precision) or `D0`-`D31`
(double-precision) and, unlike FPA, operands are not required to be a
single register class across a whole instruction stream — but every
register *within one instruction* must be the same precision, matching
the datatype suffix (`ADD.F32 S0,D1,S2` is rejected). Most arithmetic
and comparison mnemonics need a mandatory `.F32`/`.F64` datatype suffix
written **after** the condition code, UAL-style — eg `VADDEQ.F64
D0,D1,D2`. `VMOV` between an ARM core register and a single-precision
register (`VMOV S0,R0` / `VMOV R0,S0`) takes no datatype suffix at all;
the encoder tells the two `VMOV` forms apart by whether a `.` follows.
`VCMP`/`VCMPE` additionally accept `#0` (or `#0.0`) in place of the
second register, comparing against zero.

### Platform constraint: no 64-bit integer type

The 32-bit build has no `long long`/`int64_t`/`uint64_t` (the Norcroft
32-bit compiler doesn't support one), so `assemble_value_t` only carries a
32-bit integer throughout, even though the library also targets 64-bit
builds from the same source. `assemble_emit_qword` emits a 64-bit value by
sign-extending a 32-bit one for this reason — there is no way to pass a
genuine 64-bit immediate through this interface.

## Licence

MIT.
