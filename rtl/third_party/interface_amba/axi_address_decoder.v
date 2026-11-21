`include "axi_defs.vh"

// axi_address_decoder - valida faixa de endereco e AxSIZE antes do subordinado (R-15, R-21).
// MAS §4.3, §5.3, §5.3.1. Fica entre o mestre (lado s_axi_*) e o axi_transaction_manager
// (lado m_axi_*); a SRAM nunca ve uma requisicao invalida.
//
//   - Endereco fora de 0x0000_0000..0x001F_FFFF (inicio OU fim do burst): resposta DECERR.
//   - AxSIZE acima de 4 bytes (3'b010): resposta SLVERR. DECERR tem precedencia (MAS §5.3.1).
//   - A requisicao invalida NAO e encaminhada. O burst e drenado por inteiro: leitura devolve
//     arlen+1 beats com o mesmo codigo e rlast no ultimo; escrita consome awlen+1 beats de W
//     e devolve uma unica resposta B. Um burst parcialmente respondido trava o canal.
//   - Respostas de erro so saem depois que todos os bursts validos anteriores foram respondidos
//     (contadores *_outstanding_q), para nao furar a ordem de respostas de um mesmo ID (R-03).
//
// Leitura e escrita sao canais independentes, cada um com sua FSM (IDLE / PASSTHROUGH /
// ERROR_DRAIN), no padrao: um always @* de proximo estado e um always sequencial de estado.
//
// Latencia: requisicao valida atravessa o decoder em modo combinacional (sem ciclo extra por
// beat nem por burst). PASSTHROUGH so existe para segurar a decisao enquanto o subordinado
// ainda nao aceitou o comando.
module axi_address_decoder (
    input         aclk,
    input         aresetn,

    // ---------------- lado do mestre (subordinado AXI4) ----------------
    input  [3:0]  s_axi_awid,
    input  [31:0] s_axi_awaddr,
    input  [7:0]  s_axi_awlen,
    input  [2:0]  s_axi_awsize,
    input  [1:0]  s_axi_awburst,
    input         s_axi_awvalid,
    output reg    s_axi_awready,
    input  [31:0] s_axi_wdata,
    input  [3:0]  s_axi_wstrb,
    input         s_axi_wlast,
    input         s_axi_wvalid,
    output reg    s_axi_wready,
    output reg [3:0] s_axi_bid,
    output reg [1:0] s_axi_bresp,
    output reg    s_axi_bvalid,
    input         s_axi_bready,
    input  [3:0]  s_axi_arid,
    input  [31:0] s_axi_araddr,
    input  [7:0]  s_axi_arlen,
    input  [2:0]  s_axi_arsize,
    input  [1:0]  s_axi_arburst,
    input         s_axi_arvalid,
    output reg    s_axi_arready,
    output reg [3:0]  s_axi_rid,
    output reg [31:0] s_axi_rdata,
    output reg [1:0]  s_axi_rresp,
    output reg    s_axi_rlast,
    output reg    s_axi_rvalid,
    input         s_axi_rready,

    // ---------------- lado do subordinado (axi_transaction_manager) ----------------
    output [3:0]  m_axi_awid,
    output [31:0] m_axi_awaddr,
    output [7:0]  m_axi_awlen,
    output [2:0]  m_axi_awsize,
    output [1:0]  m_axi_awburst,
    output reg    m_axi_awvalid,
    input         m_axi_awready,
    output [31:0] m_axi_wdata,
    output [3:0]  m_axi_wstrb,
    output        m_axi_wlast,
    output reg    m_axi_wvalid,
    input         m_axi_wready,
    input  [3:0]  m_axi_bid,
    input  [1:0]  m_axi_bresp,
    input         m_axi_bvalid,
    output reg    m_axi_bready,
    output [3:0]  m_axi_arid,
    output [31:0] m_axi_araddr,
    output [7:0]  m_axi_arlen,
    output [2:0]  m_axi_arsize,
    output [1:0]  m_axi_arburst,
    output reg    m_axi_arvalid,
    input         m_axi_arready,
    input  [3:0]  m_axi_rid,
    input  [31:0] m_axi_rdata,
    input  [1:0]  m_axi_rresp,
    input         m_axi_rlast,
    input         m_axi_rvalid,
    output reg    m_axi_rready
);

    // ---------------- estados (iguais nas duas FSMs) ----------------
    localparam [1:0] S_IDLE        = 2'd0,  // avalia o comando; encaminha em modo combinacional
                     S_PASSTHROUGH = 2'd1,  // comando valido oferecido, subordinado ainda nao aceitou
                     S_ERROR_DRAIN = 2'd2;  // comando invalido: responde o burst com erro

    // campos que nao dependem da decisao seguem direto para o subordinado
    assign m_axi_awid    = s_axi_awid;
    assign m_axi_awaddr  = s_axi_awaddr;
    assign m_axi_awlen   = s_axi_awlen;
    assign m_axi_awsize  = s_axi_awsize;
    assign m_axi_awburst = s_axi_awburst;
    assign m_axi_wdata   = s_axi_wdata;
    assign m_axi_wstrb   = s_axi_wstrb;
    assign m_axi_wlast   = s_axi_wlast;
    assign m_axi_arid    = s_axi_arid;
    assign m_axi_araddr  = s_axi_araddr;
    assign m_axi_arlen   = s_axi_arlen;
    assign m_axi_arsize  = s_axi_arsize;
    assign m_axi_arburst = s_axi_arburst;

    // =====================================================================================
    // Decodificacao (combinacional) - faixa e tamanho
    // =====================================================================================
    // Fim do burst = Aligned_Address + (len+1)*2^size - 1 (IHI0022E §A3.4.1); a faixa e
    // potencia de dois, entao "dentro da faixa" e "bits [31:21] todos zero" (OR reduzido).
    wire [31:0] ar_nbytes_w  = 32'd1 << s_axi_arsize;
    wire [31:0] ar_aligned_w = s_axi_araddr & ~(ar_nbytes_w - 32'd1);
    wire [31:0] ar_end_w     = ar_aligned_w + (({24'd0, s_axi_arlen} + 32'd1) << s_axi_arsize) - 32'd1;
    wire        ar_addr_ok_w = ~(|s_axi_araddr[31:21]) & ~(|ar_end_w[31:21]);
    wire        ar_size_ok_w = (s_axi_arsize <= 3'b010);
    wire        ar_ok_w      = ar_addr_ok_w & ar_size_ok_w;

    wire [31:0] aw_nbytes_w  = 32'd1 << s_axi_awsize;
    wire [31:0] aw_aligned_w = s_axi_awaddr & ~(aw_nbytes_w - 32'd1);
    wire [31:0] aw_end_w     = aw_aligned_w + (({24'd0, s_axi_awlen} + 32'd1) << s_axi_awsize) - 32'd1;
    wire        aw_addr_ok_w = ~(|s_axi_awaddr[31:21]) & ~(|aw_end_w[31:21]);
    wire        aw_size_ok_w = (s_axi_awsize <= 3'b010);
    wire        aw_ok_w      = aw_addr_ok_w & aw_size_ok_w;

    // codigo de erro: DECERR (endereco) tem precedencia sobre SLVERR (tamanho)
    reg [1:0] ar_err_code_r;
    reg [1:0] aw_err_code_r;
    always @* begin
        if (!ar_addr_ok_w) ar_err_code_r = `AXI_RESP_DECERR;
        else               ar_err_code_r = `AXI_RESP_SLVERR;
    end
    always @* begin
        if (!aw_addr_ok_w) aw_err_code_r = `AXI_RESP_DECERR;
        else               aw_err_code_r = `AXI_RESP_SLVERR;
    end

    // =====================================================================================
    // CANAL DE LEITURA (AR / R)
    // =====================================================================================
    reg [1:0] rd_state_q, rd_state_next_r;
    reg [3:0] rd_err_id_q;           // ID do burst de erro
    reg [1:0] rd_err_code_q;         // codigo de erro do burst
    reg [7:0] rd_beat_cnt_q;         // beats de erro que faltam, menos 1
    reg [3:0] rd_outstanding_q;      // bursts validos encaminhados e ainda nao respondidos por inteiro

    wire m_ar_hs_w = m_axi_arvalid & m_axi_arready;
    wire m_r_last_hs_w = m_axi_rvalid & m_axi_rready & m_axi_rlast;

    // beats de erro so saem depois de os bursts validos anteriores terminarem (ordem de ID)
    wire rd_err_beat_w   = (rd_state_q == S_ERROR_DRAIN) & (rd_outstanding_q == 4'd0);
    wire rd_err_hs_w     = rd_err_beat_w & s_axi_rready;
    wire rd_err_last_w   = (rd_beat_cnt_q == 8'd0);

    // ---- proximo estado ----
    always @* begin
        rd_state_next_r = rd_state_q;
        case (rd_state_q)
            S_IDLE: begin
                if (s_axi_arvalid) begin
                    if (!ar_ok_w)          rd_state_next_r = S_ERROR_DRAIN;
                    else if (m_axi_arready) rd_state_next_r = S_IDLE;        // aceito no mesmo ciclo
                    else                   rd_state_next_r = S_PASSTHROUGH;
                end
            end

            S_PASSTHROUGH: begin
                if (m_axi_arready) rd_state_next_r = S_IDLE;
            end

            S_ERROR_DRAIN: begin
                if (rd_err_hs_w && rd_err_last_w) rd_state_next_r = S_IDLE;
            end

            default: rd_state_next_r = S_IDLE;
        endcase
    end

    // ---- registrador de estado ----
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) rd_state_q <= S_IDLE;
        else          rd_state_q <= rd_state_next_r;
    end

    // ---- contexto do burst de erro e contador de bursts em voo ----
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            rd_err_id_q      <= 4'd0;
            rd_err_code_q    <= `AXI_RESP_OKAY;
            rd_beat_cnt_q    <= 8'd0;
            rd_outstanding_q <= 4'd0;
        end else begin
            // captura o comando invalido no ciclo em que ele e aceito
            if (rd_state_q == S_IDLE && s_axi_arvalid && !ar_ok_w) begin
                rd_err_id_q   <= s_axi_arid;
                rd_err_code_q <= ar_err_code_r;
                rd_beat_cnt_q <= s_axi_arlen;
            end
            if (rd_err_hs_w) rd_beat_cnt_q <= rd_beat_cnt_q - 8'd1;

            // bursts validos em voo: +1 no AR aceito, -1 no ultimo beat de R entregue
            if (m_ar_hs_w && !m_r_last_hs_w)      rd_outstanding_q <= rd_outstanding_q + 4'd1;
            else if (!m_ar_hs_w && m_r_last_hs_w) rd_outstanding_q <= rd_outstanding_q - 4'd1;
        end
    end

    // ---- saidas do canal AR ----
    always @* begin
        m_axi_arvalid = 1'b0;
        s_axi_arready = 1'b0;
        case (rd_state_q)
            S_IDLE: begin
                if (s_axi_arvalid && !ar_ok_w) begin
                    s_axi_arready = 1'b1;                  // aceita o comando invalido
                end else begin
                    m_axi_arvalid = s_axi_arvalid;
                    s_axi_arready = m_axi_arready;
                end
            end
            S_PASSTHROUGH: begin
                m_axi_arvalid = s_axi_arvalid;
                s_axi_arready = m_axi_arready;
            end
            default: ;                                     // ERROR_DRAIN: nao aceita novo AR
        endcase
    end

    // ---- saidas do canal R: erro gerado aqui ou resposta do subordinado ----
    always @* begin
        if (rd_err_beat_w) begin
            s_axi_rid     = rd_err_id_q;
            s_axi_rdata   = 32'h0000_0000;
            s_axi_rresp   = rd_err_code_q;
            s_axi_rlast   = rd_err_last_w;
            s_axi_rvalid  = 1'b1;
            m_axi_rready  = 1'b0;
        end else begin
            s_axi_rid     = m_axi_rid;
            s_axi_rdata   = m_axi_rdata;
            s_axi_rresp   = m_axi_rresp;
            s_axi_rlast   = m_axi_rlast;
            s_axi_rvalid  = m_axi_rvalid;
            m_axi_rready  = s_axi_rready;
        end
    end

    // =====================================================================================
    // CANAL DE ESCRITA (AW / W / B)
    // =====================================================================================
    reg [1:0] wr_state_q, wr_state_next_r;
    reg [3:0] wr_err_id_q;
    reg [1:0] wr_err_code_q;
    reg       wr_err_w_done_q;       // wlast do burst de erro ja consumido
    reg       aw_done_q;             // AW do burst valido ja aceito pelo subordinado
    reg       wlast_done_q;          // wlast do burst valido ja aceito pelo subordinado
    reg [3:0] wr_outstanding_q;      // bursts validos com AW aceito e B ainda nao entregue

    wire m_aw_hs_w      = m_axi_awvalid & m_axi_awready;
    wire m_w_last_hs_w  = m_axi_wvalid & m_axi_wready & s_axi_wlast;
    wire m_b_hs_w       = m_axi_bvalid & m_axi_bready;

    // B de erro: depois de consumir todo o W do burst e de os B dos bursts anteriores sairem
    wire wr_err_b_w     = (wr_state_q == S_ERROR_DRAIN) & wr_err_w_done_q & (wr_outstanding_q == 4'd0);
    wire wr_err_b_hs_w  = wr_err_b_w & s_axi_bready;

    // ---- proximo estado ----
    always @* begin
        wr_state_next_r = wr_state_q;
        case (wr_state_q)
            S_IDLE: begin
                if (s_axi_awvalid) begin
                    if (!aw_ok_w)                          wr_state_next_r = S_ERROR_DRAIN;
                    else if (m_aw_hs_w && m_w_last_hs_w)   wr_state_next_r = S_IDLE;   // burst de 1 beat completo
                    else                                   wr_state_next_r = S_PASSTHROUGH;
                end
            end

            S_PASSTHROUGH: begin
                if ((aw_done_q || m_aw_hs_w) && (wlast_done_q || m_w_last_hs_w))
                    wr_state_next_r = S_IDLE;
            end

            S_ERROR_DRAIN: begin
                if (wr_err_b_hs_w) wr_state_next_r = S_IDLE;
            end

            default: wr_state_next_r = S_IDLE;
        endcase
    end

    // ---- registrador de estado ----
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) wr_state_q <= S_IDLE;
        else          wr_state_q <= wr_state_next_r;
    end

    // ---- contexto do burst e contador de bursts em voo ----
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            wr_err_id_q      <= 4'd0;
            wr_err_code_q    <= `AXI_RESP_OKAY;
            wr_err_w_done_q  <= 1'b0;
            aw_done_q        <= 1'b0;
            wlast_done_q     <= 1'b0;
            wr_outstanding_q <= 4'd0;
        end else begin
            if (wr_state_q == S_IDLE) begin
                // flags do burst valido nascem do que ja aconteceu neste ciclo
                aw_done_q       <= m_aw_hs_w;
                wlast_done_q    <= m_w_last_hs_w;
                wr_err_w_done_q <= 1'b0;
                if (s_axi_awvalid && !aw_ok_w) begin
                    wr_err_id_q   <= s_axi_awid;
                    wr_err_code_q <= aw_err_code_r;
                end
            end else if (wr_state_q == S_PASSTHROUGH) begin
                if (m_aw_hs_w)     aw_done_q    <= 1'b1;
                if (m_w_last_hs_w) wlast_done_q <= 1'b1;
            end else begin
                if (s_axi_wvalid && s_axi_wready && s_axi_wlast) wr_err_w_done_q <= 1'b1;
            end

            // bursts validos em voo: +1 no AW aceito, -1 no B entregue
            if (m_aw_hs_w && !m_b_hs_w)      wr_outstanding_q <= wr_outstanding_q + 4'd1;
            else if (!m_aw_hs_w && m_b_hs_w) wr_outstanding_q <= wr_outstanding_q - 4'd1;
        end
    end

    // ---- saidas dos canais AW e W ----
    always @* begin
        m_axi_awvalid = 1'b0;
        s_axi_awready = 1'b0;
        m_axi_wvalid  = 1'b0;
        s_axi_wready  = 1'b0;
        case (wr_state_q)
            S_IDLE: begin
                // W so segue depois da decisao sobre o AW (cobre W antes de AW, T-S-AXI-004)
                if (s_axi_awvalid && !aw_ok_w) begin
                    s_axi_awready = 1'b1;                  // aceita o comando invalido
                end else if (s_axi_awvalid) begin
                    m_axi_awvalid = s_axi_awvalid;
                    s_axi_awready = m_axi_awready;
                    m_axi_wvalid  = s_axi_wvalid;
                    s_axi_wready  = m_axi_wready;
                end
            end
            S_PASSTHROUGH: begin
                m_axi_awvalid = s_axi_awvalid & ~aw_done_q;
                s_axi_awready = m_axi_awready & ~aw_done_q;
                m_axi_wvalid  = s_axi_wvalid & ~wlast_done_q;
                s_axi_wready  = m_axi_wready & ~wlast_done_q;
            end
            S_ERROR_DRAIN: begin
                s_axi_wready = ~wr_err_w_done_q;           // consome o W do burst de erro
            end
            default: ;
        endcase
    end

    // ---- saidas do canal B: erro gerado aqui ou resposta do subordinado ----
    always @* begin
        if (wr_err_b_w) begin
            s_axi_bid     = wr_err_id_q;
            s_axi_bresp   = wr_err_code_q;
            s_axi_bvalid  = 1'b1;
            m_axi_bready  = 1'b0;
        end else begin
            s_axi_bid     = m_axi_bid;
            s_axi_bresp   = m_axi_bresp;
            s_axi_bvalid  = m_axi_bvalid;
            m_axi_bready  = s_axi_bready;
        end
    end

endmodule
