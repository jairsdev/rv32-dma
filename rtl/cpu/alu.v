`timescale 1ns/1ps
module alu (
    input  wire [31:0] a,
    input  wire [31:0] b,
    input  wire [3:0]  ALU_Control,
    output reg  [31:0] result
);
    localparam ADD  = 4'b0000;  // a + b
    localparam SUB  = 4'b0001;  // a - b
    localparam AND  = 4'b0010;  // a & b
    localparam OR   = 4'b0011;  // a | b
    localparam XOR  = 4'b0100;  // a ^ b
    localparam SLL  = 4'b0101;  // a << b   deslocamento lógico à esquerda
    localparam SRL  = 4'b0110;  // a >> b   deslocamento lógico à direita
    localparam SRA  = 4'b0111;  // a >>> b  deslocamento aritmético à direita
    localparam EQ   = 4'b1000;  // a == b
    localparam ULT  = 4'b1001;  // a <  b   (sem sinal)
    localparam UGTE = 4'b1010;  // a >= b   (sem sinal)
    localparam SLT  = 4'b1011;  // a <  b   (com sinal)
    localparam SGTE = 4'b1100;  // a >= b   (com sinal)
    localparam NE   = 4'b1101;  // a != b   (BNE)

    wire [4:0] shamt = b[4:0];

    always @(*) begin
        case (ALU_Control)
            ADD:     result = a + b;
            SUB:     result = a - b;
            AND:     result = a & b;
            OR:      result = a | b;
            XOR:     result = a ^ b;
            SLL:     result = a << shamt;
            SRL:     result = a >> shamt;
            SRA:     result = $signed(a) >>> shamt;
            EQ:      result = {31'b0, (a == b)};
            ULT:     result = {31'b0, (a <  b)};
            UGTE:    result = {31'b0, (a >= b)};
            SLT:     result = {31'b0, ($signed(a) <  $signed(b))};
            SGTE:    result = {31'b0, ($signed(a) >= $signed(b))};
            NE:      result = {31'b0, (a != b)};
            default: result = 32'b0;
        endcase
    end
endmodule
