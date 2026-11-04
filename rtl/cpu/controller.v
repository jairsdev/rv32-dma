`timescale 1ns/1ps

// Controle multiciclo da CPU RV32I.
// FSM: FETCH -> DECODE -> EXEC -> MEM -> WB, mais WAIT (wfi) e HALT.
// FETCH e MEM seguem o handshake valid/ready das portas I e D (README, secao 4.1):
// valid sai direto do estado e so cai depois do ready.
//
// Caminho de cada instrucao:
//   tipo R/I, lui, auipc, jal, jalr : FETCH DECODE EXEC WB
//   load                            : FETCH DECODE EXEC MEM WB
//   store                           : FETCH DECODE EXEC MEM
//   branch, fence                   : FETCH DECODE EXEC
//   wfi                             : FETCH DECODE EXEC [WAIT ate irq = 1]
//   ecall, ebreak, opcode invalido  : FETCH DECODE EXEC HALT (sem trap: a CPU para)
// O PC so muda quando a instrucao termina (transicao para FETCH).
module controller (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] instr,          // IR
    input  wire        branch_taken,   // da ULA, valido em EXEC
    input  wire        i_ready,
    input  wire        d_ready,
    input  wire        irq,

    output wire        i_valid,
    output wire        d_valid,
    output wire        ir_we,          // IR <= i_rdata
    output wire        ab_we,          // A/B <= rs1/rs2
    output wire        alu_out_we,     // ALUOut <= resultado da ULA
    output wire        mdr_we,         // MDR <= d_rdata
    output wire        reg_we,         // escrita em rd
    output wire        pc_we,          // PC <= proximo PC
    output wire        mem_write,      // a instrucao e um store
    output reg  [1:0]  ALU_Op,         // 00 soma, 01 branch, 10 tipo R, 11 tipo I
    output wire        alu_src_a,      // 0 = A (rs1), 1 = PC (auipc)
    output wire        alu_src_b,      // 0 = B (rs2), 1 = imediato
    output reg  [1:0]  wb_sel,         // 0 = load, 1 = ALUOut, 2 = imediato (lui), 3 = PC+4
    output reg  [1:0]  pc_sel,         // 0 = PC+4, 1 = PC+imm, 2 = destino do jalr
    output wire        halt
);

    localparam S_FETCH  = 3'd0;
    localparam S_DECODE = 3'd1;
    localparam S_EXEC   = 3'd2;
    localparam S_MEM    = 3'd3;
    localparam S_WB     = 3'd4;
    localparam S_WAIT   = 3'd5;
    localparam S_HALT   = 3'd6;

    localparam OP_LOAD   = 7'b0000011;
    localparam OP_FENCE  = 7'b0001111;
    localparam OP_IMM    = 7'b0010011;
    localparam OP_AUIPC  = 7'b0010111;
    localparam OP_STORE  = 7'b0100011;
    localparam OP_REG    = 7'b0110011;
    localparam OP_LUI    = 7'b0110111;
    localparam OP_BRANCH = 7'b1100011;
    localparam OP_JALR   = 7'b1100111;
    localparam OP_JAL    = 7'b1101111;
    localparam OP_SYSTEM = 7'b1110011;

    wire [6:0]  opcode  = instr[6:0];
    wire [2:0]  funct3  = instr[14:12];
    wire [11:0] funct12 = instr[31:20];

    wire is_load   = (opcode == OP_LOAD);
    wire is_store  = (opcode == OP_STORE);
    wire is_branch = (opcode == OP_BRANCH);
    wire is_jal    = (opcode == OP_JAL);
    wire is_jalr   = (opcode == OP_JALR);
    wire is_lui    = (opcode == OP_LUI);
    wire is_auipc  = (opcode == OP_AUIPC);
    wire is_reg    = (opcode == OP_REG);
    wire is_imm    = (opcode == OP_IMM);
    wire is_fence  = (opcode == OP_FENCE);
    wire is_wfi    = (opcode == OP_SYSTEM) && (funct3 == 3'b000) && (funct12 == 12'h105);
    wire writes_rd = is_reg || is_imm || is_lui || is_auipc || is_jal || is_jalr;

    reg [2:0] state, next;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            state <= S_FETCH;
        else
            state <= next;
    end

    always @(*) begin
        next = state;
        case (state)
            S_FETCH:  if (i_ready) next = S_DECODE;
            S_DECODE: next = S_EXEC;
            S_EXEC: begin
                if (is_load || is_store)
                    next = S_MEM;
                else if (writes_rd)
                    next = S_WB;
                else if (is_branch || is_fence)
                    next = S_FETCH;
                else if (is_wfi)
                    next = irq ? S_FETCH : S_WAIT;   // irq ja em 1: nao para
                else
                    next = S_HALT;                   // ecall, ebreak ou invalida
            end
            S_MEM:    if (d_ready) next = is_load ? S_WB : S_FETCH;
            S_WB:     next = S_FETCH;
            S_WAIT:   if (irq) next = S_FETCH;
            default:  next = S_HALT;
        endcase
    end

    assign i_valid    = (state == S_FETCH);
    assign d_valid    = (state == S_MEM);
    assign ir_we      = (state == S_FETCH) && i_ready;
    assign ab_we      = (state == S_DECODE);
    assign alu_out_we = (state == S_EXEC);
    assign mdr_we     = (state == S_MEM) && d_ready;
    assign reg_we     = (state == S_WB);
    assign pc_we      = (state != S_FETCH) && (next == S_FETCH);
    assign halt       = (state == S_HALT);

    assign mem_write = is_store;
    assign alu_src_a = is_auipc;
    assign alu_src_b = !(is_reg || is_branch);

    always @(*) begin
        if (is_branch)
            ALU_Op = 2'b01;
        else if (is_reg)
            ALU_Op = 2'b10;
        else if (is_imm)
            ALU_Op = 2'b11;
        else
            ALU_Op = 2'b00;    // load, store, auipc, jalr: soma

        if (is_load)
            wb_sel = 2'd0;
        else if (is_lui)
            wb_sel = 2'd2;
        else if (is_jal || is_jalr)
            wb_sel = 2'd3;
        else
            wb_sel = 2'd1;

        if (is_jal || (is_branch && branch_taken))
            pc_sel = 2'd1;
        else if (is_jalr)
            pc_sel = 2'd2;
        else
            pc_sel = 2'd0;
    end

endmodule
