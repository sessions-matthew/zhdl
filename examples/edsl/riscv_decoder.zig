const std = @import("std");
const zhdl = @import("zhdl");

pub const RType = packed struct {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    funct7: u7,

    pub fn isSub(self: RType) bool {
        return (self.funct7 & 0x20) != 0;
    }
};

pub const IType = packed struct {
    opcode: u7,
    rd: u5,
    funct3: u3,
    rs1: u5,
    imm11_0: u12,

    pub fn getSignExtendedImm(self: IType) u32 {
        const sign_bit = (self.imm11_0 >> 11) & 1;
        if (sign_bit == 1) {
            return 0xFFFFF000 | @as(u32, self.imm11_0);
        } else {
            return @as(u32, self.imm11_0);
        }
    }
};

pub const UType = packed struct {
    opcode: u7,
    rd: u5,
    imm31_12: u20,

    pub fn getLuiVal(self: UType) u32 {
        return @as(u32, self.imm31_12) << 12;
    }
};

pub const BType = packed struct {
    opcode: u7,
    imm11: u1,
    imm4_1: u4,
    funct3: u3,
    rs1: u5,
    rs2: u5,
    imm10_5: u6,
    imm12: u1,

    pub fn getBranchOffset(self: BType) u32 {
        const imm: u13 = (@as(u13, self.imm12) << 12) |
            (@as(u13, self.imm11) << 11) |
            (@as(u13, self.imm10_5) << 5) |
            (@as(u13, self.imm4_1) << 1);

        if (self.imm12 == 1) {
            return 0xFFFFE000 | @as(u32, imm);
        } else {
            return @as(u32, imm);
        }
    }
};

pub const DecodedOp = union(enum) {
    alu_reg: RType,
    alu_imm: IType,
    lui: UType,
    branch: BType,
    illegal: void,
};

pub const RiscvDecoder = struct {
    clk: zhdl.In(zhdl.Clock),
    rst_n: zhdl.In(zhdl.AsyncResetActiveLow),

    raw_inst: zhdl.In(u32),
    rs1_val: zhdl.In(u32),
    rs2_val: zhdl.In(u32),

    alu_result: zhdl.Out(u32),
    branch_taken: zhdl.Out(u1),
    illegal_inst: zhdl.Out(u1),

    pub fn build(b: *zhdl.Builder) !void {
        const u1_t = zhdl.hir.HirType{ .tag = .bits, .width = 1 };
        const u32_t = zhdl.hir.HirType{ .tag = .bits, .width = 32 };

        const rs1_ref = b.ref("rs1_val", u32_t);
        const rs2_ref = b.ref("rs2_val", u32_t);
        const alu_out = b.ref("alu_result", u32_t);
        const branch_out = b.ref("branch_taken", u1_t);
        const illegal_out = b.ref("illegal_inst", u1_t);

        // Synthesis path: default ALU add and flags
        const add_res = b.add(rs1_ref, rs2_ref);
        try b.addComb(b.assign(alu_out, add_res));
        try b.addComb(b.assign(branch_out, b.lit(0, 1)));
        try b.addComb(b.assign(illegal_out, b.lit(0, 1)));
    }

    pub fn comb(self: *@This()) void {
        const inst = self.raw_inst.get();
        const opcode = @as(u7, @truncate(inst));

        self.alu_result.set(0);
        self.branch_taken.set(0);
        self.illegal_inst.set(0);

        switch (opcode) {
            // R-type ALU: ADD, SUB, AND, OR, XOR
            0x33 => {
                const r: RType = @bitCast(inst);
                const a = self.rs1_val.get();
                const b = self.rs2_val.get();

                switch (r.funct3) {
                    0b000 => {
                        if (r.isSub()) {
                            self.alu_result.set(a -% b);
                        } else {
                            self.alu_result.set(a +% b);
                        }
                    },
                    0b111 => self.alu_result.set(a & b), // AND
                    0b110 => self.alu_result.set(a | b), // OR
                    0b100 => self.alu_result.set(a ^ b), // XOR
                    else => self.illegal_inst.set(1),
                }
            },

            // I-type ALU: ADDI, ANDI, ORI, XORI
            0x13 => {
                const i: IType = @bitCast(inst);
                const a = self.rs1_val.get();
                const imm = i.getSignExtendedImm();

                switch (i.funct3) {
                    0b000 => self.alu_result.set(a +% imm), // ADDI
                    0b111 => self.alu_result.set(a & imm), // ANDI
                    0b110 => self.alu_result.set(a | imm), // ORI
                    0b100 => self.alu_result.set(a ^ imm), // XORI
                    else => self.illegal_inst.set(1),
                }
            },

            // U-type: LUI
            0x37 => {
                const u: UType = @bitCast(inst);
                self.alu_result.set(u.getLuiVal());
            },

            // B-type: BEQ, BNE, BLT
            0x63 => {
                const b: BType = @bitCast(inst);
                const a = self.rs1_val.get();
                const b_val = self.rs2_val.get();

                switch (b.funct3) {
                    0b000 => self.branch_taken.set(if (a == b_val) @as(u1, 1) else @as(u1, 0)), // BEQ
                    0b001 => self.branch_taken.set(if (a != b_val) @as(u1, 1) else @as(u1, 0)), // BNE
                    0b100 => self.branch_taken.set(if (@as(i32, @bitCast(a)) < @as(i32, @bitCast(b_val))) @as(u1, 1) else @as(u1, 0)), // BLT
                    else => self.illegal_inst.set(1),
                }
            },

            else => {
                self.illegal_inst.set(1);
            },
        }
    }
};

