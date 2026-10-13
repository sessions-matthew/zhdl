# ZHdl Comptime Embedded DSL (eDSL) Architecture

The **ZHdl Comptime Embedded DSL (eDSL)** allows hardware designers to write, simulate, and synthesize hardware designs using **100% valid, standard Zig code**.

Instead of maintaining a custom hand-written lexer and parser, the eDSL directly leverages the **Zig compiler**, `@typeInfo` reflection, Zig's comptime engine, and the Zig build system.

---

## Key Benefits

1. **Zero Parser Maintenance**: Parsing, tokenization, error recovery, and formatting are delegated entirely to `zig` and `zig fmt`.
2. **First-Class ZLS Support**: Standard IDE features—autocomplete, go-to-definition, hover documentation, and rename refactoring—work out of the box in VS Code, Neovim, and Emacs without a custom language server.
3. **Dual Execution Model**:
   - **Synthesis**: Comptime reflection and the `Builder` compile hardware definitions down to `hir.HirModule` and synthesizable IEEE 1800 SystemVerilog.
   - **Simulation**: Modules execute at native CPU machine-code speeds directly inside `zig test` with automatic register default-holds ($D = Q$) and reset sequencing—**without needing Verilator or C++ toolchains**.
4. **Built-in Type Introspection**: Automatic bit-width and alignment calculation for arbitrary integer widths (`UInt(W)`, `SInt(W)`), packed structs, tagged unions, enums, optionals (`?T`), and arrays (`[N]T`).

---

## Core Primitives

All primitives are exported from `@import("zhdl")`:

| Primitive | Description |
| :--- | :--- |
| `Clock` | Single-bit clock net with rising/falling edge transition modeling. |
| `Reset(mode, pol)` | Reset signal specifying `.async` vs `.sync` and `.active_high` vs `.active_low`. |
| `AsyncResetActiveLow` | Convenience alias for `Reset(.async, .active_low)` (`rst_n`). |
| `Async(T)` | Qualifier for external asynchronous input pins requiring CDC synchronization. |
| `In(T)` | Input port carrying data type `T`. |
| `Out(T)` | Output port carrying data type `T`. |
| `InOut(T)` | Bidirectional inout port. |
| `Reg(T)` | Clocked sequential register (D-flip-flop) with guaranteed default-hold ($D = Q$). |
| `UInt(W)` | Unsigned integer of arbitrary bit width $W$ (`@Int(.unsigned, W)`). |
| `SInt(W)` | Signed integer of arbitrary bit width $W$ (`@Int(.signed, W)`). |

---

## Dual Execution in Action: `Counter(W)`

```zig
const std = @import("std");
const zhdl = @import("zhdl");

pub fn Counter(comptime W: u16) type {
    return struct {
        clk: zhdl.In(zhdl.Clock),
        rst_n: zhdl.In(zhdl.AsyncResetActiveLow),
        en: zhdl.In(u1),
        count: zhdl.Out(zhdl.UInt(W)),
        overflow: zhdl.Out(u1),

        count_reg: zhdl.Reg(zhdl.UInt(W)) = .init(0),

        /// Hardware netlist synthesis definition
        pub fn build(b: *zhdl.Builder) !void {
            const htype = zhdl.hir.HirType{ .tag = .bits, .width = W };
            const u1_t = zhdl.hir.HirType{ .tag = .bits, .width = 1 };

            const en_ref = b.ref("en", u1_t);
            const count_q = b.ref("count_reg", htype);
            const count_d = b.ref("count_reg_d", htype);
            const count_out = b.ref("count", htype);
            const ovf_out = b.ref("overflow", u1_t);

            const max_val = (@as(u64, 1) << W) - 1;
            const is_ovf = b.eq(count_q, b.lit(max_val, W));
            const inc_val = b.add(count_q, b.lit(1, W));
            const next_val = b.mux(b.eq(en_ref, b.lit(1, 1)), inc_val, count_q);

            try b.addComb(b.assign(ovf_out, is_ovf));
            try b.addComb(b.assign(count_d, next_val));
            try b.addComb(b.assign(count_out, count_q));
        }

        /// Native cycle-accurate simulation logic
        pub fn comb(self: *@This()) void {
            const max_val = (@as(u64, 1) << W) - 1;
            self.overflow.set(if (self.count_reg.get() == max_val) @as(u1, 1) else @as(u1, 0));

            if (self.en.get() == 1) {
                self.count_reg.set(self.count_reg.get() +% 1);
            }
            self.count.set(self.count_reg.get());
        }
    };
}
```

### 1. Synthesizing to SystemVerilog

```zig
test "Synthesize Counter" {
    const sv = try zhdl.emitSystemVerilog(Counter(8), std.testing.allocator);
    defer std.testing.allocator.free(sv);
    // Emits standard IEEE 1800 SystemVerilog with always_ff and always_comb!
}
```

### 2. Simulating in Pure Zig

