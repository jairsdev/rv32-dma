`timescale 1ns/1ps

// Memoria de instrucoes local da CPU (README, secoes 1 e 3.1): SRAM de 64 KiB
// em 0x0000_0000, lida so pela Porta I e carregada por $readmemh.
// Responde com latencia de 1 ciclo: ready e um pulso de 1 ciclo com rdata
// valido no mesmo ciclo.
module imem #(
    parameter MEM_BYTES = 65536,
    parameter INIT_FILE = ""          // .hex com uma palavra por linha
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        i_valid,
    input  wire [31:0] i_addr,
    output reg         i_ready,
    output reg  [31:0] i_rdata
);

    localparam WORDS = MEM_BYTES / 4;
    localparam AW    = $clog2(WORDS);

    reg [31:0] mem [0:WORDS-1];

    integer k;
    initial begin
        for (k = 0; k < WORDS; k = k + 1)
            mem[k] = 32'd0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i_ready <= 1'b0;
            i_rdata <= 32'd0;
        end else begin
            // Uma resposta por requisicao: nao responde de novo no ciclo do ready
            i_ready <= i_valid && !i_ready;
            if (i_valid && !i_ready)
                i_rdata <= mem[i_addr[AW+1:2]];
        end
    end

endmodule