test "RiscvDecoder synthesis to SystemVerilog" {
    const allocator = std.testing.allocator;

    const sv = try zhdl.emitSystemVerilog(RiscvDecoder, allocator);
    defer allocator.free(sv);

    try std.testing.expect(std.mem.indexOf(u8, sv, "module RiscvDecoder (") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic [31:0] raw_inst") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "input  logic [31:0] rs1_val") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic [31:0] alu_result") != null);
    try std.testing.expect(std.mem.indexOf(u8, sv, "output logic       branch_taken") != null);
}

test "RiscvDecoder real instruction execution" {
    var sim = zhdl.Sim(RiscvDecoder).init();

    // 1. ADDI x1, x0, 42 (0x02A00093)
    sim.dut.raw_inst.set(0x02A00093);
    sim.dut.rs1_val.set(0);
    sim.dut.rs2_val.set(0);
    sim.settle();
    try std.testing.expectEqual(@as(u32, 42), sim.dut.alu_result.get());
    try std.testing.expectEqual(@as(u1, 0), sim.dut.illegal_inst.get());

    // 2. ADD x3, x1, x2 (0x002081B3) with rs1 = 10, rs2 = 20
    sim.dut.raw_inst.set(0x002081B3);
    sim.dut.rs1_val.set(10);
    sim.dut.rs2_val.set(20);
    sim.settle();
    try std.testing.expectEqual(@as(u32, 30), sim.dut.alu_result.get());

    // 3. SUB x3, x1, x2 (0x402081B3) with rs1 = 50, rs2 = 15
    sim.dut.raw_inst.set(0x402081B3);
    sim.dut.rs1_val.set(50);
    sim.dut.rs2_val.set(15);
    sim.settle();
    try std.testing.expectEqual(@as(u32, 35), sim.dut.alu_result.get());

    // 4. LUI x5, 0x12345 (0x123452B7)
    sim.dut.raw_inst.set(0x123452B7);
    sim.settle();
    try std.testing.expectEqual(@as(u32, 0x12345000), sim.dut.alu_result.get());

    // 5. BEQ x1, x2, offset with equal values -> branch taken
    sim.dut.raw_inst.set(0x00208463);
    sim.dut.rs1_val.set(42);
    sim.dut.rs2_val.set(42);
    sim.settle();
    try std.testing.expectEqual(@as(u1, 1), sim.dut.branch_taken.get());

    // 6. BEQ with unequal values -> branch not taken
    sim.dut.rs2_val.set(99);
    sim.settle();
    try std.testing.expectEqual(@as(u1, 0), sim.dut.branch_taken.get());
}
