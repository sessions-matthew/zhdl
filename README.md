# ZHdl

A modern **Hardware Description Language (HDL)** inspired by **Zig**, compiling to synthesizable **IEEE 1800 SystemVerilog** with zero ambiguity.

> 📖 **Full Language Specification**: For formal grammar, typing rules, built-in primitives, CDC invariants, and SystemVerilog codegen mappings, see the [ZHdl Language Reference Manual](docs/language_reference.md).

---

## Why ZHdl?

- **Zero-Latch Guarantee**: Registers automatically maintain default-hold (`D = Q`). Transparent latches are impossible.
- **Race-Free Semantics**: Strict physical separation—combinational logic lowers to `always_comb` with `=`, sequential registers lower to `always_ff` with `<=`.
- **Compile-Time Safety**:
  - **Loop Detection**: Rejects combinational feedback cycles at compile time via DAG cycle analysis.
  - **Single Driver Enforcement**: Multiple drivers on the same wire are rejected before codegen.
  - **CDC Verification**: Statically catches unsynchronized cross-clock domain transfers; provides safe crossing via `@sync2ff`.

---

## Quick Look

```zig
pub const Counter = module {
    in clk: clock,
    in rst: reset,
    in en: u1,
    out count: u8,
    out overflow: u1,
    out rev_nibble: u4,

    reg count_reg: u8 = 0;

    comb {
        overflow = (count_reg == 255);
        if (en) {
            count_reg := count_reg +% 1; // ':=' schedules 1-cycle flop update
        }
        count = count_reg;
        rev_nibble = count_reg[4..0];    // Downward slicing: bits [3:0] in reverse order
    }
};

test "Counter increments and rolls over" {
    wire clk: clock;
    wire rst: reset;
    wire en: u1;
    wire count: u8;
    wire overflow: u1;
    wire rev_nibble: u4;

    const dut = Counter.instantiate(.{
        .clk = clk, .rst = rst, .en = en,
        .count = count, .overflow = overflow, .rev_nibble = rev_nibble,
    });

    sim {
        clk.generate(10);
        trace("counter_tb.vcd");
        rst.pulse(2);

        en = 1;
        step(clk, 10);
        assert(count == 10, "Counter should reach 10");
        finish();
    }
}
```

---

## CLI Usage

### Build Compiler
Requires **Zig 0.17.0**:
```bash
zig build -Doptimize=ReleaseFast
# Or: zig build-exe src/main.zig -O ReleaseFast --name zhdl
```

### Core Commands
```bash
# Compile ZHdl to synthesizable SystemVerilog
./zhdl compile examples/counter.zhdl -o counter.sv

# Run simulation testbench with Verilator timing backend
./zhdl test examples/counter.zhdl

# Compile and run Verilator lint check (-Wall)
./zhdl lint examples/uart_bridge.zhdl

# Syntax and semantic verification check (latch freedom, CDC, loops)
./zhdl check examples/am335x_timer.zhdl
```

---

## Core Language Rules

| Entity | Description | Assignment | SystemVerilog Target |
|---|---|:---:|---|
| **`wire`** | 0-delay combinational net or interconnect | `=` | `logic`, driven in `always_comb` |
| **`reg`** | 1-cycle clocked flip-flop / RAM array | `:=` | `always_ff @(posedge clk)` with `<=` |
| **`const`** | Elaboration-time constant / submodule instance | `=` | SV module instance / parameter |

### Key Built-in Primitives
- **`@concat(a, b, ...)`**: Vector concatenation (`{a, b}`).
- **`@truncate(T, x)` / `@bitCast(T, x)`**: Explicit bit manipulation and sizing.
- **`@bitReverse(x)` / `@byteSwap(x)`**: Zero-cost bit/byte streaming (`{<<{x}}`, `{<<8{x}}`).
- **`@sync2ff(dest_clk, sig)`**: 2-stage synchronizer with `(* ASYNC_REG = "TRUE" *)` synthesis attribute.
- **Downward Slicing (`x[4..0]`)**: Reverse-order bit extraction with zero logic gates.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

