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
        in rst_n: reset(.low),
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
    wire rst_n: reset(.low);
    wire cmd: Command;
    wire rx_stream: ?u8;

    const dut = PacketFilter(8).instantiate(.{
        .clk = clk,
        .rst_n = rst_n,
        .cmd = cmd,
        .rx_stream = rx_stream,
    });

    sim {
        clk.generate(100MHz); // First-class frequency literal (10ns period)
        trace("filter_tb.vcd");
        rst_n.pulse(20ns);    // Asynchronous real-time reset pulse

        cmd = Command{ .ping = 0xA5 };
        clk.step();           // Synchronous 1-cycle clock step
        assert(rx_stream.valid == 1, "Should be valid");
        assert(rx_stream.data == 0xA5, "Should echo ping");

        cmd = Command{ .idle = 0 };
        clk.step();
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
# Output binary generated at ./zig-out/bin/zhdl
```

### Core Commands
```bash
# Compile ZHdl to synthesizable SystemVerilog
./zhdl compile examples/counter.zhdl -o counter.sv

# Run simulation testbench with Verilator timing backend (with external Verilog sources)
./zhdl test examples/counter.zhdl --include vendor_ip.v -I ./include/

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

### Zig-Inspired Type System & Verification
- **`packed struct`**: Bit-exact hardware layouts, struct literals `.{ ... }`, and member slicing (`s.field`).
- **`?T` (Hardware Optionals)**: Valid + Data channels with `null` literal, auto-wrapping, and payload capture.
- **`union(enum)`**: Hardware tagged unions with tag + payload multiplexing and `switch` pattern matching.
- **Type Methods (`pub fn`)**: Pure combinational inlined helper functions attached directly to structs and unions.
- **Comptime Generics (`fn(comptime ...) type`)**: Parameterized module templates monomorphized into specialized modules.
- **Typed Reset Polarity**: `reset(.low)` and `reset(.high)` with explicit polarity and zero name heuristics.
- **Modern Simulation Primitives**:
  - Frequency literals (`100MHz`, `50MHz`, `1GHz`, `32kHz`) with sub-nanosecond precision.
  - Signal-centric stepping (`clk.step(5)`, `clk.posedge()`, `clk.negedge()`).
  - Dual-mode reset pulses: cycle-based (`rst.pulse(2)`) and duration-based (`rst.pulse(20ns)`).
  - Timeout assertions: `wait_for(cond, 100ns)` and `wait_for(cond, 50)`.

### HDL Interoperability & Black Box Modules
Seamlessly interface with existing Verilog, SystemVerilog, or vendor IP blocks (e.g., DSP slices, PLLs, BRAMs):

```zig
// 1. Black Box Declaration with Synthesizable Stub Generation
pub const XilinxDsp = extern("DSP48E1") module {
    const A_WIDTH: u32 = 25;
    const B_WIDTH: u32 = 18;

    in clk: clock,
    in a: u25,
    in b: u18,
    out p: u43,
};

// 2. Direct Source Inclusion via .include
pub const VendorMultiplier = extern("vendor_multiplier", .{ .include = "vendor_mult.v" }) module {
    in a: u8,
    in b: u8,
    out prod: u16,
};

// 3. Module Parameter Overrides on Instantiation
const dsp = XilinxDsp.instantiate(
    .{ .A_WIDTH = 25, .B_WIDTH = 18 },       // Module parameters
    .{ .clk = clk, .a = a, .b = b, .p = p },  // Port connections
);
```

- **Synthesis Black Box**: Declarations without source emit `(* blackbox *) module ...` stubs guarded with Verilator lint-off directives for zero-warning EDA tool synthesis.
- **Direct Source Inclusion**: Declarations specifying `.include = "file.v"` emit `` `include "file.v" `` and automatically link into Verilator simulations.
- **Parameter Passing**: Full support for Verilog module parameters via 2-argument form (`.instantiate(.{ .PARAM = val }, .{ .port = clk })`) and 1-argument form (`.instantiate(.{ .parameters = .{ ... }, .ports = .{ ... } })`).
- **CLI External Source Flags**: Pass `--include <file.v>` and `-I <dir>` to link external IP into simulation and lint runs.

---

## Example Designs

The [`examples/`](examples/) directory includes full, self-contained hardware designs covering every language feature, verified against both `./zhdl lint` (Verilator `-Wall`) and `./zhdl test`:

| Example | Highlights & Language Features Demonstrated |
|---|---|
| [`network_packet.zhdl`](examples/network_packet.zhdl) | Network frame parser with `@byteSwap` (network big-endian to host little-endian conversion), `@bitReverse` (serial streaming bit reflection), `@clog2` width calculation, compile-time unrolling with `inline for (0..4) \|i\|`, and downward bit slicing `[31..0]`. |
| [`register_file.zhdl`](examples/register_file.zhdl) | 32-entry dual-read single-write unpacked register memory array (`reg bank: [32]u32 = 0`), write-through forwarding bypass (RAW hazard avoidance), hardwired `x0` zero immutability, and race-free negedge stimulus timing. |
| [`signed_dsp.zhdl`](examples/signed_dsp.zhdl) | Signed bit-vectors (`i8`, `i16`, `i32`), SystemVerilog `logic signed` emission, signed multiplication and arithmetic (`*`, `+%`, `-%`), signed relational comparisons (`< 0`, `> 0`), and two's complement saturating clamp. |
| [`watchdog_timer.zhdl`](examples/watchdog_timer.zhdl) | Programmable watchdog timer peripheral with prescaler, reload strobe (`pet`), pre-timeout warning interrupt (`wdt_warn_irq`), hard system reset pulse (`wdt_reset_out`), and real-time verification (`wait_for(cond, 150ns)`, `assert_within(cond, 100ns)`, `delay(20ns)`). |
| [`blackbox_dsp.zhdl`](examples/blackbox_dsp.zhdl) | `extern("DSP48E1", .{ .include = "..." })` black box IP integration, compile-time Verilog parameter overrides (`.A_WIDTH`, `.B_WIDTH`), synthesizable stubs, and 100MHz behavioral testbench. |
| [`riscv_decoder.zhdl`](examples/riscv_decoder.zhdl) | Complete RV32I instruction decoder and execution unit using `packed struct` with type methods (`isSub()`, `getSignExtendedImm()`, `getLuiVal()`, `getBranchOffset()`), hardware tagged unions `union(enum)`, pattern matching `switch`, and bit-exact sign-extension. |
| [`skid_buffer.zhdl`](examples/skid_buffer.zhdl) | Zero-bubble elastic pipeline stream buffering with ready/valid backpressure, hardware optionals `?T`, `null` checks, auto-wrapping, and 2-entry internal queueing. |
| [`async_fifo.zhdl`](examples/async_fifo.zhdl) | Dual asynchronous clock domains (100MHz write, 33MHz read), active-low resets (`reset(.low)`), Gray code pointer conversion, static CDC checking, and safe CDC synchronization via `@sync2ff`. |
| [`packet_filter.zhdl`](examples/packet_filter.zhdl) | Parameterized generic module `fn(comptime W: usize) type`, tagged unions `union(enum)`, optional streams `?u(W)`, type methods, and clock/reset simulation primitives. |
| [`ads131m04.zhdl`](examples/ads131m04.zhdl) | Industrial 24-bit 4-channel delta-sigma ADC hardware interface with synchronous SPI framed protocol, DRDY pulse generation, and register control. |
| [`uart_bridge.zhdl`](examples/uart_bridge.zhdl) | Full-duplex UART receiver/transmitter with start/stop framing, CRC16 verification, byte streaming, and host injection FIFO. |
| [`am335x_timer.zhdl`](examples/am335x_timer.zhdl) | AM335x SoC 32-bit hardware timer peripheral with OCP register bus interface, compare-match interrupts, prescaler, and soft reset. |
| [`fifo.zhdl`](examples/fifo.zhdl) | Parameterized synchronous FIFO with status flags (`full`, `empty`), rollover pointers, and RAM buffer. |
| [`fsm.zhdl`](examples/fsm.zhdl) | Clean Moore/Mealy finite state machine with tagged enum states, one-hot transition logic, and pulse outputs. |
| [`counter.zhdl`](examples/counter.zhdl) | Basic synchronous counter with wrap-around and synchronous reset. |

---

## Acknowledgements

Designed, architected, and implemented in collaboration with **Gemini 4.8 Flash**.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

