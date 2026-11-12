`timescale 1ns/1ps
`default_nettype none
`include "axi_defs.vh"

// Motor de escrita AXI4: dono dos canais AW, W e B (MAS secoes 9.5, 10.2, 10.3).
//
// Recebe "linhas de C" do dma_store (comando corrente + 1 na fila), le os
// elementos do acelerador com c_rd (1 ciclo de latencia) por uma fila de 2
// entradas e grava cada linha em 1 ou mais bursts INCR.
//
//   W_IDLE --fila com comando--> W_ADDR   (comeca a buscar C, coluna 0)
//   W_ADDR --aw_ok & w_ok--> W_RESP       (W inteiro aceito antes ou junto do AW)
//          --aw_ok       --> W_DATA
//          --senao       --> W_ADDR       (registra aw_done / w_done)
//   W_DATA --w_ok--> W_RESP
//   W_RESP --B & resta segmento--> W_ADDR (proximo segmento)
//          --B & fim da linha----> fim de linha
//   Fim de linha: pulso de wr_done e, se a fila tem comando, carrega no mesmo
//   ciclo (vai para W_ADDR); senao, W_IDLE.
//
//   aw_ok = aw_done | (AWVALID & AWREADY)
//   w_ok  = w_done  | (WVALID & WREADY & WLAST)
//
// AW e W andam de forma independente (MAS 4.3 regra 2): AWVALID nao espera
// WREADY e WVALID nao espera AWREADY.
// AWVALID, AWADDR, AWLEN, BREADY saem de flops. WVALID = fase W (flop) e fila
// nao vazia (flop); WDATA = cabeca da fila (flop).
module dma_wr_engine #(
    parameter ARRAY_SIZE = 4,
    parameter MAX_BURST  = 16,
    // derivados, nao sobrescrever
    parameter IW = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1,
    parameter CW = $clog2(ARRAY_SIZE + 1)
)(
    input  wire          clk,
    input  wire          rst_n,

    // Comando do dma_store
    input  wire          wr_cmd_valid,
    output wire          wr_cmd_ready,
    input  wire [31:0]   wr_cmd_addr,     // endereco de C[i0s + r][j0s]
    input  wire [CW-1:0] wr_cmd_nwords,   // 1 ... T
    input  wire [IW-1:0] wr_cmd_row,
    output wire          wr_done,         // pulso: todos os B de uma linha
    output wire          wr_idle,
    output wire          wr_err,
    input  wire          err_clr,         // pulso do CHECK

    // AXI4 master: AW / W / B
    output wire [31:0]   m_awaddr,
    output wire [7:0]    m_awlen,
    output wire          m_awvalid,
    input  wire          m_awready,
    output wire [31:0]   m_wdata,
    output wire [3:0]    m_wstrb,
    output wire          m_wlast,
    output wire          m_wvalid,
    input  wire          m_wready,
    input  wire [1:0]    m_bresp,
    input  wire          m_bvalid,
    output wire          m_bready,

    // Leitura de C no acelerador
    output wire          c_rd,
    output wire [IW-1:0] c_row,
    output wire [IW-1:0] c_col,
    input  wire [31:0]   c_rdata
);

    // -----------------------------------------------------------------
    // Constantes
    // -----------------------------------------------------------------
    localparam [1:0] W_IDLE = 2'd0,
                     W_ADDR = 2'd1,
                     W_DATA = 2'd2,
                     W_RESP = 2'd3;

    localparam QW = 32 + CW + IW;     // largura do comando na fila

    // -----------------------------------------------------------------
    // Fila de 1 comando
    // -----------------------------------------------------------------
    wire          q_valid;
    wire [QW-1:0] q_data;
    reg           load;               // strobe: fila -> comando corrente

    dma_cmd_queue #(.WIDTH(QW)) u_cmd_queue (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (wr_cmd_valid),
        .in_ready  (wr_cmd_ready),
        .in_data   ({wr_cmd_addr, wr_cmd_nwords, wr_cmd_row}),
        .out_valid (q_valid),
        .out_data  (q_data),
        .out_pop   (load)
    );

    wire [31:0]   q_addr;
    wire [CW-1:0] q_nwords;
    wire [IW-1:0] q_row;

    assign {q_addr, q_nwords, q_row} = q_data;

    // -----------------------------------------------------------------
    // Registradores
    // -----------------------------------------------------------------
    reg [1:0]    state_q, state_d;

    reg [IW-1:0] cur_row_q;
    reg [CW-1:0] cur_nwords_q;
    reg [CW-1:0] col_q;           // proxima coluna de C a buscar

    reg [31:0]   seg_addr_q;
    reg [4:0]    seg_len_q;
    reg [4:0]    rest_q;          // palavras restantes, incluindo o segmento
    reg [7:0]    awlen_q;
    reg [4:0]    w_cnt_q;         // beats de W que faltam no segmento

    reg          aw_done_q, aw_done_d;
    reg          w_done_q,  w_done_d;

    reg          m_awvalid_q;
    reg          m_bready_q;
    reg          c_rd_q;          // leitura de C em voo (dado chega agora)
    reg          wr_done_q;
    reg          wr_err_q;

    // -----------------------------------------------------------------
    // Divisao em segmentos
    // -----------------------------------------------------------------
    reg          seg_advance;

    wire [31:0] next_seg_addr = seg_advance ? (seg_addr_q + {25'd0, seg_len_q, 2'b00})
                                            : {q_addr[31:2], 2'b00};
    wire [4:0]  next_rest     = seg_advance ? (rest_q - seg_len_q)
                                            : {{(5-CW){1'b0}}, q_nwords};
    wire [4:0]  split_len;
    wire [7:0]  split_axlen;

    dma_burst_split #(.MAX_BURST(MAX_BURST)) u_split (
        .addr    (next_seg_addr),
        .rest    (next_rest),
        .seg_len (split_len),
        .axlen   (split_axlen)
    );

    wire more_segs = (rest_q != seg_len_q);

    // -----------------------------------------------------------------
    // Fila de dados de C e canal W
    // -----------------------------------------------------------------
    wire [31:0] fifo_head;
    wire [1:0]  fifo_count;

    wire w_phase = ((state_q == W_ADDR) | (state_q == W_DATA)) & ~w_done_q;
    wire wvalid  = w_phase & (fifo_count != 2'd0);
    wire wlast   = (w_cnt_q == 5'd1);
    wire w_beat  = wvalid & m_wready;

    wire aw_hs   = m_awvalid_q & m_awready;
    wire b_hs    = m_bvalid & m_bready_q;

    wire aw_ok   = aw_done_q | aw_hs;
    wire w_ok    = w_done_q  | (w_beat & wlast);

    // -----------------------------------------------------------------
    // Proximo estado e strobes
    // -----------------------------------------------------------------
    reg line_end;

    always @(*) begin
        state_d     = state_q;
        load        = 1'b0;
        seg_advance = 1'b0;
        line_end    = 1'b0;
        aw_done_d   = aw_done_q;
        w_done_d    = w_done_q;

        case (state_q)
            W_IDLE: begin
                if (q_valid) begin
                    load    = 1'b1;
                    state_d = W_ADDR;
                end
            end

            W_ADDR: begin
                if (aw_ok && w_ok) begin
                    state_d = W_RESP;
                end else if (aw_ok) begin
                    state_d = W_DATA;
                end else begin
                    aw_done_d = aw_ok;
                    w_done_d  = w_ok;
                end
            end

            W_DATA: begin
                if (w_ok)
                    state_d = W_RESP;
            end

            W_RESP: begin
                if (b_hs) begin
                    if (more_segs) begin
                        seg_advance = 1'b1;
                        state_d     = W_ADDR;
                    end else begin
                        line_end = 1'b1;
                    end
                end
            end

            default: state_d = W_IDLE;
        endcase

        // Fim de linha: puxa o proximo comando no mesmo ciclo
        if (line_end) begin
            if (q_valid) begin
                load    = 1'b1;
                state_d = W_ADDR;
            end else begin
                state_d = W_IDLE;
            end
        end

        // Novo segmento: AW e W recomecam
        if (load || seg_advance) begin
            aw_done_d = 1'b0;
            w_done_d  = 1'b0;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q   <= W_IDLE;
            aw_done_q <= 1'b0;
            w_done_q  <= 1'b0;
        end else begin
            state_q   <= state_d;
            aw_done_q <= aw_done_d;
            w_done_q  <= w_done_d;
        end
    end

    // -----------------------------------------------------------------
    // Busca de C (MAS 10.2)
    // c_rd sai quando cabe na fila: ocupacao + em voo - beat deste ciclo < 2.
    // No load, a coluna 0 da nova linha e buscada no mesmo ciclo.
    // -----------------------------------------------------------------
    wire [2:0] fifo_after = {1'b0, fifo_count} + {2'd0, c_rd_q} - {2'd0, w_beat};
    wire       credit     = (fifo_after < 3'd2);
    wire       fetching   = (state_q != W_IDLE) & (col_q < cur_nwords_q) & credit;
    wire       c_rd_w     = load | fetching;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_row_q    <= {IW{1'b0}};
            cur_nwords_q <= {CW{1'b0}};
            col_q        <= {CW{1'b0}};
        end else if (load) begin
            cur_row_q    <= q_row;
            cur_nwords_q <= q_nwords;
            col_q        <= {{(CW-1){1'b0}}, 1'b1};    // coluna 0 sai agora
        end else if (fetching) begin
            col_q <= col_q + 1'b1;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) c_rd_q <= 1'b0;
        else        c_rd_q <= c_rd_w;
    end

    dma_c_fifo u_c_fifo (
        .clk       (clk),
        .rst_n     (rst_n),
        .push      (c_rd_q),
        .push_data (c_rdata),
        .pop       (w_beat),
        .head      (fifo_head),
        .count     (fifo_count)
    );

    // -----------------------------------------------------------------
    // Segmento corrente e contador de beats de W
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_addr_q <= 32'd0;
            seg_len_q  <= 5'd0;
            rest_q     <= 5'd0;
            awlen_q    <= 8'd0;
        end else if (load || seg_advance) begin
            seg_addr_q <= next_seg_addr;
            seg_len_q  <= split_len;
            rest_q     <= next_rest;
            awlen_q    <= split_axlen;
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            w_cnt_q <= 5'd0;
        else if (load || seg_advance)
            w_cnt_q <= split_len;
        else if (w_beat)
            w_cnt_q <= w_cnt_q - 5'd1;
    end

    // -----------------------------------------------------------------
    // Saidas AXI registradas a partir do proximo estado
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_awvalid_q <= 1'b0;
            m_bready_q  <= 1'b0;
        end else begin
            m_awvalid_q <= (state_d == W_ADDR) & ~aw_done_d;
            m_bready_q  <= (state_d == W_RESP);
        end
    end

    // Status
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_done_q <= 1'b0;
            wr_err_q  <= 1'b0;
        end else begin
            wr_done_q <= line_end;
            if (err_clr)
                wr_err_q <= 1'b0;
            else if (b_hs && (m_bresp != `AXI_RESP_OKAY))
                wr_err_q <= 1'b1;
        end
    end

    // -----------------------------------------------------------------
    // Saidas
    // -----------------------------------------------------------------
    assign m_awaddr  = seg_addr_q;
    assign m_awlen   = awlen_q;
    assign m_awvalid = m_awvalid_q;
    assign m_wdata   = fifo_head;
    assign m_wstrb   = 4'b1111;
    assign m_wlast   = wlast;
    assign m_wvalid  = wvalid;
    assign m_bready  = m_bready_q;

    assign c_rd      = c_rd_w;
    assign c_row     = load ? q_row : cur_row_q;
    assign c_col     = load ? {IW{1'b0}} : col_q[IW-1:0];

    assign wr_done   = wr_done_q;
    assign wr_idle   = (state_q == W_IDLE) & ~q_valid;
    assign wr_err    = wr_err_q;

endmodule

`default_nettype wire
