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

## Included Examples (`examples/edsl/`)

1. **`counter.zig`**: Parameterized $W$-bit counter with reset, enable, overflow detection, and rollover testing.
2. **`packet_filter.zig`**: Packet processor showcasing packed structs (`PacketHeader`), tagged unions (`PacketCommand`), asynchronous external pin qualifier (`Async(u1)`), and a 2-stage synchronizer (`sync2ff`).
3. **`fsm.zig`**: Zero-latch finite state machine using strict Zig enums with guaranteed default outputs and cycle-by-cycle state assertions.
4. **`fifo.zig`**: AXI4-Stream FIFO with standard `tvalid`/`tready` backpressure, circular pointers, burst writing, and drain verification.
5. **`arbiter.zig`**: Parameterized priority arbiter with multiple simultaneous request lines.

---

## Running Tests

Run the full suite of eDSL tests and examples:

```bash
zig build test-edsl --summary all
```
