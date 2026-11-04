`timescale 1ns/1ps
module alu_controller (
    input      [1:0] ALU_Op,
    input      [2:0] funct3,
    input      [6:0] funct7,
    output reg [3:0] ALU_Control
);
    // Mesma codificação da ULA (rtl/alu.v): tipo R/I usa {funct7[5], funct3}
    localparam ADD  = 4'b0000, SLL  = 4'b0001, SLT  = 4'b0010, SLTU = 4'b0011,
               XOR_ = 4'b0100, SRL  = 4'b0101, OR_  = 4'b0110, AND_ = 4'b0111,
               SUB  = 4'b1000, BEQ  = 4'b1001, BNE  = 4'b1010, BGE  = 4'b1011,
               BLT  = 4'b1100, SRA  = 4'b1101, BLTU = 4'b1110, BGEU = 4'b1111;

    always @(*) begin
        case (ALU_Op)
            2'b00: ALU_Control = ADD;   // load/store/auipc/jal/jalr/lui
            2'b01: begin                // branches
                case (funct3)
                    3'b000:  ALU_Control = BEQ;
                    3'b001:  ALU_Control = BNE;
                    3'b100:  ALU_Control = BLT;
                    3'b101:  ALU_Control = BGE;
                    3'b110:  ALU_Control = BLTU;
                    3'b111:  ALU_Control = BGEU;
                    default: ALU_Control = ADD;
                endcase
            end
            default: begin              // 10 = R, 11 = I
                case (funct3)
                    3'b000: ALU_Control = (ALU_Op == 2'b10 && funct7[5]) ? SUB : ADD;
                    3'b001: ALU_Control = SLL;
                    3'b010: ALU_Control = SLT;
                    3'b011: ALU_Control = SLTU;
                    3'b100: ALU_Control = XOR_;
                    3'b101: ALU_Control = funct7[5] ? SRA : SRL;
                    3'b110: ALU_Control = OR_;
                    3'b111: ALU_Control = AND_;
                endcase
            end
        endcase
    end
endmodule
