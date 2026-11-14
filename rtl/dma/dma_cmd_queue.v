`timescale 1ns/1ps
`default_nettype none

// Fila de 1 comando dos motores AXI (MAS secao 5.4).
// Guarda o comando seguinte enquanto o motor executa o corrente.
// in_ready depende so do flop full_q: nao ha caminho combinacional de
// out_pop para in_ready, entao entrada e saida nunca coincidem no mesmo ciclo.
module dma_cmd_queue #(
    parameter WIDTH = 32
)(
    input  wire             clk,
    input  wire             rst_n,

    // Lado da FSM (dma_load / dma_store)
    input  wire             in_valid,
    output wire             in_ready,
    input  wire [WIDTH-1:0] in_data,

    // Lado do motor
    output wire             out_valid,
    output wire [WIDTH-1:0] out_data,
    input  wire             out_pop     // o motor tornou o comando corrente
);

    reg             full_q;
    reg [WIDTH-1:0] data_q;

    assign in_ready  = ~full_q;
    assign out_valid = full_q;
    assign out_data  = data_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            full_q <= 1'b0;
            data_q <= {WIDTH{1'b0}};
        end else if (in_valid && in_ready) begin
            full_q <= 1'b1;
            data_q <= in_data;
        end else if (out_pop) begin
            full_q <= 1'b0;
        end
    end

endmodule

`default_nettype wire
