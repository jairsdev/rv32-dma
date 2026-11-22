`timescale 1ns/1ps
`default_nettype none

// SRAM sincrona on-chip da DMEM (MAS secao 12.2), atras do frontend AXI4 copiado
// do interface_amba (rtl/third_party/interface_amba/).
// Faz o papel do sram_controller daquele projeto, que controlava uma SRAM externa
// de 16 bits, e segue o mesmo contrato ram_* (MAS_axi4_sram.md secao 3.2):
//   - single-port, MEM_WORDS x 32 bits, escrita por byte (ram_wr = WSTRB);
//   - indice = ram_addr[AW+1:2]; os bits acima nao sao olhados (o decoder ja
//     barrou o que esta fora dos 64 KiB);
//   - ram_accept = 1 sempre: aceita uma requisicao por ciclo;
//   - ram_ack um ciclo depois de cada requisicao aceita, leitura ou escrita,
//     inclusive escrita com strobe nulo (que nao grava nada);
//   - latencia fixa de 1 ciclo, entao as respostas saem na ordem dos pedidos.
// O frontend nunca pede leitura e escrita no mesmo ciclo (regra 3 do contrato),
// por isso uma porta so basta.
// Leitura registrada sem reset no dado e escrita por byte: o padrao que as
// ferramentas de sintese inferem como bloco de RAM.
module sram_controller_onchip #(
    parameter MEM_WORDS = 16384,
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire        rst_n,

    input  wire [31:0] ram_addr,
    input  wire [3:0]  ram_wr,
    input  wire        ram_wr_req,
    input  wire        ram_rd,
    input  wire [31:0] ram_write_data,
    output wire        ram_accept,
    output reg         ram_ack,
    output reg  [31:0] ram_read_data
);

    localparam AW = $clog2(MEM_WORDS);

    reg [31:0] mem [0:MEM_WORDS-1];

    wire [AW-1:0] idx = ram_addr[AW+1:2];

    assign ram_accept = 1'b1;

    integer i;
    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1)
            mem[i] = 32'd0;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // Memoria: sem reset, para a sintese inferir RAM
    always @(posedge clk) begin
        if (ram_wr_req) begin
            if (ram_wr[0]) mem[idx][7:0]   <= ram_write_data[7:0];
            if (ram_wr[1]) mem[idx][15:8]  <= ram_write_data[15:8];
            if (ram_wr[2]) mem[idx][23:16] <= ram_write_data[23:16];
            if (ram_wr[3]) mem[idx][31:24] <= ram_write_data[31:24];
        end
        if (ram_rd)
            ram_read_data <= mem[idx];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            ram_ack <= 1'b0;
        else
            ram_ack <= ram_rd | ram_wr_req;
    end

`ifdef DMA_ASSERT
    always @(posedge clk)
        if (rst_n && ram_rd && ram_wr_req)
            $error("sram_controller_onchip: leitura e escrita no mesmo ciclo");
`endif

endmodule

`default_nettype wire
