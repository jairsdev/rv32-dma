`timescale 1ns/1ps
`default_nettype none

// Controlador DMA - top-level (ESQUELETO).
// Especificacao: docs/dma_mas.md (MAS v1.1), secoes 5.1 (parametros) e 5.2 (portas).
// Este arquivo so fixa a interface. A logica entra no passo 7 do plano de construcao
// (MAS secao 17): dma_regs, dma_ctrl, dma_load, dma_compute, dma_store,
// dma_rd_engine, dma_wr_engine e dma_bank_ctrl. Ate la todas as saidas ficam em 0.
module dma #(
    parameter ARRAY_SIZE = 4,   // T: 2, 4 ou 8 (igual ao do acelerador)
    parameter PINGPONG   = 1,   // 1 = 2 bancos de A/B + banco C; 0 = operacao serial
    parameter MAX_BURST  = 16,  // maior burst emitido (1 ... 16)
    parameter ADDR_W     = 32,
    parameter DATA_W     = 32,
    parameter ID_W       = 1,   // ID dos masters (sempre 0)
    parameter S_ID_W     = 2    // ID no lado slave: {m_idx, id}, vem do xbar
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // Interrupcao: STATUS.DONE & CTRL.IRQ_EN (nivel)
    output wire                 irq,

    // ---------------------------------------------------------------
    // Slave S1 - registradores (AXI4, perfil MAS secao 4)
    // ---------------------------------------------------------------
    input  wire [S_ID_W-1:0]    s_awid,
    input  wire [ADDR_W-1:0]    s_awaddr,
    input  wire [7:0]           s_awlen,
    input  wire [2:0]           s_awsize,
    input  wire [1:0]           s_awburst,
    input  wire                 s_awvalid,
    output wire                 s_awready,
    input  wire [DATA_W-1:0]    s_wdata,
    input  wire [DATA_W/8-1:0]  s_wstrb,
    input  wire                 s_wlast,
    input  wire                 s_wvalid,
    output wire                 s_wready,
    output wire [S_ID_W-1:0]    s_bid,
    output wire [1:0]           s_bresp,
    output wire                 s_bvalid,
    input  wire                 s_bready,
    input  wire [S_ID_W-1:0]    s_arid,
    input  wire [ADDR_W-1:0]    s_araddr,
    input  wire [7:0]           s_arlen,
    input  wire [2:0]           s_arsize,
    input  wire [1:0]           s_arburst,
    input  wire                 s_arvalid,
    output wire                 s_arready,
    output wire [S_ID_W-1:0]    s_rid,
    output wire [DATA_W-1:0]    s_rdata,
    output wire [1:0]           s_rresp,
    output wire                 s_rlast,
    output wire                 s_rvalid,
    input  wire                 s_rready,

    // ---------------------------------------------------------------
    // Master M1 - acesso a DMEM (AXI4, perfil MAS secao 4)
    // ---------------------------------------------------------------
    output wire [ID_W-1:0]      m_awid,
    output wire [ADDR_W-1:0]    m_awaddr,
    output wire [7:0]           m_awlen,
    output wire [2:0]           m_awsize,
    output wire [1:0]           m_awburst,
    output wire                 m_awlock,
    output wire [3:0]           m_awcache,
    output wire [2:0]           m_awprot,
    output wire                 m_awvalid,
    input  wire                 m_awready,
    output wire [DATA_W-1:0]    m_wdata,
    output wire [DATA_W/8-1:0]  m_wstrb,
    output wire                 m_wlast,
    output wire                 m_wvalid,
    input  wire                 m_wready,
    input  wire [ID_W-1:0]      m_bid,
    input  wire [1:0]           m_bresp,
    input  wire                 m_bvalid,
    output wire                 m_bready,
    output wire [ID_W-1:0]      m_arid,
    output wire [ADDR_W-1:0]    m_araddr,
    output wire [7:0]           m_arlen,
    output wire [2:0]           m_arsize,
    output wire [1:0]           m_arburst,
    output wire                 m_arlock,
    output wire [3:0]           m_arcache,
    output wire [2:0]           m_arprot,
    output wire                 m_arvalid,
    input  wire                 m_arready,
    input  wire [ID_W-1:0]      m_rid,
    input  wire [DATA_W-1:0]    m_rdata,
    input  wire [1:0]           m_rresp,
    input  wire                 m_rlast,
    input  wire                 m_rvalid,
    output wire                 m_rready,

    // ---------------------------------------------------------------
    // Sideband com o acelerador (MAS secao 11)
    // ---------------------------------------------------------------
    output wire                 buf_a_we,
    output wire                 buf_b_we,
    output wire                 buf_bank,
    output wire [IW-1:0]        buf_row,
    output wire [WW-1:0]        buf_word,
    output wire [31:0]          buf_wdata,
    output wire                 tile_start,
    output wire                 tile_bank,
    output wire                 first_k,
    output wire                 last_k,
    input  wire                 busy,        // acc_busy dentro do DMA
    input  wire                 acc_active,  // 1 so no estado A_RUN (CYC_COMPUTE)
    input  wire                 tile_done,
    input  wire                 c_valid,
    output wire                 c_release,
    output wire                 c_rd,
    output wire [IW-1:0]        c_row,
    output wire [IW-1:0]        c_col,
    input  wire [31:0]          c_rdata
);

    // Larguras derivadas (MAS "Como ler este documento")
    localparam IW  = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1;
    localparam WPR = (ARRAY_SIZE + 3) / 4;
    localparam WW  = (WPR > 1) ? $clog2(WPR) : 1;

    // Saidas em repouso ate a implementacao dos submodulos
    assign irq        = 1'b0;

    assign s_awready  = 1'b0;
    assign s_wready   = 1'b0;
    assign s_bid      = {S_ID_W{1'b0}};
    assign s_bresp    = 2'b00;
    assign s_bvalid   = 1'b0;
    assign s_arready  = 1'b0;
    assign s_rid      = {S_ID_W{1'b0}};
    assign s_rdata    = {DATA_W{1'b0}};
    assign s_rresp    = 2'b00;
    assign s_rlast    = 1'b0;
    assign s_rvalid   = 1'b0;

    assign m_awid     = {ID_W{1'b0}};
    assign m_awaddr   = {ADDR_W{1'b0}};
    assign m_awlen    = 8'd0;
    assign m_awsize   = 3'b010;    // 4 bytes (fixo no perfil)
    assign m_awburst  = 2'b01;     // INCR (fixo no perfil)
    assign m_awlock   = 1'b0;
    assign m_awcache  = 4'b0000;
    assign m_awprot   = 3'b000;
    assign m_awvalid  = 1'b0;
    assign m_wdata    = {DATA_W{1'b0}};
    assign m_wstrb    = {(DATA_W/8){1'b1}};
    assign m_wlast    = 1'b0;
    assign m_wvalid   = 1'b0;
    assign m_bready   = 1'b0;
    assign m_arid     = {ID_W{1'b0}};
    assign m_araddr   = {ADDR_W{1'b0}};
    assign m_arlen    = 8'd0;
    assign m_arsize   = 3'b010;
    assign m_arburst  = 2'b01;
    assign m_arlock   = 1'b0;
    assign m_arcache  = 4'b0000;
    assign m_arprot   = 3'b000;
    assign m_arvalid  = 1'b0;
    assign m_rready   = 1'b0;

    assign buf_a_we   = 1'b0;
    assign buf_b_we   = 1'b0;
    assign buf_bank   = 1'b0;
    assign buf_row    = {IW{1'b0}};
    assign buf_word   = {WW{1'b0}};
    assign buf_wdata  = 32'd0;
    assign tile_start = 1'b0;
    assign tile_bank  = 1'b0;
    assign first_k    = 1'b0;
    assign last_k     = 1'b0;
    assign c_release  = 1'b0;
    assign c_rd       = 1'b0;
    assign c_row      = {IW{1'b0}};
    assign c_col      = {IW{1'b0}};

endmodule

`default_nettype wire
