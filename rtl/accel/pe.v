`timescale 1ns/1ps

module pe (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,
    input  wire               clr_acc,
    input  wire signed [7:0]  a_in,
    input  wire signed [7:0]  b_in,
    output reg  signed [7:0]  a_out,
    output reg  signed [7:0]  b_out,
    output reg  signed [31:0] acc_out,
    output wire signed [31:0] acc_next
);

    wire signed [15:0] prod;
    assign prod = a_in * b_in;

    // acc_next e o valor que o acumulador vai ter na proxima borda. O accel usa
    // isso para copiar C para o banco no mesmo ciclo em que entra o ultimo produto.
    wire signed [31:0] acc_base = clr_acc ? 32'sd0 : acc_out;
    assign acc_next = en ? (acc_base + {{16{prod[15]}}, prod}) : acc_base;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out   <= 8'sd0;
            b_out   <= 8'sd0;
            acc_out <= 32'sd0;
        end else begin
            acc_out <= acc_next;

            // os operandos so andam para os vizinhos enquanto a malha esta rodando
            if (en) begin
                a_out <= a_in;
                b_out <= b_in;
            end
        end
    end

endmodule
