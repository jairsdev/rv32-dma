`timescale 1ns/1ps
`default_nettype none

// Slave AXI4 da DMEM (MAS secao 12.2): 64 KiB on-chip em 0x1000_0000.
//
//   AXI4 -> axi_address_decoder -> axi_transaction_manager -> sram_controller_onchip
//           (faixa e perfil)       (burst, ID, ordem, FIFOs)   (SRAM 16 K x 32, ram_*)
//   R:      axi_transaction_manager -> axi_narrow_read_align -> axi_address_decoder
//
// O frontend (decoder, transaction manager e alinhamento) foi copiado do projeto
// interface_amba (rtl/third_party/interface_amba/, origem e licenca no README de
// la); a ligacao segue o axi_interface_subordinate_sram.v daquele projeto, com a
// SRAM externa de 16 bits trocada pela SRAM on-chip.
//
// Comportamento visto de fora:
//   - addr[27:16] != 0, AxSIZE != 4 bytes ou AxBURST != INCR: completa o burst
//     com SLVERR sem acessar a memoria (ARLEN+1 beats de R / W ate WLAST e um B);
//   - addr[31:28] nao e decodificado (quem separa os slaves e o xbar);
//   - leitura: RVALID 2 ciclos depois do handshake de AR, depois 1 beat por ciclo;
//   - AR e AW alternam por transacao (round-robin do transaction manager).
//
// Portas iguais as do tb/models/axi_mem_model.v (menos w_first), para os TBs
// trocarem um pelo outro. O frontend usa ID de 4 bits; aqui o ID tem ID_W bits.
module axi_mem_ctrl #(
    parameter ID_W      = 2,
    parameter MEM_WORDS = 16384,
    parameter INIT_FILE = ""
)(
    input  wire            clk,
    input  wire            rst_n,

    input  wire [ID_W-1:0] awid,
    input  wire [31:0]     awaddr,
    input  wire [7:0]      awlen,
    input  wire [2:0]      awsize,
    input  wire [1:0]      awburst,
    input  wire            awvalid,
    output wire            awready,
    input  wire [31:0]     wdata,
    input  wire [3:0]      wstrb,
    input  wire            wlast,
    input  wire            wvalid,
    output wire            wready,
    output wire [ID_W-1:0] bid,
    output wire [1:0]      bresp,
    output wire            bvalid,
    input  wire            bready,
    input  wire [ID_W-1:0] arid,
    input  wire [31:0]     araddr,
    input  wire [7:0]      arlen,
    input  wire [2:0]      arsize,
    input  wire [1:0]      arburst,
    input  wire            arvalid,
    output wire            arready,
    output wire [ID_W-1:0] rid,
    output wire [31:0]     rdata,
    output wire [1:0]      rresp,
    output wire            rlast,
    output wire            rvalid,
    input  wire            rready
);

    // IDs: o frontend tem 4 bits; os bits de cima entram em 0 e sao descartados na volta
    wire [3:0] awid4 = {{(4-ID_W){1'b0}}, awid};
    wire [3:0] arid4 = {{(4-ID_W){1'b0}}, arid};
    wire [3:0] bid4, rid4;
    assign bid = bid4[ID_W-1:0];
    assign rid = rid4[ID_W-1:0];

    // decoder -> transaction manager
    wire [3:0]  m_awid, m_arid, m_bid, m_rid;
    wire [31:0] m_awaddr, m_araddr, m_wdata, m_rdata_raw, m_rdata;
    wire [7:0]  m_awlen, m_arlen;
    wire [2:0]  m_awsize, m_arsize;
    wire [1:0]  m_awburst, m_arburst, m_bresp, m_rresp;
    wire [3:0]  m_wstrb;
    wire        m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
    wire        m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;

    axi_address_decoder u_decoder (
        .aclk(clk), .aresetn(rst_n),
        .s_axi_awid(awid4), .s_axi_awaddr(awaddr), .s_axi_awlen(awlen),
        .s_axi_awsize(awsize), .s_axi_awburst(awburst),
        .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wlast(wlast),
        .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bid(bid4), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_arid(arid4), .s_axi_araddr(araddr), .s_axi_arlen(arlen),
        .s_axi_arsize(arsize), .s_axi_arburst(arburst),
        .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rid(rid4), .s_axi_rdata(rdata), .s_axi_rresp(rresp),
        .s_axi_rlast(rlast), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .m_axi_awid(m_awid), .m_axi_awaddr(m_awaddr), .m_axi_awlen(m_awlen),
        .m_axi_awsize(m_awsize), .m_axi_awburst(m_awburst),
        .m_axi_awvalid(m_awvalid), .m_axi_awready(m_awready),
        .m_axi_wdata(m_wdata), .m_axi_wstrb(m_wstrb), .m_axi_wlast(m_wlast),
        .m_axi_wvalid(m_wvalid), .m_axi_wready(m_wready),
        .m_axi_bid(m_bid), .m_axi_bresp(m_bresp), .m_axi_bvalid(m_bvalid), .m_axi_bready(m_bready),
        .m_axi_arid(m_arid), .m_axi_araddr(m_araddr), .m_axi_arlen(m_arlen),
        .m_axi_arsize(m_arsize), .m_axi_arburst(m_arburst),
        .m_axi_arvalid(m_arvalid), .m_axi_arready(m_arready),
        .m_axi_rid(m_rid), .m_axi_rdata(m_rdata), .m_axi_rresp(m_rresp), .m_axi_rlast(m_rlast),
        .m_axi_rvalid(m_rvalid), .m_axi_rready(m_rready)
    );

    // transaction manager -> SRAM (contrato ram_*)
    wire [31:0] ram_addr, ram_write_data, ram_read_data;
    wire [3:0]  ram_wr;
    wire [7:0]  ram_len;
    wire [2:0]  ram_size;
    wire        ram_wr_req, ram_rd, ram_accept, ram_ack;
    wire [1:0]  resp_addr_lo;
    wire [2:0]  resp_size;

    // o transaction manager (IP Ultra-Embedded) usa reset ativo em 1
    axi_transaction_manager u_manager (
        .clk_i(clk), .rst_i(~rst_n),
        .axi_awvalid_i(m_awvalid), .axi_awaddr_i(m_awaddr), .axi_awid_i(m_awid),
        .axi_awlen_i(m_awlen), .axi_awburst_i(m_awburst), .axi_awsize_i(m_awsize),
        .axi_wvalid_i(m_wvalid), .axi_wdata_i(m_wdata), .axi_wstrb_i(m_wstrb), .axi_wlast_i(m_wlast),
        .axi_bready_i(m_bready),
        .axi_arvalid_i(m_arvalid), .axi_araddr_i(m_araddr), .axi_arid_i(m_arid),
        .axi_arlen_i(m_arlen), .axi_arburst_i(m_arburst), .axi_arsize_i(m_arsize),
        .axi_rready_i(m_rready),
        .ram_accept_i(ram_accept), .ram_ack_i(ram_ack), .ram_error_i(1'b0),
        .ram_read_data_i(ram_read_data),
        .axi_awready_o(m_awready), .axi_wready_o(m_wready),
        .axi_bvalid_o(m_bvalid), .axi_bresp_o(m_bresp), .axi_bid_o(m_bid),
        .axi_arready_o(m_arready),
        .axi_rvalid_o(m_rvalid), .axi_rdata_o(m_rdata_raw), .axi_rresp_o(m_rresp),
        .axi_rid_o(m_rid), .axi_rlast_o(m_rlast),
        .ram_wr_o(ram_wr), .ram_rd_o(ram_rd), .ram_len_o(ram_len),
        .ram_addr_o(ram_addr), .ram_write_data_o(ram_write_data),
        .ram_size_o(ram_size), .ram_wr_req_o(ram_wr_req),
        .resp_addr_lo_o(resp_addr_lo), .resp_size_o(resp_size)
    );

    // com AxSIZE fixo em 4 bytes e uma passagem direta; fica para o frontend ser o original
    axi_narrow_read_align u_align (
        .rdata_raw(m_rdata_raw), .addr_lo(resp_addr_lo), .axsize(resp_size),
        .rdata_aligned(m_rdata)
    );

    sram_controller_onchip #(
        .MEM_WORDS (MEM_WORDS),
        .INIT_FILE (INIT_FILE)
    ) u_ram (
        .clk            (clk),
        .rst_n          (rst_n),
        .ram_addr       ({ram_addr[31:2], 2'b00}),
        .ram_wr         (ram_wr),
        .ram_wr_req     (ram_wr_req),
        .ram_rd         (ram_rd),
        .ram_write_data (ram_write_data),
        .ram_accept     (ram_accept),
        .ram_ack        (ram_ack),
        .ram_read_data  (ram_read_data)
    );

endmodule

`default_nettype wire
