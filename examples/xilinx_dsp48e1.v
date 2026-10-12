// Behavioral simulation model for DSP48E1 multiplier slice
`timescale 1ns / 1ps

module DSP48E1 #(
    parameter integer A_WIDTH = 25,
    parameter integer B_WIDTH = 18
) (
    input  wire                      clk,
    input  wire [A_WIDTH-1:0]        a,
    input  wire [B_WIDTH-1:0]        b,
    output wire [A_WIDTH+B_WIDTH-1:0] p
);
    // Pure behavioral combinational product
    assign p = a * b;

endmodule
