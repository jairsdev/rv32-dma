`timescale 1ns/1ps

// CPU RISC-V RV32I multiciclo (README, secoes 1, 2 e 4.1).
// - Porta I (fetch) e Porta D (load/store) com handshake valid/ready: a CPU
//   sobe valid com endereco/dados estaveis e os mantem ate ready = 1.
// - irq (nivel) acorda a CPU do wfi.
// - halt = 1 depois de ecall, ebreak ou instrucao invalida (nao ha trap/CSRs).
// Registradores entre os estados: PC, IR, A, B, ALUOut e MDR.
module rv32i_cpu #(
    parameter RESET_PC = 32'h0000_0000
)(
    input  wire        clk,
    input  wire        rst_n,

    // Porta I -> IMEM local
    output wire        i_valid,
    output wire [31:0] i_addr,
    input  wire        i_ready,
    input  wire [31:0] i_rdata,

    // Porta D -> cpu_axi_adapter
    output wire        d_valid,
    output wire [31:0] d_addr,
    output wire [3:0]  d_wstrb,
    output wire [31:0] d_wdata,
    input  wire        d_ready,
    input  wire [31:0] d_rdata,

    input  wire        irq,
    output wire        halt
);

    reg [31:0] pc, ir, a, b, alu_out, mdr;

    wire        ir_we, ab_we, alu_out_we, mdr_we, reg_we, pc_we, mem_write;
    wire        alu_src_a, alu_src_b, branch_taken;
    wire [1:0]  ALU_Op, wb_sel, pc_sel;
    wire [3:0]  ALU_Control;
    wire [31:0] imm_ext, rs1_o, rs2_o, alu_result;

    wire [2:0] funct3 = ir[14:12];

    controller u_controller (
        .clk(clk), .rst_n(rst_n), .instr(ir), .branch_taken(branch_taken),
        .i_ready(i_ready), .d_ready(d_ready), .irq(irq),
        .i_valid(i_valid), .d_valid(d_valid),
        .ir_we(ir_we), .ab_we(ab_we), .alu_out_we(alu_out_we), .mdr_we(mdr_we),
        .reg_we(reg_we), .pc_we(pc_we), .mem_write(mem_write),
        .ALU_Op(ALU_Op), .alu_src_a(alu_src_a), .alu_src_b(alu_src_b),
        .wb_sel(wb_sel), .pc_sel(pc_sel), .halt(halt)
    );

    imm_gen u_imm_gen (.instr(ir), .imm_ext(imm_ext));

    alu_controller u_alu_controller (
        .ALU_Op(ALU_Op), .funct3(funct3), .funct7(ir[31:25]), .ALU_Control(ALU_Control)
    );

    ALU u_alu (
        .a(alu_src_a ? pc : a), .b(alu_src_b ? imm_ext : b),
        .ALUControl(ALU_Control), .result(alu_result), .branch_taken(branch_taken)
    );

    // Escrita em rd
    wire [31:0] ld_word = mdr >> {alu_out[1:0], 3'b000};   // byte/half na lane 0
    reg  [31:0] ld_data, wb_data;

    always @(*) begin
        case (funct3)
            3'b000:  ld_data = {{24{ld_word[7]}},  ld_word[7:0]};    // lb
            3'b001:  ld_data = {{16{ld_word[15]}}, ld_word[15:0]};   // lh
            3'b100:  ld_data = {24'b0, ld_word[7:0]};                // lbu
            3'b101:  ld_data = {16'b0, ld_word[15:0]};               // lhu
            default: ld_data = mdr;                                  // lw
        endcase

        case (wb_sel)
            2'd0:    wb_data = ld_data;
            2'd1:    wb_data = alu_out;
            2'd2:    wb_data = imm_ext;
            default: wb_data = pc + 32'd4;
        endcase
    end

    reg_bank u_reg_bank (
        .clk(clk), .rst_n(rst_n), .we(reg_we),
        .rs1(ir[19:15]), .rs2(ir[24:20]), .rd(ir[11:7]),
        .wr_rd(wb_data), .rs1_o(rs1_o), .rs2_o(rs2_o)
    );

    // Proximo PC: branch/jal usam PC+imm; jalr usa (rs1 + imm) com bit 0 zerado
    wire [31:0] pc_next = (pc_sel == 2'd1) ? pc + imm_ext :
                          (pc_sel == 2'd2) ? {alu_out[31:1], 1'b0} :
                                             pc + 32'd4;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc      <= RESET_PC;
            ir      <= 32'd0;
            a       <= 32'd0;
            b       <= 32'd0;
            alu_out <= 32'd0;
            mdr     <= 32'd0;
        end else begin
            if (pc_we)      pc      <= pc_next;
            if (ir_we)      ir      <= i_rdata;
            if (ab_we)      a       <= rs1_o;
            if (ab_we)      b       <= rs2_o;
            if (alu_out_we) alu_out <= alu_result;
            if (mdr_we)     mdr     <= d_rdata;
        end
    end

    // Porta I
    assign i_addr = pc;

    // Porta D: endereco do byte; store com o dado ja na lane e d_wstrb por tamanho
    assign d_addr  = alu_out;
    assign d_wdata = b << {alu_out[1:0], 3'b000};
    assign d_wstrb = !mem_write       ? 4'b0000 :
                     funct3[1]        ? 4'b1111 :                       // sw
                     funct3[0]        ? (4'b0011 << alu_out[1:0]) :     // sh
                                        (4'b0001 << alu_out[1:0]);      // sb

endmodule
