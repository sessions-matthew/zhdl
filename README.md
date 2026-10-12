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
pub const PacketHeader = packed struct {
    tag: u4,
    len: u12,

    pub fn isNull(self: PacketHeader) u1 {
        return self.tag == 0;
    }
};

pub const Command = union(enum) {
    ping: u8,
    data: PacketHeader,
    idle: void,
};

pub fn PacketFilter(comptime W: usize) type {
    return module {
        in clk: clock,
        in rst: reset,
        in cmd: Command,
        out rx_stream: ?u(W),

        reg active_header: ?PacketHeader = null;

        comb {
            switch (cmd) {
                .ping => |echo| {
                    rx_stream = echo; // Auto-wraps payload into valid/data stream
                },
                .data => |hdr| {
                    if (hdr.isNull()) {
                        active_header := null; // Clears optional register
                        rx_stream = null;
                    } else {
                        active_header := hdr;  // ':=' schedules 1-cycle flop update
                        rx_stream = hdr.len[7:0];
                    }
                },
                .idle => {
                    rx_stream = null;
                },
            }
        }
    };
}

test "PacketFilter processes commands" {
    wire clk: clock;
    wire rst: reset;
    wire cmd: Command;
    wire rx_stream: ?u8;

    const dut = PacketFilter(8).instantiate(.{
        .clk = clk,
        .rst = rst,
        .cmd = cmd,
        .rx_stream = rx_stream,
    });

    sim {
        clk.generate(10);
        trace("filter_tb.vcd");
        rst.pulse(2);

        cmd = Command{ .ping = 0xA5 };
        step(clk, 1);
        assert(rx_stream.valid == 1, "Should be valid");
        assert(rx_stream.data == 0xA5, "Should echo ping");

        cmd = Command{ .idle = 0 };
        step(clk, 1);
        assert(rx_stream.valid == 0, "Should be idle/null");
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

### Zig-Inspired Type System
- **`packed struct`**: Bit-exact hardware layouts, struct literals `.{ ... }`, and member slicing (`s.field`).
- **`?T` (Hardware Optionals)**: Valid + Data channels with `null` literal, auto-wrapping, and `if (opt) |data|` payload capture.
- **`union(enum)`**: Hardware tagged unions with discriminant tag + payload multiplexing and `switch` pattern matching with capture.
- **Type Methods (`pub fn`)**: Pure combinational inlined helper functions attached to structs and unions.
- **Comptime Generics (`fn(comptime ...) type`)**: Parameterized module templates monomorphized into specialized synthesizable modules.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

