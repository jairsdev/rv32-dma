`timescale 1ns/1ps
module controller #(
    /** Macros for signal bit counts **/
    parameter PC_SEL_W  = 2,    // PC_sel width
    parameter REG_SEL_W = 2,     // REG_sel width
)(
    input      [6:0]           opcode,
    input  result_lsb,
    output reg [PC_SEL_W-1:0]  PC_sel,
    output reg [REG_SEL_W-1:0] REG_sel,
    output reg [1:0]           ALU_Op,
    output reg                 we_mem, we_reg, rs1_sel, rs2_sel
);
    localparam R     = 7'b0110011;
    localparam LW    = 7'b0000011;
    localparam I     = 7'b0010011;
    localparam SW    = 7'b0100011;
    localparam B     = 7'b1100011;
    localparam LUI   = 7'b0110111;
    localparam AUIPC = 7'b0010111;
    localparam JAL   = 7'b1101111;
    localparam JALR  = 7'b1100111;

    always @(*) begin
        we_reg = 0;
        rs1_sel = 0;
        rs2_sel = 0;
        we_mem = 0;
        REG_sel = 0;
        PC_sel = 0;
        ALU_Op = 2'b00;

        case (opcode)
            R : begin
                we_reg = 1;
                rs1_sel = 0;
                rs2_sel = 0;
                we_mem = 0;
                REG_sel = 1;
                PC_sel = 0;
                ALU_Op = 2'b10;
            end

            LUI : begin
                we_reg = 1;
                rs1_sel = 0;
                rs2_sel = 1;
                we_mem = 0;
                REG_sel = 2;
                PC_sel = 0;
                ALU_Op = 2'b00;
            end

            AUIPC : begin
                we_reg = 1;
                rs1_sel = 1;
                rs2_sel = 1;
                we_mem = 0;
                REG_sel = 1;
                PC_sel = 0;
                ALU_Op = 2'b00;
            end

            B : begin
                we_reg = 0;
                rs1_sel = 0;
                rs2_sel = 0;
                we_mem = 0;
                if (result_lsb) begin
                    PC_sel = 2;
                end else begin
                    PC_sel = 0;
                end
                ALU_Op = 2'b01;
            end

            LW : begin
                we_reg = 1;
                rs1_sel = 0;
                rs2_sel = 1;
                we_mem = 0;
                REG_sel = 0;
                PC_sel = 0;
                ALU_Op = 2'b00;
            end

            SW : begin
                we_reg = 0;
                rs1_sel = 0;
                rs2_sel = 1;
                we_mem = 1;
                PC_sel = 0;
                ALU_Op = 2'b00;
            end

            JAL : begin
                we_reg = 1;
                rs1_sel = 1;
                rs2_sel = 1;
                we_mem = 0;
                REG_sel = 3;
                PC_sel = 2;
                ALU_Op = 2'b00;
            end

            JALR : begin
                we_reg = 1;
                rs1_sel = 0;
                rs2_sel = 1;
                we_mem = 0;
                REG_sel = 3;
                PC_sel = 1;
                ALU_Op = 2'b00;
            end

            I : begin
                we_reg = 1;
                rs1_sel = 0;
                rs2_sel = 1;
                we_mem = 0;
                REG_sel = 1;
                PC_sel = 0;
                ALU_Op = 2'b11;
            end
            default: begin
                we_reg = 0;
                rs1_sel = 0;
                rs2_sel = 0;
                we_mem = 0;
                REG_sel = 0;
                PC_sel = 0;
                ALU_Op = 2'b00;
            end
        endcase
    end
    
endmodule