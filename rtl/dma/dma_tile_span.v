`timescale 1ns/1ps
`default_nettype none

// Extensao valida de um tile em uma dimensao. Combinacional.
// span = min(T, dim - origin): quantas linhas/colunas do tile que comeca em
// "origin" caem dentro da matriz de tamanho "dim".
// Pre-condicao: origin < dim (garantida pelos limites last_* do dma_ctrl).
module dma_tile_span #(
    parameter ARRAY_SIZE = 4,
    // derivado, nao sobrescrever
    parameter CW = $clog2(ARRAY_SIZE + 1)
)(
    input  wire [15:0]   dim,
    input  wire [15:0]   origin,
    output wire [CW-1:0] span
);

    localparam [15:0] T16 = ARRAY_SIZE;

    wire [15:0] remaining = dim - origin;

    assign span = (remaining > T16) ? T16[CW-1:0] : remaining[CW-1:0];

endmodule

`default_nettype wire
