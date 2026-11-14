`timescale 1ns/1ps
`default_nettype none
`include "axi_defs.vh"

// Controlador DMA - top-level (MAS v1.1, secoes 5.1 a 5.4).
//
// Este arquivo so instancia e liga os submodulos:
//
//   dma_regs       slave AXI4 S1: registradores, contadores, irq
//   dma_ctrl       FSM principal: CHECK, RUN, DRAIN, ERROR, DONE
//   dma_bank_ctrl  estado dos bancos de A/B e ponteiros ld_ptr/cp_ptr
//   dma_load       produtor de blocos  -> dma_rd_engine (AR/R)  -> buffers
//   dma_compute    disparo dos tiles   -> acelerador
//   dma_store      gravacao de C       -> dma_wr_engine (AW/W/B) <- banco C
//   dma_assert     assercoes H1-H6 (so com `define DMA_ASSERT)
//
// O dma_rd_engine e o unico que escreve nos buffers e o dma_wr_engine o
// unico que le C, entao nao ha mux de porta.
module dma #(
    parameter ARRAY_SIZE = 4,   // T: 2, 4 ou 8 (igual ao do acelerador)
    parameter PINGPONG   = 1,   // 1 = 2 bancos de A/B + banco C; 0 = operacao serial
    parameter MAX_BURST  = 16,  // maior burst emitido (1 ... 16)
    parameter ADDR_W     = 32,
    parameter DATA_W     = 32,
    parameter ID_W       = 1,   // ID dos masters (sempre 0)
    parameter S_ID_W     = 2,   // ID no lado slave: {m_idx, id}, vem do xbar
    // derivados, nao sobrescrever (MAS "Como ler este documento")
    parameter IW  = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1,
    parameter WPR = (ARRAY_SIZE + 3) / 4,
    parameter WW  = (WPR > 1) ? $clog2(WPR) : 1
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

    localparam CW = $clog2(ARRAY_SIZE + 1);   // largura de 0 ... T

    // m_bid e m_rid: com 1 transacao por direcao e ID fixo as respostas
    // chegam em ordem (MAS 4.3 regra 5); nao precisam ser conferidos.

    // =================================================================
    // Fios internos
    // =================================================================
    wire        acc_busy = busy;

    // dma_regs <-> dma_ctrl
    wire        start, soft_reset;
    wire [31:0] addr_a, addr_b, addr_c;
    wire [15:0] dim_m, dim_n, dim_k;
    wire        ctrl_busy, ctrl_done, ctrl_error;
    wire [3:0]  ctrl_err_code;

    // dma_ctrl -> FSMs
    wire        run, stop, bank_clr;
    wire [17:0] stride_a, stride_b, stride_c;
    wire [15:0] last_i0, last_j0, last_k0;

    // Fim das FSMs
    wire        load_end, compute_end, store_end, store_active;

    // dma_bank_ctrl
    wire        ld_ptr, ld_bank_empty, ld_claim, ld_full;
    wire        ld_first_k, ld_last_k, ld_last_blk;
    wire        cp_ptr, cp_bank_full, cp_first_k, cp_last_k, cp_last_blk;
    wire        cp_start, cp_free;
    wire [3:0]  bank_state_flat;

    // dma_load <-> dma_rd_engine
    wire          rd_cmd_valid, rd_cmd_ready;
    wire [31:0]   rd_cmd_addr;
    wire [CW-1:0] rd_cmd_nbytes;
    wire          rd_cmd_sel, rd_cmd_bank;
    wire [IW-1:0] rd_cmd_row;
    wire          rd_done, rd_idle, rd_err;

    // dma_store <-> dma_wr_engine
    wire          wr_cmd_valid, wr_cmd_ready;
    wire [31:0]   wr_cmd_addr;
    wire [CW-1:0] wr_cmd_nwords;
    wire [IW-1:0] wr_cmd_row;
    wire          wr_done, wr_idle, wr_err;

    // Handshakes de comando (usados pelas assercoes)
    wire          rd_cmd_hs = rd_cmd_valid & rd_cmd_ready;
    wire          wr_cmd_hs = wr_cmd_valid & wr_cmd_ready;

    // =================================================================
    // Banco de registradores
    // =================================================================
    dma_regs #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .PINGPONG   (PINGPONG),
        .ADDR_W     (ADDR_W),
        .DATA_W     (DATA_W),
        .S_ID_W     (S_ID_W)
    ) u_regs (
        .clk           (clk),
        .rst_n         (rst_n),
        .s_awid        (s_awid),
        .s_awaddr      (s_awaddr),
        .s_awlen       (s_awlen),
        .s_awsize      (s_awsize),
        .s_awburst     (s_awburst),
        .s_awvalid     (s_awvalid),
        .s_awready     (s_awready),
        .s_wdata       (s_wdata),
        .s_wstrb       (s_wstrb),
        .s_wlast       (s_wlast),
        .s_wvalid      (s_wvalid),
        .s_wready      (s_wready),
        .s_bid         (s_bid),
        .s_bresp       (s_bresp),
        .s_bvalid      (s_bvalid),
        .s_bready      (s_bready),
        .s_arid        (s_arid),
        .s_araddr      (s_araddr),
        .s_arlen       (s_arlen),
        .s_arsize      (s_arsize),
        .s_arburst     (s_arburst),
        .s_arvalid     (s_arvalid),
        .s_arready     (s_arready),
        .s_rid         (s_rid),
        .s_rdata       (s_rdata),
        .s_rresp       (s_rresp),
        .s_rlast       (s_rlast),
        .s_rvalid      (s_rvalid),
        .s_rready      (s_rready),
        .start         (start),
        .soft_reset    (soft_reset),
        .addr_a        (addr_a),
        .addr_b        (addr_b),
        .addr_c        (addr_c),
        .dim_m         (dim_m),
        .dim_n         (dim_n),
        .dim_k         (dim_k),
        .ctrl_busy     (ctrl_busy),
        .ctrl_done     (ctrl_done),
        .ctrl_error    (ctrl_error),
        .ctrl_err_code (ctrl_err_code),
        .acc_active    (acc_active),
        .irq           (irq)
    );

    // =================================================================
    // FSM principal
    // =================================================================
    dma_ctrl #(
        .ARRAY_SIZE (ARRAY_SIZE)
    ) u_ctrl (
        .clk         (clk),
        .rst_n       (rst_n),
        .start       (start),
        .soft_reset  (soft_reset),
        .addr_a      (addr_a),
        .addr_b      (addr_b),
        .addr_c      (addr_c),
        .dim_m       (dim_m),
        .dim_n       (dim_n),
        .dim_k       (dim_k),
        .load_end    (load_end),
        .compute_end (compute_end),
        .store_end   (store_end),
        .rd_idle     (rd_idle),
        .wr_idle     (wr_idle),
        .rd_err      (rd_err),
        .wr_err      (wr_err),
        .acc_busy    (acc_busy),
        .c_valid     (c_valid),
        .ctrl_busy   (ctrl_busy),
        .run         (run),
        .stop        (stop),
        .bank_clr    (bank_clr),
        .done        (ctrl_done),
        .error       (ctrl_error),
        .err_code    (ctrl_err_code),
        .stride_a    (stride_a),
        .stride_b    (stride_b),
        .stride_c    (stride_c),
        .last_i0     (last_i0),
        .last_j0     (last_j0),
        .last_k0     (last_k0)
    );

    // =================================================================
    // Estado dos bancos
    // =================================================================
    dma_bank_ctrl #(
        .PINGPONG (PINGPONG)
    ) u_bank_ctrl (
        .clk             (clk),
        .rst_n           (rst_n),
        .bank_clr        (bank_clr),
        .ld_claim        (ld_claim),
        .ld_full         (ld_full),
        .ld_first_k      (ld_first_k),
        .ld_last_k       (ld_last_k),
        .ld_last_blk     (ld_last_blk),
        .cp_start        (cp_start),
        .cp_free         (cp_free),
        .ld_ptr          (ld_ptr),
        .ld_bank_empty   (ld_bank_empty),
        .cp_ptr          (cp_ptr),
        .cp_bank_full    (cp_bank_full),
        .cp_first_k      (cp_first_k),
        .cp_last_k       (cp_last_k),
        .cp_last_blk     (cp_last_blk),
        .bank_state_flat (bank_state_flat)
    );

    // =================================================================
    // Produtor de blocos
    // =================================================================
    dma_load #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .PINGPONG   (PINGPONG)
    ) u_load (
        .clk           (clk),
        .rst_n         (rst_n),
        .run           (run),
        .stop          (stop),
        .addr_a        (addr_a),
        .addr_b        (addr_b),
        .dim_m         (dim_m),
        .dim_n         (dim_n),
        .dim_k         (dim_k),
        .stride_a      (stride_a),
        .stride_b      (stride_b),
        .last_i0       (last_i0),
        .last_j0       (last_j0),
        .last_k0       (last_k0),
        .load_end      (load_end),
        .ld_ptr        (ld_ptr),
        .ld_bank_empty (ld_bank_empty),
        .ld_claim      (ld_claim),
        .ld_full       (ld_full),
        .ld_first_k    (ld_first_k),
        .ld_last_k     (ld_last_k),
        .ld_last_blk   (ld_last_blk),
        .c_valid       (c_valid),
        .store_active  (store_active),
        .rd_cmd_valid  (rd_cmd_valid),
        .rd_cmd_ready  (rd_cmd_ready),
        .rd_cmd_addr   (rd_cmd_addr),
        .rd_cmd_nbytes (rd_cmd_nbytes),
        .rd_cmd_sel    (rd_cmd_sel),
        .rd_cmd_bank   (rd_cmd_bank),
        .rd_cmd_row    (rd_cmd_row),
        .rd_done       (rd_done),
        .rd_idle       (rd_idle)
    );

    // =================================================================
    // Disparo dos tiles
    // =================================================================
    dma_compute u_compute (
        .clk          (clk),
        .rst_n        (rst_n),
        .run          (run),
        .stop         (stop),
        .compute_end  (compute_end),
        .cp_ptr       (cp_ptr),
        .cp_bank_full (cp_bank_full),
        .cp_first_k   (cp_first_k),
        .cp_last_k    (cp_last_k),
        .cp_last_blk  (cp_last_blk),
        .cp_start     (cp_start),
        .cp_free      (cp_free),
        .acc_busy     (acc_busy),
        .tile_done    (tile_done),
        .tile_start   (tile_start),
        .tile_bank    (tile_bank),
        .first_k      (first_k),
        .last_k       (last_k)
    );

    // =================================================================
    // Gravacao de C
    // =================================================================
    dma_store #(
        .ARRAY_SIZE (ARRAY_SIZE)
    ) u_store (
        .clk           (clk),
        .rst_n         (rst_n),
        .run           (run),
        .stop          (stop),
        .addr_c        (addr_c),
        .dim_m         (dim_m),
        .dim_n         (dim_n),
        .stride_c      (stride_c),
        .last_i0       (last_i0),
        .last_j0       (last_j0),
        .store_end     (store_end),
        .store_active  (store_active),
        .compute_end   (compute_end),
        .c_valid       (c_valid),
        .c_release     (c_release),
        .wr_cmd_valid  (wr_cmd_valid),
        .wr_cmd_ready  (wr_cmd_ready),
        .wr_cmd_addr   (wr_cmd_addr),
        .wr_cmd_nwords (wr_cmd_nwords),
        .wr_cmd_row    (wr_cmd_row),
        .wr_done       (wr_done)
    );

    // =================================================================
    // Motor de leitura (AR/R -> buffers)
    // =================================================================
    dma_rd_engine #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .MAX_BURST  (MAX_BURST)
    ) u_rd_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        .rd_cmd_valid  (rd_cmd_valid),
        .rd_cmd_ready  (rd_cmd_ready),
        .rd_cmd_addr   (rd_cmd_addr),
        .rd_cmd_nbytes (rd_cmd_nbytes),
        .rd_cmd_sel    (rd_cmd_sel),
        .rd_cmd_bank   (rd_cmd_bank),
        .rd_cmd_row    (rd_cmd_row),
        .rd_done       (rd_done),
        .rd_idle       (rd_idle),
        .rd_err        (rd_err),
        .err_clr       (bank_clr),
        .m_araddr      (m_araddr),
        .m_arlen       (m_arlen),
        .m_arvalid     (m_arvalid),
        .m_arready     (m_arready),
        .m_rdata       (m_rdata),
        .m_rresp       (m_rresp),
        .m_rlast       (m_rlast),
        .m_rvalid      (m_rvalid),
        .m_rready      (m_rready),
        .buf_a_we      (buf_a_we),
        .buf_b_we      (buf_b_we),
        .buf_bank      (buf_bank),
        .buf_row       (buf_row),
        .buf_word      (buf_word),
        .buf_wdata     (buf_wdata)
    );

    // =================================================================
    // Motor de escrita (banco C -> AW/W/B)
    // =================================================================
    dma_wr_engine #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .MAX_BURST  (MAX_BURST)
    ) u_wr_engine (
        .clk           (clk),
        .rst_n         (rst_n),
        .wr_cmd_valid  (wr_cmd_valid),
        .wr_cmd_ready  (wr_cmd_ready),
        .wr_cmd_addr   (wr_cmd_addr),
        .wr_cmd_nwords (wr_cmd_nwords),
        .wr_cmd_row    (wr_cmd_row),
        .wr_done       (wr_done),
        .wr_idle       (wr_idle),
        .wr_err        (wr_err),
        .err_clr       (bank_clr),
        .m_awaddr      (m_awaddr),
        .m_awlen       (m_awlen),
        .m_awvalid     (m_awvalid),
        .m_awready     (m_awready),
        .m_wdata       (m_wdata),
        .m_wstrb       (m_wstrb),
        .m_wlast       (m_wlast),
        .m_wvalid      (m_wvalid),
        .m_wready      (m_wready),
        .m_bresp       (m_bresp),
        .m_bvalid      (m_bvalid),
        .m_bready      (m_bready),
        .c_rd          (c_rd),
        .c_row         (c_row),
        .c_col         (c_col),
        .c_rdata       (c_rdata)
    );

    // =================================================================
    // Campos fixos do perfil AXI4 (MAS 4.2)
    // =================================================================
    assign m_arid    = {ID_W{1'b0}};
    assign m_arsize  = `AXI_SIZE_4B;
    assign m_arburst = `AXI_BURST_INCR;
    assign m_arlock  = 1'b0;
    assign m_arcache = 4'b0000;
    assign m_arprot  = 3'b000;

    assign m_awid    = {ID_W{1'b0}};
    assign m_awsize  = `AXI_SIZE_4B;
    assign m_awburst = `AXI_BURST_INCR;
    assign m_awlock  = 1'b0;
    assign m_awcache = 4'b0000;
    assign m_awprot  = 3'b000;

    // =================================================================
    // Assercoes H1-H6
    // =================================================================
`ifdef DMA_ASSERT
    dma_assert #(
        .PINGPONG (PINGPONG)
    ) u_assert (
        .clk             (clk),
        .rst_n           (rst_n),
        .bank_state_flat (bank_state_flat),
        .ld_ptr          (ld_ptr),
        .ld_claim        (ld_claim),
        .ld_first_k      (ld_first_k),
        .cp_ptr          (cp_ptr),
        .buf_a_we        (buf_a_we),
        .buf_b_we        (buf_b_we),
        .buf_bank        (buf_bank),
        .tile_start      (tile_start),
        .acc_busy        (acc_busy),
        .c_valid         (c_valid),
        .c_rd            (c_rd),
        .c_release       (c_release),
        .store_active    (store_active),
        .ctrl_busy       (ctrl_busy),
        .rd_cmd_hs       (rd_cmd_hs),
        .wr_cmd_hs       (wr_cmd_hs),
        .m_arvalid       (m_arvalid),
        .m_awvalid       (m_awvalid),
        .m_wvalid        (m_wvalid)
    );
`endif


endmodule

`default_nettype wire
