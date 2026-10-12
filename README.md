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

pub module PacketFilter(comptime W: usize) {
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
                    active_header := hdr; // ':=' schedules 1-cycle flop update
                    rx_stream = hdr.len[7:0];
                }
            },
            .idle => {
                rx_stream = null;
            },
        }
    }
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

## Core Signal Model & Assignment Discipline

| Entity | Description | Assignment | SystemVerilog Target |
|---|---|:---:|---|
| **`wire`** | 0-delay combinational net or interconnect | `=` | `logic`, driven in `always_comb` |
| **`reg`** | 1-cycle clocked flip-flop / RAM array | `:=` | `always_ff @(posedge clk)` with `<=` |
| **`const`** | Elaboration-time constant / submodule instance | `=` | SV module instance / parameter |

- **Strict Assignment Discipline ("The One Obvious Way")**:
  - Combinational nets (`wire`) and output ports are assigned strictly with `=`. Using `:=` on a wire triggers a compile error.
  - Clocked state registers (`reg`) are updated inside `comb` blocks strictly with `:=` (including scalar registers, RAM array elements `mem[i] := din`, struct fields `pkt.cmd := val`, bit-slices `flags[0] := 1`, and tuples `.{ a, b } := ...`). Using `=` on a register triggers a compile error.
  - Legacy `.next =` syntax is deprecated with actionable compiler errors directing developers to `:=`.
- **Zero-Latch Guarantee**: Registers maintain default hold (`D = Q`). Transparent latches cannot be synthesized.

---

## Type System

ZHdl brings Zig's type safety, expressive layouts, and first-class algebraic data types to hardware design, replacing untyped Verilog bit vectors:

### 1. Integers & Bit-Vectors (`uN`, `iN`)
- **Unsigned Bit-Vectors (`u1` to `u128`, `u(W)`)**: Explicit bit widths with zero implicit sign extension.
- **Signed Integers (`i1` to `i128`, `i(W)`)**: Two's complement arithmetic, automatically emitting SystemVerilog `logic signed` with signed comparisons (`<`, `<=`, `>`, `>=`) and arithmetic (`*`, `+%`, `-%`).
- **Generic Sizing**: Parameterized bit widths like `u(W)` or `i(DATA_WIDTH)` resolve cleanly at elaboration time.

### 2. Domain Types (`clock`, `reset`)
- **`clock`**: Edge-triggered clock domain (`posedge`).
- **`reset`**: Active-high reset signal.
- **`reset(.low)` / `reset(.high)`**: Explicit reset polarity enforced by the type system—no variable name heuristics. Generates correct sensitivity lists (`@(posedge clk or negedge rst_n)`) and reset assertions (`if (!rst_n)`).

### 3. Unpacked Memory Arrays (`[N]T`)
Hardware RAMs, register files, and FIFO buffers are declared using unpacked arrays:
```zig
reg reg_file: [32]u32 = 0;  // 32-entry 32-bit register file (unpacked array)
wire mem_bank: [16]u8;      // 16-entry 8-bit memory interconnect
```

### 4. Packed Structs (`packed struct`)
Bit-exact hardware layouts with zero padding, MSB-to-LSB field order, and method encapsulation:
```zig
pub const Instruction = packed struct {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct7: u7,

    pub fn isBranch(self: Instruction) u1 {
        return self.opcode == 0b1100011;
    }
};

// Literals and member slicing:
const inst = Instruction{ .opcode = 0x33, ... };
wire is_br = inst.isBranch(); // Pure combinational method call
```

### 5. Hardware Optionals (`?T`)
Native Valid + Data stream handshakes that synthesize directly to `{ valid: u1, data: T }`:
```zig
reg stream_byte: ?u8 = null; // Clears valid bit and data

stream_byte := 8'hA5;        // Auto-wraps: valid = 1, data = 0xA5
if (stream_byte) |data| {    // Payload capture: runs only when valid == 1
    out_byte = data;
}
wire is_valid = stream_byte.valid;
```

