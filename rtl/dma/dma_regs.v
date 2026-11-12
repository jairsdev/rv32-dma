`timescale 1ns/1ps
`default_nettype none

// Banco de registradores do DMA (MAS secao 6).
//
// Mapa (offset em bytes):
//   0x00 CTRL        [0] START (W, le 0) [1] IRQ_EN [2] SOFT_RESET (W, le 0)
//   0x04 STATUS      [0] BUSY (RO) [1] DONE (W1C) [2] ERROR (W1C) [7:4] ERR_CODE (RO)
//   0x08 ADDR_A      0x0C ADDR_B      0x10 ADDR_C   (32 bits, inclusive [1:0])
//   0x14 DIM_M       0x18 DIM_N       0x1C DIM_K    ([15:0])
//   0x20 CYCLES      ciclos com ctrl_busy desde o START (RO)
//   0x24 INFO        [7:0] T, [15:8] 8, [23:16] 32, [27:24] versao 2, [28] PINGPONG
//   0x28 CYC_COMPUTE ciclos com acc_active desde o START (RO)
//
// Regras (MAS 6.1):
//   - com o DMA ocupado, ADDR_*, DIM_* e START sao ignorados;
//   - START e SOFT_RESET na mesma escrita: vale o SOFT_RESET;
//   - o set de DONE/ERROR pelo hardware vence um W1C no mesmo ciclo;
//   - offset nao mapeado le 0 e ignora escrita.
module dma_regs #(
    parameter ARRAY_SIZE = 4,
    parameter PINGPONG   = 1,
    parameter ADDR_W     = 32,
    parameter DATA_W     = 32,
    parameter S_ID_W     = 2
)(
    input  wire                 clk,
    input  wire                 rst_n,

    // AXI4 slave S1
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

    // Para o dma_ctrl
    output wire                 start,        // pulso
    output wire                 soft_reset,   // pulso
    output wire [31:0]          addr_a,
    output wire [31:0]          addr_b,
    output wire [31:0]          addr_c,
    output wire [15:0]          dim_m,
    output wire [15:0]          dim_n,
    output wire [15:0]          dim_k,

    // Do dma_ctrl e do acelerador
    input  wire                 ctrl_busy,
    input  wire                 ctrl_done,     // pulso
    input  wire                 ctrl_error,    // pulso
    input  wire [3:0]           ctrl_err_code,
    input  wire                 acc_active,

    output wire                 irq
);

    // Offsets / 4
    localparam [9:0] REG_CTRL        = 10'h000,
                     REG_STATUS      = 10'h001,
                     REG_ADDR_A      = 10'h002,
                     REG_ADDR_B      = 10'h003,
                     REG_ADDR_C      = 10'h004,
                     REG_DIM_M       = 10'h005,
                     REG_DIM_N       = 10'h006,
                     REG_DIM_K       = 10'h007,
                     REG_CYCLES      = 10'h008,
                     REG_INFO        = 10'h009,
                     REG_CYC_COMPUTE = 10'h00A;

    localparam [3:0] VERSION = 4'd2;

    // -----------------------------------------------------------------
    // Interface AXI4 -> barramento interno
    // -----------------------------------------------------------------
    wire              reg_wr_en;
    wire [9:0]        reg_wr_addr;
    wire [DATA_W-1:0] reg_wr_data;
    wire [3:0]        reg_wr_strb;
    wire [9:0]        reg_rd_addr;
    reg  [DATA_W-1:0] reg_rd_data;

    dma_regs_axi_if #(
        .ADDR_W (ADDR_W),
        .DATA_W (DATA_W),
        .S_ID_W (S_ID_W)
    ) u_axi_if (
        .clk         (clk),
        .rst_n       (rst_n),
        .s_awid      (s_awid),
        .s_awaddr    (s_awaddr),
        .s_awlen     (s_awlen),
        .s_awsize    (s_awsize),
        .s_awburst   (s_awburst),
        .s_awvalid   (s_awvalid),
        .s_awready   (s_awready),
        .s_wdata     (s_wdata),
        .s_wstrb     (s_wstrb),
        .s_wlast     (s_wlast),
        .s_wvalid    (s_wvalid),
        .s_wready    (s_wready),
        .s_bid       (s_bid),
        .s_bresp     (s_bresp),
        .s_bvalid    (s_bvalid),
        .s_bready    (s_bready),
        .s_arid      (s_arid),
        .s_araddr    (s_araddr),
        .s_arlen     (s_arlen),
        .s_arsize    (s_arsize),
        .s_arburst   (s_arburst),
        .s_arvalid   (s_arvalid),
        .s_arready   (s_arready),
        .s_rid       (s_rid),
        .s_rdata     (s_rdata),
        .s_rresp     (s_rresp),
        .s_rlast     (s_rlast),
        .s_rvalid    (s_rvalid),
        .s_rready    (s_rready),
        .reg_wr_en   (reg_wr_en),
        .reg_wr_addr (reg_wr_addr),
        .reg_wr_data (reg_wr_data),
        .reg_wr_strb (reg_wr_strb),
        .reg_rd_addr (reg_rd_addr),
        .reg_rd_data (reg_rd_data)
    );

    // -----------------------------------------------------------------
    // Registradores
    // -----------------------------------------------------------------
    reg        irq_en_q;
    reg        done_q;
    reg        error_q;
    reg [3:0]  err_code_q;
    reg [31:0] addr_a_q, addr_b_q, addr_c_q;
    reg [15:0] dim_m_q, dim_n_q, dim_k_q;
    reg [31:0] cycles_q;
    reg [31:0] cyc_compute_q;
    reg        start_q;
    reg        soft_reset_q;

    // start_q cobre o ciclo entre o pulso de start e a subida de ctrl_busy
    wire locked = ctrl_busy | start_q;

    // Decodificacao de escrita
    wire wr_ctrl   = reg_wr_en & (reg_wr_addr == REG_CTRL)   & reg_wr_strb[0];
    wire wr_status = reg_wr_en & (reg_wr_addr == REG_STATUS) & reg_wr_strb[0];
    wire wr_cfg    = reg_wr_en & ~locked;

    wire soft_reset_w = wr_ctrl & reg_wr_data[2];
    wire start_w      = wr_ctrl & reg_wr_data[0] & ~reg_wr_data[2] & ~locked;

    // Escrita de 32 bits respeitando WSTRB
    function [31:0] apply_strb;
        input [31:0] old_val;
        input [31:0] new_val;
        input [3:0]  strb;
        integer b;
        begin
            for (b = 0; b < 4; b = b + 1)
                apply_strb[8*b +: 8] = strb[b] ? new_val[8*b +: 8] : old_val[8*b +: 8];
        end
    endfunction

    // Valor novo de cada DIM_* (32 bits com WSTRB; so [15:0] e guardado)
    wire [31:0] dim_m_new = apply_strb({16'd0, dim_m_q}, reg_wr_data, reg_wr_strb);
    wire [31:0] dim_n_new = apply_strb({16'd0, dim_n_q}, reg_wr_data, reg_wr_strb);
    wire [31:0] dim_k_new = apply_strb({16'd0, dim_k_q}, reg_wr_data, reg_wr_strb);

    // Configuracao: ADDR_* e DIM_*
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            addr_a_q <= 32'd0;
            addr_b_q <= 32'd0;
            addr_c_q <= 32'd0;
            dim_m_q  <= 16'd0;
            dim_n_q  <= 16'd0;
            dim_k_q  <= 16'd0;
        end else if (wr_cfg) begin
            case (reg_wr_addr)
                REG_ADDR_A: addr_a_q <= apply_strb(addr_a_q, reg_wr_data, reg_wr_strb);
                REG_ADDR_B: addr_b_q <= apply_strb(addr_b_q, reg_wr_data, reg_wr_strb);
                REG_ADDR_C: addr_c_q <= apply_strb(addr_c_q, reg_wr_data, reg_wr_strb);
                REG_DIM_M:  dim_m_q  <= dim_m_new[15:0];
                REG_DIM_N:  dim_n_q  <= dim_n_new[15:0];
                REG_DIM_K:  dim_k_q  <= dim_k_new[15:0];
                default: ;
            endcase
        end
    end

    // CTRL e pulsos de comando
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            irq_en_q     <= 1'b0;
            start_q      <= 1'b0;
            soft_reset_q <= 1'b0;
        end else begin
            start_q      <= start_w;
            soft_reset_q <= soft_reset_w;
            if (wr_ctrl)
                irq_en_q <= reg_wr_data[1];
        end
    end

    // STATUS: prioridade crescente de cima para baixo
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            done_q     <= 1'b0;
            error_q    <= 1'b0;
            err_code_q <= 4'd0;
        end else begin
            if (start_w) begin
                done_q     <= 1'b0;
                error_q    <= 1'b0;
                err_code_q <= 4'd0;
            end
            if (wr_status) begin
                if (reg_wr_data[1]) done_q  <= 1'b0;
                if (reg_wr_data[2]) error_q <= 1'b0;
            end
            if (ctrl_error) begin
                error_q    <= 1'b1;
                err_code_q <= ctrl_err_code;
            end
            if (ctrl_done)
                done_q <= 1'b1;
        end
    end

    // Contadores de desempenho
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cycles_q      <= 32'd0;
            cyc_compute_q <= 32'd0;
        end else if (start_w) begin
            cycles_q      <= 32'd0;
            cyc_compute_q <= 32'd0;
        end else begin
            if (ctrl_busy)  cycles_q      <= cycles_q + 32'd1;
            if (acc_active) cyc_compute_q <= cyc_compute_q + 32'd1;
        end
    end

    // -----------------------------------------------------------------
    // Leitura (combinacional; o axi_if amostra no handshake de AR)
    // -----------------------------------------------------------------
    localparam [7:0] T8 = ARRAY_SIZE;
    localparam       PP = (PINGPONG != 0) ? 1'b1 : 1'b0;

    always @(*) begin
        case (reg_rd_addr)
            REG_CTRL:        reg_rd_data = {29'd0, 1'b0, irq_en_q, 1'b0};
            REG_STATUS:      reg_rd_data = {24'd0, err_code_q, 1'b0, error_q, done_q, ctrl_busy};
            REG_ADDR_A:      reg_rd_data = addr_a_q;
            REG_ADDR_B:      reg_rd_data = addr_b_q;
            REG_ADDR_C:      reg_rd_data = addr_c_q;
            REG_DIM_M:       reg_rd_data = {16'd0, dim_m_q};
            REG_DIM_N:       reg_rd_data = {16'd0, dim_n_q};
            REG_DIM_K:       reg_rd_data = {16'd0, dim_k_q};
            REG_CYCLES:      reg_rd_data = cycles_q;
            REG_INFO:        reg_rd_data = {3'd0, PP, VERSION, 8'd32, 8'd8, T8};
            REG_CYC_COMPUTE: reg_rd_data = cyc_compute_q;
            default:         reg_rd_data = 32'd0;
        endcase
    end

    // -----------------------------------------------------------------
    // Saidas
    // -----------------------------------------------------------------
    assign start      = start_q;
    assign soft_reset = soft_reset_q;
    assign addr_a     = addr_a_q;
    assign addr_b     = addr_b_q;
    assign addr_c     = addr_c_q;
    assign dim_m      = dim_m_q;
    assign dim_n      = dim_n_q;
    assign dim_k      = dim_k_q;
    assign irq        = done_q & irq_en_q;

endmodule

`default_nettype wire
