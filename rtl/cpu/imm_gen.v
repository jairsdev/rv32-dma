`timescale 1ns/1ps
module imm_gen (
    input  [31:0] instr,
    output reg [31:0] imm_ext
);
    /** Module Behavior **/
    always @(*) begin
        case (instr[6:0])
            7'b0000011,
            7'b0010011,
            7'b1100111:  // I-type: Load, Non-Load e JALR
                imm_ext = {instr[31] ? {20{1'b1}} : 20'b0,
                           instr[31:20]};

            7'b0100011:  // S-type: Store
                imm_ext = {instr[31] ? {20{1'b1}} : 20'b0,
                           instr[31:25], instr[11:7]};

            7'b0010111,
            7'b0110111:  // U-type and LUI
                imm_ext = {instr[31:12], 12'b0};

            7'b1100011: //B-type
                imm_ext = {{19{instr[31]}}, instr[31], instr[7], 
                instr[30:25], instr[11:8], 1'b0};
            
            7'b1101111:  // J-type: JAL
                imm_ext = {{11{instr[31]}}, instr[31], instr[19:12], 
                instr[20], instr[30:21], 1'b0};
            
            default:     // Default: No output
                imm_ext = {32'b0};
        endcase
    end

endmodule