### 6. Hardware Tagged Unions (`union(enum)`)
Variant multiplexing with an auto-sized discriminant tag and shared payload space:
```zig
pub const Command = union(enum) {
    ping: u8,
    data: u32,
    idle: void,
};

switch (cmd) {
    .ping => |p| rx = p,
    .data => |d| rx = d[7..0],
    .idle => rx = 0,
}
```

### 7. Comptime Generics (`module(params)`)
Parameterized module templates without boilerplate double-nesting:
```zig
pub module Fifo(comptime DEPTH: usize, comptime WIDTH: usize) { ... }
// Or without explicit comptime keyword:
pub module Counter(WIDTH: usize) { ... }
```

### 8. Multi-File Modularity (`@import`)
First-class multi-file imports for modules, generic templates, packed structs, constants, and helper functions:
```zig
const math = @import("math_pkg.zhdl");
const Adder = @import("alu.zhdl").Adder;

pub module Top {
    in x: u8,
    in y: u8,
    out sum: u8,
    out prod: u16,

    const add0 = Adder.instantiate(.{ .a = x, .b = y, .sum = sum });
    const mult = math.Multiplier.instantiate(.{ .a = x, .b = y, .product = prod });
}
```
Transitive submodule hierarchies are automatically resolved and emitted on-demand into synthesizable SystemVerilog, with compile-time circular import protection.

### 9. Zig-Style Namespaces (`struct { ... }`)
Bare `struct { ... }` blocks act as declaration containers with **zero hardware wire footprint** (`width = 0`). They organize constants, submodules, generic module generators, nested namespaces, types, and helper functions. Associated declarations can also be placed directly inside `packed struct`, `enum`, and `union(enum)`:

```zig
pub const Math = struct {
    pub const SCALE = 4;
    pub const Multiplier = module {
        in a: u8,
        out y: u8,
        comb { y = a * 2; }
    };
    pub fn doubleVal(v: u8) u8 { return v * 2; }
};

pub const State = enum(u2) {
    idle = 0,
    busy = 1,
    pub const RESET_STATE = State.idle;
    pub fn isBusy(self: State) u1 { return self == .busy; }
};

// Dotted access & submodule instantiation:
const mult = Math.Multiplier.instantiate(.{ .a = in_val, .y = out_val });
wire reset_val = State.RESET_STATE;
wire busy = state.isBusy();
```

---

## Language Architecture & Verification

- **Declarative Module Scope & Explicit `comb` Blocks**: Module root is strictly declarative (ports, continuous wire assignments, constants, sub-module instantiations, and register declarations). All procedural combinational logic, control flow (`if`, `switch`, loops), and register updates must be enclosed in explicit `comb { ... }` blocks ("The One Obvious Way"). Bare anonymous `{ ... }` blocks, floating control-flow, and bare register updates at module root are rejected at compile time.
- **Clock Binding to Registers (No `sync` Blocks)**: Clocks and resets are bound directly to registers (`reg(clk, rst)`). Legacy `sync` blocks are deprecated with actionable compiler errors.
- **Flat Testbenches (`test "name" { ... }`)**: Write testbench stimulus, clock generation, reset pulses, stepping, and assertions directly at the top level of `test` blocks.
- **Race-Condition & Read-Before-Write Prevention**: Static analysis verifies combinational wires are written before read, and unifies all procedural logic into a single SystemVerilog `always_comb` process to eliminate simulator delta-cycle event races.
- **Single-Writer Rule**: Multiple concurrent drivers on the same wire or port contention are rejected during semantic elaboration.
- **DAG Combinational Loop Detection**: Zero-delay feedback paths ($a \to b \to a$) are detected via 3-color directed acyclic graph (DAG) cycle checks and rejected before synthesis.
- **Static CDC Verification**: Rejects unsynchronized cross-clock domain transfers at compile time; provides safe crossing via `@sync2ff`.

---

## Built-in Hardware Primitives

