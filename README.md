# Assemble

A RISC OS library providing **line-at-a-time assemblers** for several CPU
instruction sets, all built against one shared interface. It is intended to
be driven one source line at a time by a host such as a BASIC inline
assembler, assembling a `[...]` block line-by-line across one or more
passes.

The project builds as three pieces: `MakefileLib` builds the `libAssemble`
library itself (the backends below, plus exported headers); `MakefileTests`
builds an `AssembleTest` command that runs every backend's self-test suite
and exits with a non-zero status if any test fails; `Makefile` builds a real
`*Assemble -cpu <cpu> -input <source> -output <binary>` command-line tool
linked against `libAssemble`. There is currently no BASIC integration —
nothing wires this into BASIC's own inline assembler — but the interface is
designed to make that straightforward for a future caller.

## Backends

| Backend | Header             | Source               | Instruction set(s)                          |
|---------|--------------------|-----------------------|----------------------------------------------|
| 6502    | `h.assemble_6502`  | `c.assemble_6502`     | 6502, 65C02, 65C816 (dialect via `opt` bits) |
| 6809    | `h.assemble_6809`  | `c.assemble_6809`     | 6809                                          |
| x86-64  | `h.assemble_x86_64`| `c.assemble_x86_64`   | x86-64 (limited subset, see below)            |
| Z80     | `h.assemble_z80`   | `c.assemble_z80`      | Z80 (including common undocumented forms)     |
| ARM32   | `h.assemble_arm32` | `c.assemble_arm32`    | Base ARM (ARMv4 through the AArch32 subset of ARMv8) + legacy FPA + classic VFP scalar + partial NEON/SIMD (dialect via `opt` bits, see below) |
| RISC-V  | `h.assemble_riscv` | `c.assemble_riscv`    | RV32I base integer ISA + Zicsr, plus the standard NOP/MV/LI/J/JR/RET/CALL/branch-vs-zero pseudo-instructions |
| m68k    | `h.assemble_m68k`  | `c.assemble_m68k`     | Motorola MC68000, base instruction set only (dialect via `opt` bit for directive syntax, see below) |

Shared infrastructure (the assembly context, error reporting, byte/word
emission helpers) lives in `h.assemble_common` / `c.assemble_common`.

## Discovering backends at runtime

A caller doesn't need to know the seven backends above in advance, or
`#include` each backend's own header directly: `h.assemble_registry` /
`c.assemble_registry` provide a directory of every backend, so a caller can
enumerate what's available or look one up by CPU class or by name.

```c
typedef struct assemble_interface
{
    assemble_cpu_class_t       cpu_class;
    const char                *name;                 /* eg "arm32" */
    const char                *description;
    assemble_line_fn            assemble_line;         /* eg assemble_arm32_line */
    uint32_t                    max_instruction_length; /* minimum output buffer size, in bytes */
    const assemble_opt_flag_t  *opt_flags;             /* CPU-specific OPT bits, or NULL */
    size_t                      opt_flag_count;
} assemble_interface_t;

const assemble_interface_t *assemble_get_interfaces(size_t *out_count);
const assemble_interface_t *assemble_find_by_class(assemble_cpu_class_t cpu_class);
const assemble_interface_t *assemble_find_by_name(const char *name, uint32_t *out_default_opt);
```

`max_instruction_length` is the worst case for a genuine fixed-shape
instruction or pseudo-instruction on that backend — enough to size a minimum
output buffer. It deliberately excludes pseudo-ops that take an unbounded
comma-separated list (`DCB`/`DCW`/`DCD`, `DEFM`) or a string-literal operand,
which have no fixed upper bound (see each backend's own header, or
`AGENTS.md`, for exactly which those are and how the figure below was
derived):

| Backend | `max_instruction_length` | Worst case |
|---------|--------------------------|------------|
| 6502    | 4  | 65C816 absolute-long addressing (1 opcode + 3-byte address) |
| 6809    | 5  | page-2-prefixed opcode (2 bytes) + 16-bit indexed offset, or extended-indirect `[nnnn]` |
| x86-64  | 13 | segment prefix + REX + opcode + ModRM + SIB + disp32 + imm32 |
| Z80     | 4  | `DD`/`FD CB`-prefixed bit/rotate/shift on `(IX+d)`/`(IY+d)`, or `LD (IX+d),n` |
| ARM32   | 4  | any ARM-state instruction word, or Thumb `BL`/`BLX`'s two-halfword pair (also 4 bytes, from one call) |
| RISC-V  | 8  | the `LI`/`CALL` pseudo-instructions, which always expand to a fixed two-instruction pair |
| m68k    | 10 | an immediate-family instruction (`ANDI`/`ORI`/`EORI`/`ADDI`/`SUBI`/`CMPI` or `MOVE.L #imm`) combining a `.L` immediate with an absolute-long `(xxxxxxxx).L` destination -- the only base-MC68000 shape with two independent 4-byte extension-word groups on one opcode |

