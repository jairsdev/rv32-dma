// axi_narrow_read_align - posiciona o dado lido na byte lane que a norma determina (R-20).
// MAS §5.6, IHI0022E §A3.4.1 e §A3.4.3. Puramente combinacional, sem estado nem clock.
//
// A SRAM sempre entrega 32 bits alinhados. Numa leitura estreita o AXI exige o dado nas lanes
//   Lower_Byte_Lane = addr[1:0]   ate   Upper_Byte_Lane = Lower_Byte_Lane + Number_Bytes - 1
// e essas lanes mudam a cada beat do burst. O endereco e o tamanho chegam junto da resposta,
// vindos do FIFO de requisicoes do axi_transaction_manager (MAS §5.4.2), sem caminho paralelo.
//
// Lanes nao usadas (D12): recebem o dado replicado, nao zeros. E decisao de projeto, nao
// exigencia da norma (P-06); trocar por zeros e alteracao de uma linha por caso.
// Transferencia de 2 bytes desalinhada (addr[0] = 1) e passagem direta (P-07).
// axsize > 3'b010 nunca chega aqui: o axi_address_decoder o rejeita antes (MAS §5.3.1).
module axi_narrow_read_align (
    input      [31:0] rdata_raw,       // dado alinhado, vindo da memoria
    input      [1:0]  addr_lo,        // addr[1:0] do beat
    input      [2:0]  axsize,         // tamanho do beat: 2^axsize bytes
    output reg [31:0] rdata_aligned   // dado posicionado na lane correta
);

    always @* begin
        rdata_aligned = rdata_raw;     // padrao: passagem direta (4 B e caso desalinhado)

        case ({axsize, addr_lo})
            // 2 bytes: meia palavra baixa ou alta, replicada
            {3'b001, 2'b00}: rdata_aligned = {rdata_raw[15:0],  rdata_raw[15:0]};
            {3'b001, 2'b10}: rdata_aligned = {rdata_raw[31:16], rdata_raw[31:16]};

            // 1 byte: o byte da lane indicada por addr[1:0], replicado
            {3'b000, 2'b00}: rdata_aligned = {4{rdata_raw[7:0]}};
            {3'b000, 2'b01}: rdata_aligned = {4{rdata_raw[15:8]}};
            {3'b000, 2'b10}: rdata_aligned = {4{rdata_raw[23:16]}};
            {3'b000, 2'b11}: rdata_aligned = {4{rdata_raw[31:24]}};

            default: rdata_aligned = rdata_raw;
        endcase
    end

endmodule
