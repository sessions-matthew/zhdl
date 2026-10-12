# ZHdl Language Reference Manual

**ZHdl** is a modern hardware description language (HDL) with Zig-like syntax and strict compile-time verification. It compiles directly to clean, synthesizable IEEE 1800 SystemVerilog and provides cycle-accurate testbenches executed via Verilator 5.

This document serves as the formal language specification and reference guide for ZHdl developers.

---

## Table of Contents

1. [Design Philosophy & Core Invariants](#1-design-philosophy--core-invariants)
2. [Lexical Structure](#2-lexical-structure)
   - [Comments](#21-comments)
   - [Identifiers](#22-identifiers)
   - [Numeric Literals](#23-numeric-literals)
   - [Keywords](#24-keywords)
3. [Type System](#3-type-system)
   - [Bit-Vectors (`uN`, `iN`)](#31-bit-vectors-un-in)
   - [Hardware Domain Types (`clock`, `reset`)](#32-hardware-domain-types-clock-reset)
   - [Unpacked Arrays (`[N]T`)](#33-unpacked-arrays-nt)
   - [Packed Structs (`packed struct`)](#34-packed-structs-packed-struct)
   - [Hardware Optionals (`?T`)](#35-hardware-optionals-t)
   - [Hardware Tagged Unions (`union(enum)`)](#36-hardware-tagged-unions-unionenum)
   - [Type Methods & Pure Combinational Functions (`pub fn`)](#37-type-methods--pure-combinational-functions-pub-fn)
   - [Comptime Generics (`fn(comptime ...) type`)](#38-comptime-generics-fncomptime--type)
4. [Module Architecture & Declarations](#4-module-architecture--declarations)
   - [Module Definition](#41-module-definition)
   - [Port Declarations (`in`, `out`, `inout`)](#42-port-declarations-in-out-inout)
   - [Wire Declarations (`wire`, `const`)](#43-wire-declarations-wire-const)
   - [Register Declarations (`reg`)](#44-register-declarations-reg)
5. [Procedural Blocks & Execution Semantics](#5-procedural-blocks--execution-semantics)
   - [Combinational Blocks (`comb`)](#51-combinational-blocks-comb)
   - [Register Updates (`reg.next`)](#52-register-updates-regnext)
   - [Synchronous Blocks (`sync`)](#53-synchronous-blocks-sync)
6. [Expressions, Operators & Slicing](#6-expressions-operators--slicing)
   - [Operators and Precedence](#61-operators-and-precedence)
   - [Wrapping vs Saturating Arithmetic](#62-wrapping-vs-saturating-arithmetic)
   - [Bit Slicing: Upward and Downward](#63-bit-slicing-upward-and-downward)
   - [Array Indexing](#64-array-indexing)
7. [Control Flow](#7-control-flow)
   - [Conditional Statements & Muxes (`if` / `else`)](#71-conditional-statements--muxes-if--else)
   - [Pattern Matching & Decoders (`switch`)](#72-pattern-matching--decoders-switch)
   - [Compile-Time Loop Unrolling (`inline for`)](#73-compile-time-loop-unrolling-inline-for)
8. [Built-in Functions (`@builtins`)](#8-built-in-functions-builtins)
   - [`@sync2ff(dest_clk, sig)`](#81-sync2ffdest_clk-sig)
   - [`@bitReverse(x)`](#82-bitreversex)
   - [`@byteSwap(x)`](#83-byteswapx)
   - [`@concat(...)`](#84-concata-b-)
   - [`@truncate(T, x)`](#85-truncatetype-expr)
   - [`@bitCast(T, x)` and `@as(T, x)`](#86-bitcasttype-expr-and-astype-expr)
   - [`@clog2(x)`](#87-clog2val)
   - [`@import("path")`](#88-importpath)
9. [Static Safety & Compile-Time Verification](#9-static-safety--compile-time-verification)
   - [Static Single-Writer Rule (No Multi-Driven Nets)](#91-static-single-writer-rule)
   - [Combinational Loop Freedom (Cycle Detection)](#92-combinational-loop-freedom-dag)
   - [Clock Domain Crossing (CDC) Safety](#93-clock-domain-crossing-cdc-safety)
   - [Zero-Latch Guarantee](#94-zero-latch-guarantee)
10. [Hierarchy & Submodule Instantiation](#10-hierarchy--submodule-instantiation)
11. [Hardware Testbenches & Simulation](#11-hardware-testbenches--simulation)
    - [Testbench Structure (`test "name"`)](#111-testbench-structure)
    - [Simulation Procedures (`sim`)](#112-simulation-procedures)
    - [Timing and Verification Primitives](#113-timing-and-verification-primitives)
12. [SystemVerilog Translation Specification](#12-systemverilog-translation-specification)

---

## 1. Design Philosophy & Core Invariants

ZHdl is designed to eliminate classic hardware bugs directly at compile time:

1. **No Inferred Latches**: Combinational logic cannot accidentally retain state. Register architectures enforce explicit next-state updates (`reg.next`) with automatic default holds.
2. **Deterministic Concurrency (Single-Writer Rule)**: Multiple concurrent drivers on the same wire or port contention are rejected during semantic elaboration.
3. **No Parasitic Combinational Loops**: Zero-delay feedback paths ($a \to b \to a$) are detected via 3-color directed acyclic graph (DAG) cycle checks and rejected before synthesis.
4. **Metastability-Proof Clock Domain Crossings**: Asynchronous transfers between differing clock domains ($R_{\text{src}}\text{.clk} \neq R_{\text{dest}}\text{.clk}$) are rejected unless explicitly routed through dual flip-flop synchronizers (`@sync2ff`).
5. **Separation of Synthesizable RTL and Verification**: Hardware models generate 100% pure synthesizable IEEE 1800 SystemVerilog without simulation directives (`#`, `$finish`, `$fatal`), while first-class `test` declarations compile into dedicated cycle-accurate simulation harnesses with waveform output.

---

## 2. Lexical Structure

### 2.1 Comments

ZHdl supports standard C/Zig comment styles:
```zig
// Single-line comment to end of line

/* Multi-line
   block comment */
```

### 2.2 Identifiers

Identifiers begin with an ASCII letter or underscore, followed by letters, digits, or underscores:
```text
count, clk_200mhz, rx_fifo_wr_ptr, _internal_sync_0
```

### 2.3 Numeric Literals

ZHdl supports integer literals in decimal, hexadecimal, binary, and octal:
```zig
const dec = 42;
const hex = 0x1F;
const bin = 0b1010_0110;  // underscores permitted as visual digit separators
const oct = 0o77;
```

### 2.4 Keywords

The following tokens are reserved keywords:

| Category | Keywords |
|---|---|
| **Hardware Core** | `module`, `in`, `out`, `inout`, `comb`, `sync`, `reg`, `wire`, `clock`, `reset` |
| **Verification** | `test`, `sim` |
| **Declarations** | `const`, `var`, `fn`, `pub`, `return` |
| **Types & Layout**| `struct`, `packed`, `enum` |
| **Control Flow** | `if`, `else`, `switch`, `for`, `inline` |
| **Literals** | `true`, `false` |
| **Meta** | `comptime` |

---

## 3. Type System

### 3.1 Bit-Vectors (`uN`, `iN`)

ZHdl natively supports arbitrary bit-width integers:
- `u1` to `u128`: Unsigned bit-vector of $N$ bits.
- `i1` to `i128`: Two's complement signed integer of $N$ bits.

```zig
wire flag: u1 = 1;
wire byte_val: u8 = 0xFF;
wire word_val: u32 = 0xDEADBEEF;
wire offset: i16 = -128;
```

### 3.2 Hardware Domain Types (`clock`, `reset`)

Ports that represent clock and reset signals use explicit domain types:
- `clock`: Identifies an edge-triggered clock signal.
- `reset`: Identifies an asynchronous or synchronous reset signal.

#### Active-Low Reset Detection
The compiler analyzes reset signal names. If a reset signal ends in `_n`, `_b`, or is named `nrst` or `aresetn`, the SystemVerilog codegen automatically configures the sequential block sensitivity for active-low operation:
```systemverilog
always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) ...
```

### 3.3 Unpacked Arrays (`[N]T`)

Hardware memories, register files, and FIFOs are declared using unpacked array syntax:
```zig
// 64-entry FIFO buffer where each entry is 8 bits
wire fifo_mem: [64]u8;

// 16-entry register bank
var reg_bank = reg([16]u32, .{ .clk = clk, .rst = rst, .init = 0 });
```

### 3.4 Packed Structs (`packed struct`)

ZHdl supports bit-exact hardware packed structs. Struct fields are laid out contiguously without padding:

```zig
pub const PacketHeader = packed struct {
    sof: u8,
    msg_id: u8,
    length: u16,
};
```

- **Bit Layout**: Fields are ordered from MSB to LSB. The total bit width is the exact sum of member field widths ($8 + 8 + 16 = 32\text{ bits}$).
- **Struct Literals**: Supports anonymous struct literals `.{ .sof = 0xA5, .msg_id = 1, .length = 64 }` and named struct literals `PacketHeader{ ... }`.
- **Member Access & Slicing**: Reading `hdr.msg_id` automatically lowers to the exact bit-slice (`hdr[23:16]`).
- **Field Assignment**: Assigning to `hdr.msg_id = 8'h02;` on a wire or `hdr.msg_id := 8'h02;` on a register updates the corresponding bit slice.

### 3.5 Hardware Optionals (`?T`)

Optional types represent hardware **Valid + Data** handshakes:

```zig
reg rx_byte: ?u8 = null;
```

- **Physical Layout**: Width is $1 + W(T)$. Bit $W(T)$ (MSB) is the 1-bit `valid` flag, and bits $[W(T)-1 : 0]$ are the payload data.
- **Null Literal (`null`)**: `rx_byte := null;` clears the valid bit and zero-clears the data bits.
- **Auto-Wrapping**: Assigning a raw payload value `rx_byte := 8'h42;` automatically asserts valid and packs the data: `{ 1'b1, 8'h42 }`.
- **Direct Inspection**: Inspect `rx_byte.valid` (1 bit) and `rx_byte.data` ($W(T)$ bits).
- **Pattern Unwrapping (`if (opt) |data|`)**:
  ```zig
  if (rx_byte) |b| {
      out_byte = b;
  }
  ```
  Evaluates the valid bit and provides the unwrapped payload `b` in the body.

### 3.6 Hardware Tagged Unions (`union(enum)`)

Hardware tagged unions represent variant multiplexing where multiple data types share a common bitfield accompanied by a discriminant tag:

```zig
pub const Packet = union(enum) {
    ping: u8,
    data: u32,
    ack: void,
};
```

- **Physical Layout**: Total width is $W_{\text{tag}} + \max_i(W_i)$.
  - Tag discriminant width $W_{\text{tag}} = \lceil \log_2(N) \rceil$ (or explicit enum backing type).
  - Discriminant tag stored at MSB $[W_{\text{total}}-1 : W_{\text{payload}}]$.
  - Variant payload stored at LSB $[W_{\text{payload}}-1 : 0]$.
- **Initialization**: `Packet{ .ping = 8'hA5 }` or `.{ .ping = 8'hA5 }` sets tag 0 and zero-extends the payload.
- **Member Access**: `pkt.tag` inspects the discriminant; `pkt.ping` slices the payload.
- **Pattern Matching with Capture**:
  ```zig
  switch (pkt) {
      .ping => |p| {
          out_val = p;
      },
      .data => |d| {
          out_val = d[7:0];
      },
      .ack => {
          out_val = 0;
      },
  }
  ```
  Synthesizes a clean SystemVerilog `case (pkt[33:32])` with automatic capture binding.

### 3.7 Type Methods & Pure Combinational Functions (`pub fn`)

Types can encapsulate pure combinational helper functions and methods:

```zig
pub const Float16 = packed struct {
    sign: u1,
    exp: u5,
    mantissa: u10,

    pub fn isZero(self: Float16) u1 {
        return self.exp == 0 and self.mantissa == 0;
    }

    pub fn isNegative(self: Float16) u1 {
        return self.sign == 1;
    }
};
```

- **Method Call Syntax**: `f.isZero()` resolves to the method on `Float16` with `self` bound to `f`.
- **Associated Functions**: `Float16.isZero(f)` or static helpers.
- **Combinational Inlining**: Evaluated and inlined as combinational logic with zero simulation or runtime overhead.
- **Top-Level Helper Functions**: `pub fn clamp_add(a: u8, b: u8) u8 { return if (a > 200) 200 else a + b; }` can be called directly in `comb` blocks.

### 3.8 Comptime Generics (`fn(comptime ...) type`)

ZHdl supports parameterizing hardware modules via compile-time functions returning `module { ... }`:

```zig
pub fn Counter(comptime W: usize) type {
    return module {
        in clk: clock,
        in rst: reset,
        in en: u1,
        out count: u(W),

        reg val: u(W) = 0;

        comb {
            val.next = if (en) val + 1 else val;
            count = val;
        }
    };
}
```

- **Monomorphization**: When instantiated as `Counter(8)` and `Counter(16)`, the compiler specializes independent, collision-free SystemVerilog modules `Counter_8` and `Counter_16`.
- **Parameter Kinds**: Supports numeric parameters (`comptime W: usize`) and hardware type parameters (`comptime T: type`).
- **Instantiation**:
  ```zig
  // Alias or direct instantiation
  const Counter8 = Counter(8);
  const c1 = Counter8.instantiate(.{ .clk = clk, .rst = rst, .en = en, .count = count8 });
  const c2 = Counter(16).instantiate(.{ .clk = clk, .rst = rst, .en = en, .count = count16 });
  ```

---

## 4. Module Architecture & Declarations

### 4.1 Module Definition

Modules are defined as constants assigned to a `module` block:

```zig
pub const Counter = module {
    in clk: clock,
    in rst: reset,
    in en: u1,
    out count: u8,

    // Module items (registers, wires, submodules, comb blocks)
};
```

### 4.2 Port Declarations (`in`, `out`, `inout`)

Ports define the boundary interface of the module:
- `in name: Type`: Read-only input port driven externally.
- `out name: Type`: Output port driven by internal logic.
- `inout name: Type`: Bidirectional port.

```zig
in clk: clock,
in rst: reset,
in din: u16,
out dout: u16,
inout sda: u1,
```

### 4.3 Wire Declarations (`wire`, `const`)

Wires represent combinational nets:

```zig
// Continuous wire declaration with explicit type and driver
wire valid: u1 = (state == State.done);

// Continuous wire declaration with inferred type
wire sum = a +% b;

// Unassigned wire (driven procedurally within a comb block)
wire wr_ptr: u4;
```

### 4.4 Register Declarations (`reg`)

Registers represent physical D-flip-flops. ZHdl supports two equivalent declarations:

#### Explicit Configuration Form:
```zig
var count = reg(u8, .{
    .clk = clk,
    .rst = rst,
    .init = 0,
});
```

#### Compact Sugar Form:
```zig
reg count: u8 = 0; // Inferred to bind to default 'clk' and 'rst' ports
```

Registers automatically split into:
- `count_q`: Stable output of the flip-flop (read in combinational expressions).
- `count_d`: Combinational input driving the next clock cycle state (assigned via `count.next`).

---

## 5. Procedural Blocks & Execution Semantics

### 5.1 Combinational Blocks (`comb`)

Combinational logic is written inside `comb { ... }` blocks. Statements inside execute conceptually in zero simulation time and synthesize to IEEE 1800 `always_comb`:

```zig
comb {
    if (en) {
        count.next = count +% 1;
    }
    out_valid = (count == 255);
}
```

### 5.2 Register Updates (`:=` and `reg.next`)

Within a `comb` block, registers can be scheduled for the next clock edge using the dedicated **register non-blocking assignment operator (`:=`)** or the explicit `.next` property:

```zig
comb {
    // Dedicated register assignment (:=):
    count := count +% 1;
    fsm_state := State.read;

    // Array element register update:
    fifo_mem[wr_ptr] := din;

    // Explicit .next syntax (fully supported backward-compatible alias):
    count.next = count +% 1;
}
```

#### Why `:=`?
1. **Visual Time Boundary**: Distinguishes instantaneous 0-delay wires (`=`) from 1-cycle delayed flip-flops (`:=`) at the call-site without requiring verbose `.next` properties.
2. **Clean Array Indexing**: Avoids syntactic awkwardness with memories (`mem[ptr] := data` vs `mem[ptr].next = data`).
3. **No Collision with `<=`**: Avoids Verilog's bug-prone overloading of `<=` (which is strictly the less-than-or-equal comparison operator in ZHdl).
4. **Compile-Time Enforcement**: Attempting to use `:=` on a combinational `wire` triggers a compile error:
   ```text
   COMPILE ERROR: Invalid Register Assignment (':=') on Signal 'w'
   The operator ':=' is reserved for clocked registers ('reg').
   ```

#### Latch-Free Hold Guarantee
At the beginning of every evaluation cycle, all registers implicitly default to:
$$\text{reg\_d} = \text{reg\_q}$$
Unless explicitly updated within conditional branches, a register preserves its existing state. This guarantees **100% latch-free synthesizable RTL**.

### 5.3 Synchronous Blocks (`sync`)

Alternatively, sequential logic can be grouped into edge-triggered `sync` blocks:

```zig
sync(clk, rst) {
    if (en) {
        count = count +% 1;
    }
}
```
Any signal assigned inside a `sync` block is automatically lowered to a D-flip-flop clocked by `clk`.

---

## 6. Expressions, Operators & Slicing

### 6.1 Operators and Precedence

Operators follow standard C/Zig precedence rules:

| Category | Operators | Description |
|---|---|---|
| **Primary** | `()`, `[]`, `.`, `@` | Function call, indexing, field access, builtin |
| **Unary** | `!`, `~`, `-` | Logical NOT, bitwise invert, negation |
| **Multiplicative** | `*`, `*%`, `/`, `%` | Multiply, wrapping multiply, divide, modulo |
| **Additive** | `+`, `+%`, `-`, `-%` | Add, wrapping add, subtract, wrapping subtract |
| **Shift** | `<<`, `>>` | Logical left shift, logical right shift |
| **Relational** | `<`, `<=`, `>`, `>=` | Less than, less than equal, greater than, greater than equal |
| **Equality** | `==`, `!=` | Equality, inequality |
| **Bitwise AND** | `&` | Bitwise AND |
| **Bitwise XOR** | `^` | Bitwise XOR |
| **Bitwise OR** | `\|` | Bitwise OR |
| **Logical AND** | `&&` | Logical short-circuit AND |
| **Logical OR** | `\|\|` | Logical short-circuit OR |
| **Conditional** | `if (c) x else y` | Mux / ternary selection |

### 6.2 Wrapping vs Saturating Arithmetic

To explicitly avoid synthesis overflow ambiguities:
- `+%`: Wrapping addition (modulo $2^N$).
- `-%`: Wrapping subtraction (modulo $2^N$).
- `*%`: Wrapping multiplication.

```zig
count.next = count +% 1; // 255 +% 1 wraps to 0
```

### 6.3 Bit Slicing: Upward and Downward

ZHdl supports both upward and downward bit slicing directly in square brackets:

```zig
wire data: u16 = 0xABCD;

// Upward slice: [start..end] (half-open, width = end - start)
wire low_byte: u8 = data[0..8];   // bits [7:0]

// Downward slice: [high..low] (downward sugar, width = high - low)
wire rev_nibble: u4 = data[4..0]; // bits [3:0]
```

### 6.4 Array Indexing

Unpacked arrays and memory buffers are indexed using `[index]`:
```zig
wire cur_byte: u8 = fifo_mem[rd_ptr];
```

---

## 7. Control Flow

### 7.1 Conditional Statements & Muxes (`if` / `else`)

`if` statements synthesize directly to priority multiplexers:

```zig
comb {
    if (reset_override) {
        state.next = State.idle;
    } else if (data_ready) {
        state.next = State.read;
    }
}
```

`if` can also be used as an expression (ternary mux):
```zig
wire selected: u8 = if (sel) channel_a else channel_b;
```

### 7.2 Pattern Matching & Decoders (`switch`)

`switch` expressions and statements provide comprehensive decoding logic:

```zig
comb {
    switch (addr) {
        0x00 => { rdata = reg_id; },
        0x02 => { rdata = reg_mode; },
        0x10...0x1F => { rdata = bank_regs[addr - 0x10]; },
        else => { rdata = 0; },
    }
}
```
- Supports single values (`0x00`), value ranges (`0x10...0x1F`), and default fallbacks (`else`).
- Translates cleanly to SystemVerilog `case ... endcase`.

### 7.3 Compile-Time Loop Unrolling (`inline for`)

Static loop structures are fully unrolled at compile time:

```zig
comb {
    var crc = prev_crc;
    inline for (0..8) |i| {
        const bit = (data_in >> i) & 1;
        crc = if (bit ^ crc[15]) (crc << 1) ^ 0x1021 else (crc << 1);
    }
    next_crc = crc;
}
```

---

## 8. Built-in Functions (`@builtins`)

Built-in compiler primitives begin with the `@` prefix:

### 8.1 `@sync2ff(dest_clk, sig)`

Instantiates a 2-stage D-flip-flop synchronizer into clock domain `dest_clk`:

```zig
wire synced_sig: u8 = @sync2ff(clk_b, async_sig);
```
- Lowers to a 2-stage shift register clocked by `dest_clk`.
- Emits the IEEE 1800 synthesis attribute `(* ASYNC_REG = "TRUE" *)` in SystemVerilog.
- Whitelists cross-domain transfers in the compiler CDC checker.

### 8.2 `@bitReverse(x)`

Reverses the bit order of an integer vector:
```zig
wire rev: u8 = @bitReverse(val); // bit 0 becomes bit 7, bit 1 becomes bit 6...
```
Synthesizes to SystemVerilog streaming operators: `{<<{val}}`.

### 8.3 `@byteSwap(x)`

Reverses the byte order (endianness flip):
```zig
wire be_val: u32 = @byteSwap(le_val);
```
Synthesizes to SystemVerilog byte streaming operators: `{<<8{val}}`.

### 8.4 `@concat(a, b, ...)`

Concatenates arbitrary vectors into a single vector:
```zig
wire full_frame: u32 = @concat(header_u8, payload_u16, crc_u8);
```
Synthesizes to SystemVerilog concatenation: `{header, payload, crc}`.

### 8.5 `@truncate(Type, expr)`

Truncates an expression to a narrower target bit-width:
```zig
wire lower_nibble: u4 = @truncate(u4, full_word);
```

### 8.6 `@bitCast(Type, expr)` and `@as(Type, expr)`

Reinterprets or casts raw bits between compatible types:
```zig
wire signed_val: i8 = @bitCast(i8, unsigned_val);
wire expanded: u16 = @as(u16, raw_literal);
```

### 8.7 `@clog2(val)`

Calculates the ceiling logarithm base 2 at compile time, ideal for pointer widths:
```zig
const depth = 64;
const ptr_width = @clog2(depth); // 6
```

### 8.8 `@import("path")`

Imports definitions and types from another `.zhdl` file:
```zig
const uart = @import("uart_pkg.zhdl");
```

---

## 9. Static Safety & Compile-Time Verification

### 9.1 Static Single-Writer Rule

ZHdl enforces that no physical net can experience electrical contention:
1. **Module Input Protection**: Input ports are read-only. Procedural or continuous assignments to input ports trigger:
   ```text
   COMPILE ERROR: Cannot Assign to Input Port 'clk' in module 'MyMod'
   ```
2. **Single-Driver Rule**: Every wire must have exactly one concurrent driver across submodule instance outputs, continuous declarations, and `comb` blocks. Multi-driver contention triggers:
   ```text
   COMPILE ERROR: Multiple Drivers Detected on Signal 'y' in module 'MyMod'
   ```

### 9.2 Combinational Loop Freedom (DAG)

Combinational logic must be a pure directed acyclic graph. Any cyclic dependency ($a \to b \to a$ or multi-hop $w_0 \to \dots \to w_9 \to w_0$) creates an unstable analog ring oscillator in physical silicon and hangs event-driven simulators.

ZHdl extracts dependency edges across all assignments, runs 3-color DFS cycle detection, and rejects cyclic logic:

```text
======================================================================
COMPILE ERROR: Combinational Loop Detected in module 'DeepLoop'
======================================================================
A cyclic dependency exists among purely combinational signals:
  w8 -> w9 -> w0 -> w1 -> w2 -> w3 -> w4 -> w5 -> w6 -> w7 -> w8

Reason:
  Combinational logic cannot form a closed loop without an intervening
  clocked register (D-flip-flop). This creates an unstable analog ring
  oscillator in physical silicon and hangs event-driven simulators in
  infinite zero-delay delta-cycle loops.

Solution:
  Break the combinational cycle by declaring a clocked register:
    reg w8: ... = 0;
    comb {
        w8.next = ...;
    }
======================================================================
```

### 9.3 Clock Domain Crossing (CDC) Safety

Asynchronous clock domains cannot directly exchange signals without risking metastability and setup/hold timing violations.

#### Verification Algorithm:
1. Distinct clock domains are collected across all registers. Modules with $\le 1$ clock domain incur **zero analysis overhead**.
2. If multiple clock domains exist, backward dataflow DFS traces from each destination register's D-input back through intermediate combinational wires.
3. If an asynchronous source register is reached where $R_{\text{src}}\text{.clk} \neq R_{\text{dest}}\text{.clk}$, and the destination is not tagged as a synchronizer stage, the compiler halts with `error.ClockDomainCrossing`:

```text
======================================================================
COMPILE ERROR: Unsafe Clock Domain Crossing in module 'Bridge'
======================================================================
Illegal asynchronous transfer from clock domain 'clk_fast' to 'clk_slow':
  Source register:      'reg_fast' (clock: clk_fast)
  Destination register: 'reg_slow' (clock: clk_slow)
  Dataflow path:        reg_fast -> w1 -> w2 -> reg_slow

Reason:
  Sampling registers across asynchronous clock domains without synchronization
  causes metastability and non-deterministic race conditions.

Fix:
  Synchronize the cross-domain signal using a 2-stage flip-flop synchronizer:
    wire reg_fast_sync = @sync2ff(clk_slow, reg_fast);
======================================================================
```

#### Safe Crossings with `@sync2ff`:
Wrapping the transfer in `@sync2ff(dest_clk, sig)` inserts an isolated 2-stage synchronizer (`is_sync_stage = true`) with synthesis protection attributes (`(* ASYNC_REG = "TRUE" *)`), satisfying the CDC invariant.

### 9.4 Zero-Latch Guarantee

Because register D-inputs automatically default to hold their Q-outputs (`reg_d = reg_q`), partial assignments in `if` or `switch` branches can never infer unwanted transparent latches.

---

## 10. Hierarchy & Submodule Instantiation

Submodules are instantiated using explicit named port bindings:

```zig
pub const TopModule = module {
    in clk: clock,
    in rst: reset,
    in wr_en: u1,
    out wr_ptr: u4,

    // Instantiate submodule
    const wr_unit = FifoPointer.instantiate(.{
        .clk = clk,
        .rst = rst,
        .inc = wr_en,
        .ptr = wr_ptr,
    });
};
```

---

## 11. Hardware Testbenches & Simulation

ZHdl provides first-class hardware testbenches matching Zig's `test "name" { ... }` syntax.

### 11.1 Testbench Structure

A testbench declares test wires, instantiates the Device Under Test (DUT), and executes a procedural `sim` block:

```zig
test "Counter increments and rolls over at 255" {
    wire clk: clock;
    wire rst: reset;
    wire en: u1;
    wire count: u8;

    const dut = Counter.instantiate(.{
        .clk = clk,
        .rst = rst,
        .en = en,
        .count = count,
    });

    sim {
        trace("counter_tb.vcd");
        clk.generate(10);     // 50 MHz clock (10ns period)
        rst.pulse(2);         // Hold reset for 2 cycles
        
        en = 1;
        step(clk, 10);
        assert(count == 10, "Counter should reach 10 after 10 enabled cycles");

        step(clk, 246);
        assert(count == 0, "Counter should roll over to 0 after 256 cycles");

        finish();
    }
}
```

### 11.2 Simulation Procedures

Statements inside `sim { ... }` blocks execute sequentially in time.

### 11.3 Timing and Verification Primitives

ZHdl supports both cycle-accurate synchronous testing and time-based testing with typed physical units (`ps`, `ns`, `us`, `ms`, `s`):

| Simulation Primitive | Description | Generated SystemVerilog |
|---|---|---|
| `clk.generate(10ns)` / `(10)` | Spawns an oscillating clock generator with half-period toggling | `always #5ns clk = ~clk;` |
| `rst.pulse(cycles)` | Asserts reset active, waits $N$ clock cycles, then deasserts | Procedural reset sequence |
| `step(clk, cycles)` | Synchronously advances simulation by $N$ rising clock edges | `repeat (cycles) @(posedge clk);` |
| `delay(50ns)` / `delay(10us)` | Explicit physical delay with typed time units (`ps`, `ns`, `us`, `ms`, `s`) | `#50ns;` / `#10us;` |
| `wait_for(cond, timeout)` | Waits until `cond` is asserted or fails after `timeout` (time or cycles) | `fork ... wait (cond); ... #timeout; ... join_any` |
| `assert_within(cond, timeout)` | Asserts `cond` occurs within physical timeout or cycle limit | Bounded assertion verification |
| `assert(cond, "msg")` | Hardware assertion check; aborts simulation with error code on failure | `if (!(cond)) begin $error("[FAIL] msg"); $fatal(1); end` |
| `trace("path.vcd")` | Enables VCD waveform dump for GTKWave or VS Code Surfer | `$dumpfile("path.vcd"); $dumpvars(0, tb_mod);` |
| `finish()` | Terminates simulation successfully | `$finish;` |

#### Typed Time Literals
Time quantities in `sim` blocks support standard physical units:
```zig
sim {
    clk.generate(10ns);    // 100 MHz clock
    trace("wave.vcd");
    rst.pulse(2);

    delay(250ps);          // Sub-nanosecond setup time modeling
    delay(50ns);           // Nanosecond timing
    delay(10us);           // Microsecond bus delay
    delay(2ms);            // Millisecond peripheral delay

    wait_for(rx_done == 1, 100us); // Bounded time-based wait
    assert(data == 0xA5, "Data mismatch");
    finish();
}
```

Testbenches are executed using the CLI:
```bash
$ ./zhdl test examples/counter.zhdl
1/1 test.Counter increments and rolls over at 255...OK
   Waveform saved to: counter_tb.vcd
All 1 tests passed.
```

---

## 12. SystemVerilog Translation Specification

ZHdl compiles to clean, standard IEEE 1800-2017 SystemVerilog. The table below summarizes the exact mappings:

| ZHdl Construct | Target SystemVerilog-2017 Construct | Notes |
|---|---|---|
| `in name: u8` | `input logic [7:0] name` | Port declaration |
| `out name: u1` | `output logic name` | Single-bit scalar port |
| `wire w: u16 = expr;` | `logic [15:0] w; assign w = expr;` | Continuous wire declaration |
| `reg r: u8 = 0;` | `logic [7:0] r_q, r_d; always_ff @(posedge clk) ...` | Flip-flop with $Q$/$D$ separation |
| `reg r (is_sync_stage)` | `(* ASYNC_REG = "TRUE" *) always_ff @(posedge clk) ...` | Synchronizer synthesis attribute |
| `comb { ... }` | `always_comb begin ... end` | Combinational procedure |
| `reg.next = expr;` / `reg := expr;` | `reg_d = expr;` (inside `always_comb`) | Latch-free register next-state update |
| `a +% b` | `a + b` | Native wrapping in bit-vector |
| `x[0..8]` | `x[7:0]` | Upward slice conversion |
| `x[4..0]` | `x[3:0]` | Downward slice conversion |
| `@bitReverse(x)` | `{<<{x}}` | Streaming bit reflection |
| `@byteSwap(x)` | `{<<8{x}}` | Streaming byte reversal |
| `@concat(a, b)` | `{a, b}` | Bit concatenation |
| `switch (x) { ... }` | `case (x) ... endcase` | Clean decoder syntax |
| `Sub.instantiate(...)` | `Sub u_Sub ( .port(sig), ... );` | Explicit named port binding |
| `test "name" { ... }` | `module name_tb; ... initial begin ... end endmodule` | Dedicated test harness |