`assemble_find_by_name()` also matches a small table of CLI-style aliases —
a name that selects a backend plus a preset default OPT value, eg `65c02`,
`65c816`, `arm32-fpa`, `arm32-vfp` and `arm32-thumb` — returned via
`out_default_opt` so a caller (typically parsing a `-cpu` argument) doesn't
need its own copy of that mapping. `assemble_get_aliases()` returns that
table directly for enumeration. The `*Assemble` command-line tool (`c.main`)
uses this registry for its own `-cpu` handling, and `*Assemble -list` prints
the full enumeration.

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
  are not implemented (see `AGENTS.md`);
* ARMv8-only VFP/NEON additions — `VMAXNM`/`VMINNM`, `VSELEQ`/`VSELGE`/
  `VSELGT`/`VSELVS`, the directed-rounding `VRINTA`/`VRINTN`/`VRINTP`/
  `VRINTM`/`VRINTX`/`VRINTZ` and the legacy `VRINTR`, directed-rounding
  float-to-integer `VCVTA`/`VCVTN`/`VCVTP`/`VCVTM`, and half-precision
  `VCVTB`/`VCVTT`.

General `VCVT` (the plain integer/fixed-point conversions, other than
`VCVTB`/`VCVTT`) remains a deliberate gap — see `AGENTS.md`. Within
base ARM32, the ARMv5TE/v6 'xy' DSP
multiply family (`SMLABB`, `SMLAWx`, `SMUAD`, `SMLAD`, `SMLALD` and
friends), `SMMLA`/`SMMLS`/`SMMUL`, `MRRC`/`MCRR`, the ARMv8 `LDA`/`STL`/
`LDAEX`/`STLEX` load-acquire/store-release family, and the banked-register
form of `MSR`/`MRS` (hypervisor-mode register access) are not yet
implemented and raise "Mnemonic not recognised". Within FPA, `LFM`/`SFM`
(multiple-register stack transfer) are omitted for the same reason.
Within classic VFP scalar, the `VMOV`-immediate (float constant) and
two-core-register transfer forms are omitted — see `AGENTS.md` for
detail on all of these.

A syntax quirk worth knowing: unlike every other ARM mnemonic, `LDR`,
`STR`, `LDM`, `STM`, `SWP`, the long-multiply family (`UMULL`/`UMLAL`/
`SMULL`/`SMLAL`), the generic coprocessor instructions (`CDP`, `MCR`,
`MRC`, `LDC`, `STC`) and the FPA mnemonics all write their size,
addressing-mode or precision suffix **after** the condition code —
`LDREQB`, not `LDRBEQ`; `ADFEQDP`, not `ADFDPEQ`. VFP mnemonics instead
separate the condition from a `.F32`/`.F64` datatype suffix with a dot,
following normal UAL syntax — `VADDEQ.F64`, not `VADD.F64EQ`.

### Thumb dialect: `ASSEMBLE_ARM32_OPT_THUMB`

Classic (pre-Thumb-2) 16-bit Thumb — the 19 instruction "formats" of
ARMv4T through ARMv6, ported from armips' `Archs/ARM/ThumbOpcodes.cpp`
— is implemented, gated by `ASSEMBLE_ARM32_OPT_THUMB`. Unlike FPA/VFP,
which add mnemonics on top of 32-bit ARM, Thumb is a wholly separate
16-bit encoding: setting this bit makes every instruction on that
`assemble_arm32_line()` call assemble as Thumb through its own
mnemonic table, and `ASSEMBLE_ARM32_OPT_FPA`/`ASSEMBLE_ARM32_OPT_VFP`
are ignored. A caller wanting to mix ARM and Thumb functions in one
source file assembles each region with a different `context->opt`.

Covered: the shift family (`LSL`/`ASL`/`LSR`/`ASR`, both the
shift-immediate and register-controlled-shift forms); `ADD`/`SUB`
(register, 3-bit and 8-bit immediate, PC/SP-relative address
generation, and SP adjustment forms); `MOV`/`CMP` (low-register
immediate and register forms, plus the hi-register forms of both);
the plain two-low-register ALU family (`AND`, `EOR`/`XOR`, `ADC`,
`SBC`, `ROR`, `TST`, `NEG`, `CMN`, `ORR`, `MUL`, `BIC`, `MVN`); `NOP`;
`BX`/`BLX` (register, interworking); `LDR`/`STR`/`LDRB`/`STRB`/`LDRH`/
`STRH`/`LDRSB`(`LDSB`)/`LDRSH`(`LDSH`) across all their addressing
forms (register offset, immediate offset, PC-relative and
SP-relative — `LDRSB`/`LDRSH` register-offset only, matching real
Thumb, which has no immediate-offset encoding for them); `PUSH`/`POP`;
`STMIA`/`LDMIA`; `SWI`/`BKPT`; the conditional branches (`BEQ`
through `BLE`); `B`; and `BL`/`BLX` (the two-halfword long
branch-with-link form).

