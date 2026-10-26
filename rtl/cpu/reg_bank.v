`timescale 1ns/1ps
// Banco de registradores RV32I: 32 x 32 bits, 2 leituras (rs1, rs2), 1 escrita (rd)
// x0 é fixo em zero.
module reg_bank (
    input         clk,
    input         rst_n,
    input         we,
    input  [4:0]  rs1,
    input  [4:0]  rs2,
    input  [4:0]  rd,
    input  [31:0] wr_rd,
    output [31:0] rs1_o,
    output [31:0] rs2_o
);
    reg [31:0] mem [31:0];

    integer i;

    // leitura combinacional
    assign rs1_o = (rs1 == 5'd0) ? 32'd0 : mem[rs1];
    assign rs2_o = (rs2 == 5'd0) ? 32'd0 : mem[rs2];

    // escrita síncrona, reset síncrono ativo em nível baixo
    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1)
                mem[i] <= 32'd0;
        end else if (we && rd != 5'd0) begin
            mem[rd] <= wr_rd;
        end
    end
endmodule
