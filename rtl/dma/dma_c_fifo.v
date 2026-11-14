`timescale 1ns/1ps
`default_nettype none

// Fila de 2 entradas dos dados de C (MAS secao 10.2).
// Absorve o ciclo de latencia entre c_rd e c_rdata para que o canal W
// entregue 1 beat por ciclo.
// Fila por deslocamento: d0_q e sempre a cabeca, entao WDATA sai direto de flop.
// Quem empilha (dma_wr_engine) controla o credito; a fila nao tem backpressure.
module dma_c_fifo (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        push,
    input  wire [31:0] push_data,
    input  wire        pop,

    output wire [31:0] head,
    output wire [1:0]  count
);

    reg [31:0] d0_q;
    reg [31:0] d1_q;
    reg [1:0]  count_q;

    // Ocupacao depois do pop deste ciclo: decide onde o push grava
    wire [1:0] count_after_pop = count_q - {1'b0, pop};
    wire       push_to_head    = (count_after_pop == 2'd0);

    assign head  = d0_q;
    assign count = count_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            d0_q    <= 32'd0;
            d1_q    <= 32'd0;
            count_q <= 2'd0;
        end else begin
            if (pop)
                d0_q <= d1_q;

            if (push) begin
                if (push_to_head)
                    d0_q <= push_data;   // vence o deslocamento acima
                else
                    d1_q <= push_data;
            end

            count_q <= count_after_pop + {1'b0, push};
        end
    end

`ifdef DMA_ASSERT
    always @(posedge clk) begin
        if (rst_n && pop && (count_q == 2'd0))
            $error("dma_c_fifo: pop com a fila vazia");
        if (rst_n && push && (count_after_pop == 2'd2))
            $error("dma_c_fifo: push com a fila cheia");
    end
`endif

endmodule

`default_nettype wire