Two deliberate scope reductions, both consistent with base ARM32
rather than being Thumb-specific gaps: no `LDR Rd,=const` literal-pool
pseudo-op (base ARM32 has never supported literal pools), and no
`ADR` pseudo-mnemonic (the PC/SP-relative address-generation
instruction is written out explicitly, eg `ADD Rd,PC,#imm`).

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

### RISC-V (RV32I + Zicsr)

Covers the full RV32I base integer instruction set (including
`FENCE`/`FENCE.TSO`, `ECALL`, `EBREAK`) plus the six Zicsr CSR
instructions (`CSRRW`/`CSRRS`/`CSRRC`/`CSRRWI`/`CSRRSI`/`CSRRCI`).
There is no RV32M/RV64I support and no `opt` dialect bits -- RV32I is
a single, fixed dialect for this backend. Registers may be written as
`x0`-`x31`, by their standard ABI names (`zero`, `ra`, `sp`, `gp`,
`tp`, `t0`-`t6`, `s0`-`s11`, `a0`-`a7`, `fp` as an alias for `s0`), or
as any expression evaluating to 0-31 (eg a BASIC variable holding a
register number). Loads, stores and `JALR` use the standard
`rd, imm(rs1)` / `rs2, imm(rs1)` syntax; branch and jump targets are
ordinary expressions (typically a `.label`), with the PC-relative
offset computed automatically against the instruction's own address.

The standard `NOP`, `MV`, `LI`, `J`, `JR`, `RET`, `CALL` and
zero-compare branch (`BEQZ`/`BNEZ`/`BLEZ`/`BGEZ`/`BLTZ`/`BGTZ`)
pseudo-instructions are supported. `LI` and `CALL` always expand to a
fixed two-instruction sequence (`LUI`+`ADDI` / `AUIPC`+`JALR`)
regardless of the value involved, rather than shrinking to one
instruction when the value happens to fit -- this keeps a line's
assembled size independent of whether a forward-referenced label has
been resolved yet, which matters because this library assembles one
line at a time across multiple passes (see `AGENTS.md`).

### m68k (base MC68000)

Covers the full standard Motorola MC68000 instruction set and all 12
of its addressing modes -- no 68010/68020/68030/68040/68060
extensions, no 68881/68882 FPU, no 68851 PMMU. There is a single
instruction-set dialect (`context->opt` carries no CPU-specific bits
for the instruction set itself), but one dialect bit controls the
spelling of the data pseudo-ops:

```c
#define ASSEMBLE_M68K_OPT_NATIVE_DIRECTIVES (1u << 4)  /* 0x10 */
```

Clear (the default) selects this library's shared `DCB`/`DCW`/`DCD`
convention, matching 6502/6809/RISC-V; set selects idiomatic 68k
`DC.B`/`DC.W`/`DC.L`/`DS.B`/`DS.W`/`DS.L` (`DS.*` reserves zero-filled
space, with no equivalent in the shared dialect -- 6502/6809/RISC-V's
`DCB`/`DCW`/`DCD` don't have one either). `EQU` and `OPT` behave
identically in both dialects.

Branch displacement size (`BRA`/`BSR`/`Bcc`) must always be written
explicitly as `.S` (8-bit) or `.W` (16-bit); there is no relaxation
between the two forms, the same reasoning as RISC-V's `LI`/`CALL`
always emitting their full fixed-size form -- this library assembles
one line at a time across caller-driven passes, so an instruction
whose size depends on a forward reference's eventual value has
nowhere safe to live. `Scc`/`DBcc` are recognised structurally (a
`B`/`S`/`DB` prefix plus one of the 16 standard condition-code
suffixes, `CC`/`HS` and `CS`/`LO` accepted as synonyms) rather than as
separate mnemonic-table rows, checked only after an exact
mnemonic-table match fails.

`ADD`/`SUB`/`CMP`/`AND`/`OR` automatically produce whichever real
opcode shape their operands require (the plain register-to-register
form, the address-register-destination `ADDA`/`CMPA`-shaped form, or
the immediate-to-memory `ADDI`/`CMPI`-shaped form) -- this is not an
optional relaxation the way an immediate-value-triggered `MOVEQ`/
`ADDQ`/`SUBQ` shortening would be (which this backend never does
automatically; write those explicitly), since only one of those
encodings is ever legal for a given combination of operand addressing
modes.

`MOVE from CCR` (`CCR,<ea>`) is a 68010 addition, not genuine MC68000,
and is deliberately rejected (`ASSEMBLE_M68K_ERR_NOT_ON_MC68000`)
rather than silently assembled; `MOVE to CCR`, `MOVE to/from SR` and
`MOVE to/from USP` are all genuine MC68000 and are supported. `AND`/
`OR`/`EOR`/`NOT` collide with BASIC's own tokenised keywords (bytes
`&80`/`&84`/`&82`/`&AC`), handled the same way as the 6809/Z80/RISC-V
backends handle their own colliding keywords: the token byte is
expanded back to its ASCII spelling before the mnemonic reader runs.

## Licence

MIT.
