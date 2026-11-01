`timescale 1ns/1ps

// Unidade basica de processamento (Processing Element) da malha sistolica.
// Opera em modo output-stationary: o elemento de C fica acumulado aqui
// enquanto os operandos de A e B fluem pela malha.
module pe (
    input  wire               clk,
    input  wire               rst_n,
    input  wire               en,
    input  wire               clr_acc,
    input  wire signed [7:0]  a_in,
    input  wire signed [7:0]  b_in,
    output reg  signed [7:0]  a_out,
    output reg  signed [7:0]  b_out,
    output reg  signed [31:0] acc_out
);

    wire signed [15:0] prod;
    assign prod = a_in * b_in;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out   <= 8'sd0;
            b_out   <= 8'sd0;
            acc_out <= 32'sd0;
        end else begin
            // Zera o acumulador no inicio do primeiro bloco k0
            if (clr_acc) begin
                acc_out <= 32'sd0;
            end

            // Quando habilitado, propaga os dados para os vizinhos e acumula
            if (en) begin
                a_out <= a_in;
                b_out <= b_in;
                acc_out <= (clr_acc ? 32'sd0 : acc_out) + {{16{prod[15]}}, prod};
            end
        end
    end

endmodule

