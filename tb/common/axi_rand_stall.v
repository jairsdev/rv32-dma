`timescale 1ns/1ps
`default_nettype none

// Insere backpressure aleatoria entre um master e um slave AXI4 (MAS 16.1).
// Segura ARREADY, AWREADY, WREADY (lado master) e RVALID, BVALID (lado master)
// de forma aleatoria, sem violar o protocolo:
//   - cada canal tem um "pass" aleatorio por ciclo;
//   - VALID repassado = VALID de origem & pass; READY repassado = READY & pass;
//   - depois que o VALID repassado sobe sem handshake, o canal fica "travado"
//     em pass = 1 ate o handshake, entao o VALID nunca cai antes da hora.
// O payload passa direto. Com enable = 0 o modulo e transparente.
// STALL_PCT: probabilidade (0-100) de segurar um canal em um ciclo.
module axi_rand_stall #(
    parameter ID_W      = 1,
    parameter STALL_PCT = 40
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            enable,
    input  wire [31:0]     seed,

    // Lado master (conectado ao master)
    input  wire [ID_W-1:0] m_awid,
    input  wire [31:0]     m_awaddr,
    input  wire [7:0]      m_awlen,
    input  wire [2:0]      m_awsize,
    input  wire [1:0]      m_awburst,
    input  wire            m_awvalid,
    output wire            m_awready,
    input  wire [31:0]     m_wdata,
    input  wire [3:0]      m_wstrb,
    input  wire            m_wlast,
    input  wire            m_wvalid,
    output wire            m_wready,
    output wire [ID_W-1:0] m_bid,
    output wire [1:0]      m_bresp,
    output wire            m_bvalid,
    input  wire            m_bready,
    input  wire [ID_W-1:0] m_arid,
    input  wire [31:0]     m_araddr,
    input  wire [7:0]      m_arlen,
    input  wire [2:0]      m_arsize,
    input  wire [1:0]      m_arburst,
    input  wire            m_arvalid,
    output wire            m_arready,
    output wire [ID_W-1:0] m_rid,
    output wire [31:0]     m_rdata,
    output wire [1:0]      m_rresp,
    output wire            m_rlast,
    output wire            m_rvalid,
    input  wire            m_rready,

    // Lado slave (conectado ao slave)
    output wire [ID_W-1:0] s_awid,
    output wire [31:0]     s_awaddr,
    output wire [7:0]      s_awlen,
    output wire [2:0]      s_awsize,
    output wire [1:0]      s_awburst,
    output wire            s_awvalid,
    input  wire            s_awready,
    output wire [31:0]     s_wdata,
    output wire [3:0]      s_wstrb,
    output wire            s_wlast,
    output wire            s_wvalid,
    input  wire            s_wready,
    input  wire [ID_W-1:0] s_bid,
    input  wire [1:0]      s_bresp,
    input  wire            s_bvalid,
    output wire            s_bready,
    output wire [ID_W-1:0] s_arid,
    output wire [31:0]     s_araddr,
    output wire [7:0]      s_arlen,
    output wire [2:0]      s_arsize,
    output wire [1:0]      s_arburst,
    output wire            s_arvalid,
    input  wire            s_arready,
    input  wire [ID_W-1:0] s_rid,
    input  wire [31:0]     s_rdata,
    input  wire [1:0]      s_rresp,
    input  wire            s_rlast,
    input  wire            s_rvalid,
    output wire            s_rready
);

    // Indices dos canais
    localparam CH_AW = 0, CH_W = 1, CH_B = 2, CH_AR = 3, CH_R = 4;

    integer   rng;
    reg [4:0] rnd_pass;     // sorteio deste ciclo
    reg [4:0] locked_q;     // VALID repassado esperando handshake

    initial rng = 1;

    // Sorteio registrado, um bit por canal
    integer c;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rng      = (seed == 32'd0) ? 1 : seed;
            rnd_pass <= 5'b11111;
        end else begin
            for (c = 0; c < 5; c = c + 1)
                rnd_pass[c] <= (({$random(rng)} % 100) >= STALL_PCT);
        end
    end

    wire [4:0] pass = enable ? (rnd_pass | locked_q) : 5'b11111;

    // VALID repassado de cada canal (origem -> destino)
    wire fwd_awvalid = m_awvalid & pass[CH_AW];
    wire fwd_wvalid  = m_wvalid  & pass[CH_W];
    wire fwd_bvalid  = s_bvalid  & pass[CH_B];
    wire fwd_arvalid = m_arvalid & pass[CH_AR];
    wire fwd_rvalid  = s_rvalid  & pass[CH_R];

    // READY do destino, como visto no canal
    wire [4:0] fwd_valid = {fwd_rvalid, fwd_arvalid, fwd_bvalid, fwd_wvalid, fwd_awvalid};
    wire [4:0] dst_ready = {m_rready,   s_arready,   m_bready,   s_wready,   s_awready};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            locked_q <= 5'b00000;
        else
            locked_q <= fwd_valid & ~dst_ready;
    end

    // Master -> slave
    assign s_awid    = m_awid;
    assign s_awaddr  = m_awaddr;
    assign s_awlen   = m_awlen;
    assign s_awsize  = m_awsize;
    assign s_awburst = m_awburst;
    assign s_awvalid = fwd_awvalid;
    assign m_awready = s_awready & pass[CH_AW];

    assign s_wdata   = m_wdata;
    assign s_wstrb   = m_wstrb;
    assign s_wlast   = m_wlast;
    assign s_wvalid  = fwd_wvalid;
    assign m_wready  = s_wready & pass[CH_W];

    assign s_arid    = m_arid;
    assign s_araddr  = m_araddr;
    assign s_arlen   = m_arlen;
    assign s_arsize  = m_arsize;
    assign s_arburst = m_arburst;
    assign s_arvalid = fwd_arvalid;
    assign m_arready = s_arready & pass[CH_AR];

    // Slave -> master
    assign m_bid     = s_bid;
    assign m_bresp   = s_bresp;
    assign m_bvalid  = fwd_bvalid;
    assign s_bready  = m_bready & pass[CH_B];

    assign m_rid     = s_rid;
    assign m_rdata   = s_rdata;
    assign m_rresp   = s_rresp;
    assign m_rlast   = s_rlast;
    assign m_rvalid  = fwd_rvalid;
    assign s_rready  = m_rready & pass[CH_R];

endmodule

`default_nettype wire
