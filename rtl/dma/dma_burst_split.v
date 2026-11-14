`timescale 1ns/1ps
`default_nettype none

// Divisao de um pedido em segmentos (MAS secao 10.3). Combinacional.
// seg_len = min(rest, MAX_BURST, palavras ate a fronteira de 4 KB)
// Usado pelos dois motores AXI, para que a regra dos 4 KB exista em um so lugar.
module dma_burst_split #(
    parameter MAX_BURST = 16    // 1 ... 16
)(
    input  wire [31:0] addr,     // endereco alinhado a 4 do proximo segmento
    input  wire [4:0]  rest,     // palavras que faltam (inclui este segmento)
    output wire [4:0]  seg_len,  // beats deste segmento
    output wire [7:0]  axlen     // AxLEN = seg_len - 1
);

    localparam [4:0] MAX_BURST_L = MAX_BURST;

    // Palavras de addr ate o fim da pagina de 4 KB: 1 ... 1024
    wire [10:0] words_to_4k = 11'd1024 - {1'b0, addr[11:2]};

    // Limite pelo tamanho maximo de burst
    wire [4:0]  len_burst = (rest > MAX_BURST_L) ? MAX_BURST_L : rest;

    // Limite pela fronteira de 4 KB
    wire        hits_4k = (words_to_4k < {6'd0, len_burst});

    assign seg_len = hits_4k ? words_to_4k[4:0] : len_burst;
    assign axlen   = {3'd0, seg_len} - 8'd1;

endmodule

`default_nettype wire