- **Native Aggregate Packing `.{ a, b }` & `@concat(a, b, ...)`**: Clean anonymous bit concatenation (`{a, b}`) for bit vectors and tuple register updates (`.{ r_hi, r_lo } := .{ in_data[4..8], in_data[0..4] }`).
- **`@truncate(T, x)` / `@bitCast(T, x)`**: Explicit bit manipulation and sizing.
- **`@bitReverse(x)` / `@byteSwap(x)`**: Zero-cost bit/byte streaming (`{<<{x}}`, `{<<8{x}}`).
- **`@sync2ff(dest_clk, sig)`**: 2-stage synchronizer with `(* ASYNC_REG = "TRUE" *)` synthesis attribute.
- **Downward Slicing (`x[4..0]`)**: Reverse-order bit extraction with zero logic gates.

---

## Simulation & Testbench Primitives

ZHdl provides first-class verification primitives matching modern cycle-accurate and time-based testing workflows:
- **Frequency Literals (`100MHz`, `50MHz`, `1GHz`, `32kHz`)**: Sub-nanosecond precision clock generators (`clk.generate(100MHz)`).
- **Signal-Centric Stepping**: Synchronous edge advancement (`clk.step(5)`, `clk.posedge()`, `clk.negedge()`).
- **Dual-Mode Reset Pulses**: Cycle-based (`rst.pulse(2)`) and physical duration-based (`rst.pulse(20ns)`).
- **Timeout Assertions**: Bounded event detection (`wait_for(cond, 100ns)`, `wait_for(cond, 50)`).

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
| [`packet_filter.zhdl`](examples/packet_filter.zhdl) | Parameterized generic module `pub module PacketFilter(comptime W: usize)`, tagged unions `union(enum)`, optional streams `?u(W)`, type methods, and flat testbench simulation. |
| [`ads131m04.zhdl`](examples/ads131m04.zhdl) | Industrial 24-bit 4-channel delta-sigma ADC hardware interface with synchronous SPI framed protocol, DRDY pulse generation, and register control. |
| [`uart_bridge.zhdl`](examples/uart_bridge.zhdl) | Full-duplex UART receiver/transmitter with start/stop framing, CRC16 verification, byte streaming, and host injection FIFO. |
| [`am335x_timer.zhdl`](examples/am335x_timer.zhdl) | AM335x SoC 32-bit hardware timer peripheral with OCP register bus interface, compare-match interrupts, prescaler, and soft reset. |
| [`sha256.zhdl`](examples/sha256.zhdl) | Complete NIST FIPS 180-4 SHA-256 cryptographic hashing core with 64-round expansion, message schedule buffer (`w_mem`), 8 state variables (`a` through `h`), and standard test vector verification. |
| [`riscv_div.zhdl`](examples/riscv_div.zhdl) | 32-bit non-restoring integer divider with quotient/remainder output, divide-by-zero detection, and multi-cycle completion handshakes. |
| [`serv_alu.zhdl`](examples/serv_alu.zhdl) | Bit-serial RISC-V ALU based on the award-winning SERV core with carry tracking and bit-wise logical operations. |
| [`arbiter.zhdl`](examples/arbiter.zhdl) | 4-client round-robin arbiter with rotating priority mask and single-grant mutual exclusion guarantee. |
| [`uart.zhdl`](examples/uart.zhdl) | Full-duplex UART transceiver with 8N1 framing, 16x oversampling baud rate generator, and loopback testbench. |
| [`fifo.zhdl`](examples/fifo.zhdl) | Parameterized synchronous FIFO with status flags (`full`, `empty`), rollover pointers, and RAM buffer. |
| [`fsm.zhdl`](examples/fsm.zhdl) | Clean Moore/Mealy finite state machine with tagged enum states, one-hot transition logic, and pulse outputs. |
| [`counter.zhdl`](examples/counter.zhdl) | Basic synchronous counter with wrap-around, downward bit slicing `[4..0]`, and flat testbench. |

---

## Acknowledgements

Designed, architected, and implemented in collaboration with **Gemini 4.8 Flash**.

---

## License

MIT License. See [LICENSE](LICENSE) for details.