```zig
test "Simulate Counter" {
    var sim = zhdl.Sim(Counter(8)).init();

    // Pulse reset for 2 cycles
    sim.pulseReset(2);
    try std.testing.expectEqual(@as(u8, 0), sim.dut.count.get());

    // Enable and step 10 cycles
    sim.dut.en.set(1);
    sim.step(10);
    try std.testing.expectEqual(@as(u8, 10), sim.dut.count.get());
}
```

---

---

## Syntax Sugar Architecture: Tier 1 & Tier 2

To bridge hardware ergonomics with pure Zig semantics, ZHdl provides two complementary tiers of syntax sugar:

### Tier 1: In-Language Hardware Ergonomics (100% Valid Zig)

Available natively from `@import("zhdl")`:

1. **Bitwise and Signal Manipulation**:
   - `cat(.{ sig_a, sig_b, sig_c })`: Variadic bitwise concatenation packed MSB to LSB returning `UInt(total_width)`.
   - `slice(val, high, low)`: Bit slicing `[high:low]` returning `UInt(high - low + 1)`.
   - `bit(val, idx)`: Extracts 1-bit integer `u1`.
   - `rep(val, count)`: Replicates 1-bit or $N$-bit value `count` times.
   - `mux(cond, a, b)`: 2-to-1 hardware multiplexer returning `a` if `cond != 0` else `b`.
   - `signExtend(TargetInt, val)`: Sign-extends smaller integer to target type width.

2. **Direct Pin and Register Access**:
   - `Reg(T)` exposes direct `.d = expr;` write and `.q` read access, alongside `.bit(idx)`, `.slice(high, low)`, and `.next(expr)`.
   - `In(T)` and `Out(T)` expose `.val` and methods `.bit(idx)`, `.slice(high, low)`, and `.next(expr)`.

3. **Physical Frequency and Timing Units**:
   - Frequency: `Hz(N)`, `KHz(N)`, `MHz(N)`, `GHz(N)`. Methods: `.toHz()`, `.toPeriodPs()`, `.toPeriodNs()`.
   - Time: `ps(N)`, `ns(N)`, `us(N)`, `ms(N)`. Methods: `.toPs()`, `.toNs()`, `.toUs()`, `.toMs()`.

### Tier 2: Source-to-Source HDL Desugarer (`src/edsl/desugar.zig`)

For hardware designers who prefer classic HDL brevity (`in`, `out`, `reg`, `:=`, `comb`, `100MHz`, `u(W)`), the Tier 2 desugarer transforms `.zhdl` files into valid Zig eDSL virtual buffers parsed with 0 errors by `std.zig.Ast`:

```zhdl
pub const Counter = module {
    in clk: clock,
    in rst: reset(.async),
    in en: u1,
    out count: u8,
    out overflow: u1,

    reg count_reg: u8 = 0;

    overflow = (count_reg == 255);

    comb {
        if (en != 0) {
            count_reg := count_reg +% 1;
        }
    }

    count = count_reg;
};
```

Desugars directly to:

```zig
const std = @import("std");
const zhdl = @import("zhdl");

pub const Counter = struct {
    clk: zhdl.In(zhdl.Clock),
    rst: zhdl.In(zhdl.AsyncReset),
    en: zhdl.In(u1),
    count: zhdl.Out(u8),
    overflow: zhdl.Out(u1),
    count_reg: zhdl.Reg(u8) = .init(0),

    pub fn comb(self: *@This()) void {
        self.overflow.val = (self.count_reg.q == 255);
        self.count.val = self.count_reg.q;
        if (self.en.get() != 0) {
            self.count_reg.d = (self.count_reg.q +% 1);
        }
    }
};
```

#### CLI Usage:
```bash
zhdl desugar input.zhdl -o output.zig
```

---

## Included Examples (`examples/edsl/`)

1. **`counter.zig`**: Parameterized $W$-bit counter with reset, enable, overflow detection, and rollover testing.
2. **`packet_filter.zig`**: Packet processor showcasing packed structs (`PacketHeader`), tagged unions (`PacketCommand`), asynchronous external pin qualifier (`Async(u1)`), and a 2-stage synchronizer (`sync2ff`).
3. **`fsm.zig`**: Zero-latch finite state machine using strict Zig enums with guaranteed default outputs and cycle-by-cycle state assertions.
4. **`fifo.zig`**: AXI4-Stream FIFO with standard `tvalid`/`tready` backpressure, circular pointers, burst writing, and drain verification.
5. **`arbiter.zig`**: Parameterized priority arbiter with multiple simultaneous request lines.
6. **`skid_buffer.zig`**: Zero-bubble elastic pipeline buffer using optional types (`?UInt(W)`), absorbing downstream stalls without throughput bubbles.
7. **`riscv_decoder.zig`**: Full RISC-V RV32I instruction decoder using packed structs (`RType`, `IType`, `UType`, `BType`), sign-extension methods, and ALU execution (ADDI, ADD, SUB, LUI, BEQ).
8. **`uart.zig`**: AXI4-Stream UART transmitter and receiver (`UartTx`, `UartRx`) with configurable baud prescaler, bit-accurate serialization/deserialization, and full loopback testbench.

---

## Running Tests

Run the full suite of eDSL tests and examples:

```bash
zig build test-edsl --summary all
```

