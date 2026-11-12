`timescale 1ns/1ps
`default_nettype none
`include "axi_defs.vh"

// Motor de leitura AXI4: dono dos canais AR e R (MAS secoes 9.5, 10.1, 10.3).
//
// Recebe "linhas de A/B" do dma_load (comando corrente + 1 na fila), le cada
// linha em 1 ou mais bursts INCR (divisao em 4 KB / MAX_BURST), alinha os bytes,
// zera o padding e escreve uma palavra por ciclo no buffer do acelerador.
//
//   R_IDLE --fila: nbytes = 0--> R_ZERO     (linha de padding, sem AR)
//          --fila: nbytes > 0--> R_AR
//   R_AR   --ARREADY--> R_DATA
//   R_DATA --RLAST & resta segmento-----> R_AR    (proximo segmento)
//          --RLAST & faltam palavras----> R_ZERO  (completa a linha com zeros)
//          --RLAST & linha completa-----> fim de linha
//   R_ZERO --ultima palavra--> fim de linha
//   Fim de linha: pulso de rd_done e, se a fila tem comando, carrega no mesmo
//   ciclo (vai para R_AR ou R_ZERO); senao, R_IDLE.
//
// Saidas AXI: ARVALID, ARADDR, ARLEN e RREADY saem de flops.
module dma_rd_engine #(
    parameter ARRAY_SIZE = 4,
    parameter MAX_BURST  = 16,
    // derivados, nao sobrescrever
    parameter IW  = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1,
    parameter CW  = $clog2(ARRAY_SIZE + 1),
    parameter WPR = (ARRAY_SIZE + 3) / 4,
    parameter WW  = (WPR > 1) ? $clog2(WPR) : 1
)(
    input  wire          clk,
    input  wire          rst_n,

    // Comando do dma_load
    input  wire          rd_cmd_valid,
    output wire          rd_cmd_ready,
    input  wire [31:0]   rd_cmd_addr,     // primeiro byte valido da linha
    input  wire [CW-1:0] rd_cmd_nbytes,   // 0 ... T (0 = padding)
    input  wire          rd_cmd_sel,      // 0 = A, 1 = B
    input  wire          rd_cmd_bank,
    input  wire [IW-1:0] rd_cmd_row,
    output wire          rd_done,         // pulso: uma linha escrita no buffer
    output wire          rd_idle,
    output wire          rd_err,
    input  wire          err_clr,         // pulso do CHECK

    // AXI4 master: AR / R
    output wire [31:0]   m_araddr,
    output wire [7:0]    m_arlen,
    output wire          m_arvalid,
    input  wire          m_arready,
    input  wire [31:0]   m_rdata,
    input  wire [1:0]    m_rresp,
    input  wire          m_rlast,
    input  wire          m_rvalid,
    output wire          m_rready,

    // Porta de escrita dos buffers do acelerador
    output wire          buf_a_we,
    output wire          buf_b_we,
    output wire          buf_bank,
    output wire [IW-1:0] buf_row,
    output wire [WW-1:0] buf_word,
    output wire [31:0]   buf_wdata
);

    // -----------------------------------------------------------------
    // Constantes
    // -----------------------------------------------------------------
    localparam [1:0] R_IDLE = 2'd0,
                     R_AR   = 2'd1,
                     R_DATA = 2'd2,
                     R_ZERO = 2'd3;

    localparam [WW-1:0] LAST_WORD = WPR - 1;
    localparam QW = 32 + CW + 1 + 1 + IW;     // largura do comando na fila

    // -----------------------------------------------------------------
    // Fila de 1 comando
    // -----------------------------------------------------------------
    wire          q_valid;
    wire [QW-1:0] q_data;
    reg           load;              // strobe: fila -> comando corrente

    dma_cmd_queue #(.WIDTH(QW)) u_cmd_queue (
        .clk       (clk),
        .rst_n     (rst_n),
        .in_valid  (rd_cmd_valid),
        .in_ready  (rd_cmd_ready),
        .in_data   ({rd_cmd_addr, rd_cmd_nbytes, rd_cmd_sel, rd_cmd_bank, rd_cmd_row}),
        .out_valid (q_valid),
        .out_data  (q_data),
        .out_pop   (load)
    );

    wire [31:0]   q_addr;
    wire [CW-1:0] q_nbytes;
    wire          q_sel;
    wire          q_bank;
    wire [IW-1:0] q_row;

    assign {q_addr, q_nbytes, q_sel, q_bank, q_row} = q_data;

    // Palavras de 32 bits que a linha ocupa na memoria: ceil((off + nbytes) / 4)
    wire [4:0] q_nwords_sum = {3'd0, q_addr[1:0]} + {{(5-CW){1'b0}}, q_nbytes} + 5'd3;
    wire [4:0] q_nwords     = {2'd0, q_nwords_sum[4:2]};
    wire       q_is_pad     = (q_nbytes == {CW{1'b0}});

    // -----------------------------------------------------------------
    // Registradores
    // -----------------------------------------------------------------
    reg [1:0]    state_q, state_d;

    reg          cur_sel_q;
    reg          cur_bank_q;
    reg [IW-1:0] cur_row_q;
    reg [CW-1:0] cur_nbytes_q;
    reg [1:0]    cur_off_q;       // addr[1:0] do primeiro byte
    reg [WW-1:0] word_q;          // palavra do buffer escrita agora

    reg [31:0]   seg_addr_q;      // ARADDR do segmento
    reg [4:0]    seg_len_q;       // beats do segmento
    reg [4:0]    rest_q;          // palavras restantes, incluindo o segmento
    reg [7:0]    arlen_q;

    reg          m_arvalid_q;
    reg          m_rready_q;
    reg          rd_done_q;
    reg          rd_err_q;

    // -----------------------------------------------------------------
    // Divisao em segmentos: uma instancia, alimentada pelo proximo segmento
    // -----------------------------------------------------------------
    reg          seg_advance;     // strobe: proximo segmento da mesma linha

    wire [31:0] next_seg_addr = seg_advance ? (seg_addr_q + {25'd0, seg_len_q, 2'b00})
                                            : {q_addr[31:2], 2'b00};
    wire [4:0]  next_rest     = seg_advance ? (rest_q - seg_len_q) : q_nwords;
    wire [4:0]  split_len;
    wire [7:0]  split_axlen;

    dma_burst_split #(.MAX_BURST(MAX_BURST)) u_split (
        .addr    (next_seg_addr),
        .rest    (next_rest),
        .seg_len (split_len),
        .axlen   (split_axlen)
    );

    wire more_segs = (rest_q != seg_len_q);
    wire beat      = m_rvalid & m_rready_q;

    // -----------------------------------------------------------------
    // Proximo estado e strobes
    // -----------------------------------------------------------------
    reg line_end;     // ultima palavra da linha escrita neste ciclo

    // Destino ao carregar um comando da fila (ou R_IDLE se vazia)
    wire [1:0] load_target = q_is_pad ? R_ZERO : R_AR;

    always @(*) begin
        state_d     = state_q;
        load        = 1'b0;
        seg_advance = 1'b0;
        line_end    = 1'b0;

        case (state_q)
            R_IDLE: begin
                if (q_valid) begin
                    load    = 1'b1;
                    state_d = load_target;
                end
            end

            R_AR: begin
                if (m_arready)
                    state_d = R_DATA;
            end

            R_DATA: begin
                if (beat && m_rlast) begin
                    if (more_segs) begin
                        seg_advance = 1'b1;
                        state_d     = R_AR;
                    end else if (word_q != LAST_WORD) begin
                        state_d = R_ZERO;
                    end else begin
                        line_end = 1'b1;
                    end
                end
            end

            R_ZERO: begin
                if (word_q == LAST_WORD)
                    line_end = 1'b1;
            end

            default: state_d = R_IDLE;
        endcase

        // Fim de linha: puxa o proximo comando no mesmo ciclo
        if (line_end) begin
            if (q_valid) begin
                load    = 1'b1;
                state_d = load_target;
            end else begin
                state_d = R_IDLE;
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= R_IDLE;
        else        state_q <= state_d;
    end

    // -----------------------------------------------------------------
    // Datapath: comando corrente
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cur_sel_q    <= 1'b0;
            cur_bank_q   <= 1'b0;
            cur_row_q    <= {IW{1'b0}};
            cur_nbytes_q <= {CW{1'b0}};
            cur_off_q    <= 2'd0;
        end else if (load) begin
            cur_sel_q    <= q_sel;
            cur_bank_q   <= q_bank;
            cur_row_q    <= q_row;
            cur_nbytes_q <= q_nbytes;
            cur_off_q    <= q_addr[1:0];
        end
    end

    // Palavra corrente do buffer: avanca a cada beat e a cada ciclo de R_ZERO
    wire buf_we = beat | (state_q == R_ZERO);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            word_q <= {WW{1'b0}};
        else if (load)
            word_q <= {WW{1'b0}};
        else if (buf_we)
            word_q <= word_q + 1'b1;
    end

    // Segmento corrente
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            seg_addr_q <= 32'd0;
            seg_len_q  <= 5'd0;
            rest_q     <= 5'd0;
            arlen_q    <= 8'd0;
        end else if (load || seg_advance) begin
            seg_addr_q <= next_seg_addr;
            seg_len_q  <= split_len;
            rest_q     <= next_rest;
            arlen_q    <= split_axlen;
        end
    end

    // Saidas AXI registradas a partir do proximo estado
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_arvalid_q <= 1'b0;
            m_rready_q  <= 1'b0;
        end else begin
            m_arvalid_q <= (state_d == R_AR);
            m_rready_q  <= (state_d == R_DATA);
        end
    end

    // Status para as FSMs e para o dma_ctrl
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rd_done_q <= 1'b0;
            rd_err_q  <= 1'b0;
        end else begin
            rd_done_q <= line_end;
            if (err_clr)
                rd_err_q <= 1'b0;
            else if (beat && (m_rresp != `AXI_RESP_OKAY))
                rd_err_q <= 1'b1;
        end
    end

    // -----------------------------------------------------------------
    // Alinhamento e mascara de padding (MAS 10.1)
    // -----------------------------------------------------------------
    wire [31:0] shifted = m_rdata >> {cur_off_q, 3'b000};
    wire [31:0] lanes_masked;

    genvar l;
    generate
        for (l = 0; l < 4; l = l + 1) begin : gen_lane
            // coluna desta lane dentro da linha: 4*word + l
            wire [5:0] col       = {word_q, 2'b00} + l;
            wire       lane_used = (col < {{(6-CW){1'b0}}, cur_nbytes_q});
            assign lanes_masked[8*l +: 8] = lane_used ? shifted[8*l +: 8] : 8'd0;
        end
    endgenerate

    // -----------------------------------------------------------------
    // Saidas
    // -----------------------------------------------------------------
    assign m_araddr  = seg_addr_q;
    assign m_arlen   = arlen_q;
    assign m_arvalid = m_arvalid_q;
    assign m_rready  = m_rready_q;

    assign buf_a_we  = buf_we & ~cur_sel_q;
    assign buf_b_we  = buf_we &  cur_sel_q;
    assign buf_bank  = cur_bank_q;
    assign buf_row   = cur_row_q;
    assign buf_word  = word_q;
    assign buf_wdata = (state_q == R_ZERO) ? 32'd0 : lanes_masked;

    assign rd_done   = rd_done_q;
    assign rd_idle   = (state_q == R_IDLE) & ~q_valid;
    assign rd_err    = rd_err_q;

endmodule

`default_nettype wire
