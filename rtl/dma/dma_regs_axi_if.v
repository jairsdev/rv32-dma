`timescale 1ns/1ps
`default_nettype none
`include "axi_defs.vh"

// Slave AXI4 S1 do banco de registradores (MAS secao 6.2).
// Converte o protocolo AXI4 em um barramento interno simples:
//   escrita: pulso reg_wr_en com endereco/dado/strobe;
//   leitura: reg_rd_addr -> reg_rd_data (combinacional, vem do dma_regs).
// Pedidos fora do perfil (AxLEN > 0 ou AxSIZE != 4 bytes) completam todos os
// beats com SLVERR, sem efeito nos registradores.
// Duas FSMs independentes: escrita (WS_*) e leitura (RS_*).
module dma_regs_axi_if #(
    parameter ADDR_W = 32,
    parameter DATA_W = 32,
    parameter S_ID_W = 2
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // AXI4 slave
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

    // Barramento interno
    output wire                 reg_wr_en,
    output wire [9:0]           reg_wr_addr,   // offset / 4
    output wire [DATA_W-1:0]    reg_wr_data,
    output wire [DATA_W/8-1:0]  reg_wr_strb,
    output wire [9:0]           reg_rd_addr,   // offset / 4
    input  wire [DATA_W-1:0]    reg_rd_data
);

    // s_awburst/s_arburst nao mudam a resposta: com AxLEN = 0 o tipo de burst
    // e irrelevante (MAS 6.2 so trata AxLEN e AxSIZE).

    // =================================================================
    // FSM de escrita: WS_IDLE -> WS_DATA -> WS_RESP -> WS_IDLE
    // =================================================================
    localparam [1:0] WS_IDLE = 2'd0,
                     WS_DATA = 2'd1,
                     WS_RESP = 2'd2;

    reg [1:0]        ws_state_q, ws_state_d;
    reg [S_ID_W-1:0] awid_q;
    reg [9:0]        awaddr_q;
    reg              wr_bad_q;
    reg [1:0]        bresp_q;

    wire aw_hs     = s_awvalid & s_awready;
    wire w_hs      = s_wvalid  & s_wready;
    wire b_hs      = s_bvalid  & s_bready;
    wire aw_is_bad = (s_awlen != 8'd0) | (s_awsize != `AXI_SIZE_4B);

    // Proximo estado
    always @(*) begin
        ws_state_d = ws_state_q;
        case (ws_state_q)
            WS_IDLE: if (aw_hs)            ws_state_d = WS_DATA;
            WS_DATA: if (w_hs && s_wlast)  ws_state_d = WS_RESP;
            WS_RESP: if (b_hs)             ws_state_d = WS_IDLE;
            default:                       ws_state_d = WS_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) ws_state_q <= WS_IDLE;
        else        ws_state_q <= ws_state_d;
    end

    // Datapath da escrita
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            awid_q   <= {S_ID_W{1'b0}};
            awaddr_q <= 10'd0;
            wr_bad_q <= 1'b0;
            bresp_q  <= `AXI_RESP_OKAY;
        end else begin
            if (aw_hs) begin
                awid_q   <= s_awid;
                awaddr_q <= s_awaddr[11:2];
                wr_bad_q <= aw_is_bad;
            end
            if (w_hs && s_wlast)
                bresp_q <= wr_bad_q ? `AXI_RESP_SLVERR : `AXI_RESP_OKAY;
        end
    end

    // READY decodificados do estado; BVALID e payload de B vem de flops
    assign s_awready = (ws_state_q == WS_IDLE);
    assign s_wready  = (ws_state_q == WS_DATA);
    assign s_bvalid  = (ws_state_q == WS_RESP);
    assign s_bid     = awid_q;
    assign s_bresp   = bresp_q;

    // Barramento interno: so beats de pedidos validos escrevem
    assign reg_wr_en   = w_hs & ~wr_bad_q;
    assign reg_wr_addr = awaddr_q;
    assign reg_wr_data = s_wdata;
    assign reg_wr_strb = s_wstrb;

    // =================================================================
    // FSM de leitura: RS_IDLE -> RS_DATA -> RS_IDLE
    // =================================================================
    localparam RS_IDLE = 1'b0,
               RS_DATA = 1'b1;

    reg              rs_state_q, rs_state_d;
    reg [S_ID_W-1:0] rid_q;
    reg [DATA_W-1:0] rdata_q;
    reg [1:0]        rresp_q;
    reg              rlast_q;
    reg [7:0]        rd_cnt_q;      // beats que faltam depois do atual

    wire ar_hs     = s_arvalid & s_arready;
    wire r_hs      = s_rvalid  & s_rready;
    wire ar_is_bad = (s_arlen != 8'd0) | (s_arsize != `AXI_SIZE_4B);

    always @(*) begin
        rs_state_d = rs_state_q;
        case (rs_state_q)
            RS_IDLE: if (ar_hs)                         rs_state_d = RS_DATA;
            RS_DATA: if (r_hs && (rd_cnt_q == 8'd0))    rs_state_d = RS_IDLE;
            default:                                    rs_state_d = RS_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) rs_state_q <= RS_IDLE;
        else        rs_state_q <= rs_state_d;
    end

    // Datapath da leitura: o registrador e amostrado no handshake de AR
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rid_q    <= {S_ID_W{1'b0}};
            rdata_q  <= {DATA_W{1'b0}};
            rresp_q  <= `AXI_RESP_OKAY;
            rlast_q  <= 1'b0;
            rd_cnt_q <= 8'd0;
        end else if (ar_hs) begin
            rid_q    <= s_arid;
            rdata_q  <= ar_is_bad ? {DATA_W{1'b0}} : reg_rd_data;
            rresp_q  <= ar_is_bad ? `AXI_RESP_SLVERR : `AXI_RESP_OKAY;
            rlast_q  <= (s_arlen == 8'd0);
            rd_cnt_q <= s_arlen;
        end else if (r_hs && (rd_cnt_q != 8'd0)) begin
            rd_cnt_q <= rd_cnt_q - 8'd1;
            rlast_q  <= (rd_cnt_q == 8'd1);
        end
    end

    assign s_arready   = (rs_state_q == RS_IDLE);
    assign s_rvalid    = (rs_state_q == RS_DATA);
    assign s_rid       = rid_q;
    assign s_rdata     = rdata_q;
    assign s_rresp     = rresp_q;
    assign s_rlast     = rlast_q;
    assign reg_rd_addr = s_araddr[11:2];

endmodule

`default_nettype wire
