`timescale 1ns/1ps
module mux4 (
    input      [1:0]  s,
    input      [31:0] a,  // s = 00
    input      [31:0] b,  // s = 01
    input      [31:0] c,  // s = 10
    input      [31:0] d,  // s = 11
    output reg [31:0] o
);
    always @(*) begin
        case (s)
            2'b00:   o = a;
            2'b01:   o = b;
            2'b10:   o = c;
            default: o = d;
        endcase
    end
endmodule
