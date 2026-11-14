`timescale 1ns/1ps
`default_nettype none

// Monitor passivo de uma interface AXI4 (MAS secao 16.1).
// Verifica, no perfil do projeto (MAS secao 4):
//   - VALID estavel ate o handshake e payload estavel enquanto espera;
//   - AxBURST = INCR, AxSIZE = 4 bytes, AxLEN <= 15;
//   - nenhum burst cruza fronteira de 4 KB;
//   - numero de beats = AxLEN + 1, LAST so no ultimo (R e W);
//   - B so depois do WLAST e do handshake de AW;
//   - no maximo 1 leitura e 1 escrita em andamento.
// Cada violacao imprime uma mensagem e incrementa "violations".
// Com CHECK_PROFILE = 0 as regras do perfil (burst/size/len/4 KB) nao sao
// conferidas: serve para o lado slave de testes que injetam pedidos invalidos.
module axi_checker #(
    parameter ID_W          = 1,
    parameter CHECK_PROFILE = 1,
    parameter NAME          = "axi"
)(
    input  wire            clk,
    input  wire            rst_n,

    input  wire [ID_W-1:0] awid,
    input  wire [31:0]     awaddr,
    input  wire [7:0]      awlen,
    input  wire [2:0]      awsize,
    input  wire [1:0]      awburst,
    input  wire            awvalid,
    input  wire            awready,
    input  wire [31:0]     wdata,
    input  wire [3:0]      wstrb,
    input  wire            wlast,
    input  wire            wvalid,
    input  wire            wready,
    input  wire [ID_W-1:0] bid,
    input  wire [1:0]      bresp,
    input  wire            bvalid,
    input  wire            bready,
    input  wire [ID_W-1:0] arid,
    input  wire [31:0]     araddr,
    input  wire [7:0]      arlen,
    input  wire [2:0]      arsize,
    input  wire [1:0]      arburst,
    input  wire            arvalid,
    input  wire            arready,
    input  wire [ID_W-1:0] rid,
    input  wire [31:0]     rdata,
    input  wire [1:0]      rresp,
    input  wire            rlast,
    input  wire            rvalid,
    input  wire            rready
);

    integer violations = 0;

    // Contadores para os testbenches
    integer ar_count = 0;
    integer aw_count = 0;
    integer r_beats  = 0;
    integer w_beats  = 0;
    integer b_count  = 0;

    task report;
        input [8*96-1:0] msg;
        begin
            violations = violations + 1;
            $display("[%0t] AXI_CHECKER(%0s) VIOLACAO: %0s", $time, NAME, msg);
        end
    endtask

    // Estado amostrado no ciclo anterior
    reg            p_awvalid, p_awready, p_wvalid, p_wready, p_bvalid, p_bready;
    reg            p_arvalid, p_arready, p_rvalid, p_rready;
    reg [31:0]     p_awaddr, p_araddr, p_wdata, p_rdata;
    reg [7:0]      p_awlen, p_arlen;
    reg [3:0]      p_wstrb;
    reg            p_wlast, p_rlast;
    reg [1:0]      p_bresp, p_rresp;
    reg [ID_W-1:0] p_awid, p_arid, p_bid, p_rid;

    // Rastreamento de transacoes
    reg        rd_open;       // AR aceito, RLAST ainda nao
    reg [7:0]  rd_len;
    integer    rd_beat;
    reg        aw_open;       // AW aceito, B ainda nao
    reg [7:0]  aw_len;
    reg        w_closed;      // WLAST ja aceito para a escrita corrente
    integer    w_beat;        // beats de W na escrita corrente
    integer    w_len_seen;    // beats do burst W ja fechado (W antes de AW)

    wire aw_hs = awvalid & awready;
    wire w_hs  = wvalid  & wready;
    wire b_hs  = bvalid  & bready;
    wire ar_hs = arvalid & arready;
    wire r_hs  = rvalid  & rready;

    function crosses_4k;
        input [31:0] addr;
        input [7:0]  len;
        reg   [13:0] end_off;
        begin
            end_off    = {2'b00, addr[11:0]} + (({6'd0, len} + 14'd1) << 2);
            crosses_4k = (end_off > 14'd4096);
        end
    endfunction

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            p_awvalid <= 1'b0; p_wvalid <= 1'b0; p_bvalid <= 1'b0;
            p_arvalid <= 1'b0; p_rvalid <= 1'b0;
            p_awready <= 1'b0; p_wready <= 1'b0; p_bready <= 1'b0;
            p_arready <= 1'b0; p_rready <= 1'b0;
            rd_open   <= 1'b0; rd_len <= 8'd0; rd_beat <= 0;
            aw_open   <= 1'b0; aw_len <= 8'd0;
            w_closed  <= 1'b0; w_beat <= 0;   w_len_seen <= 0;
        end else begin
            // ---------------------------------------------------------
            // Estabilidade de VALID e payload (IHI0022E A3.2)
            // ---------------------------------------------------------
            if (p_awvalid && !p_awready) begin
                if (!awvalid) report("AWVALID caiu sem handshake");
                else if (awaddr != p_awaddr || awlen != p_awlen || awid != p_awid)
                    report("payload de AW mudou antes do handshake");
            end
            if (p_wvalid && !p_wready) begin
                if (!wvalid) report("WVALID caiu sem handshake");
                else if (wdata != p_wdata || wstrb != p_wstrb || wlast != p_wlast)
                    report("payload de W mudou antes do handshake");
            end
            if (p_bvalid && !p_bready) begin
                if (!bvalid) report("BVALID caiu sem handshake");
                else if (bresp != p_bresp || bid != p_bid)
                    report("payload de B mudou antes do handshake");
            end
            if (p_arvalid && !p_arready) begin
                if (!arvalid) report("ARVALID caiu sem handshake");
                else if (araddr != p_araddr || arlen != p_arlen || arid != p_arid)
                    report("payload de AR mudou antes do handshake");
            end
            if (p_rvalid && !p_rready) begin
                if (!rvalid) report("RVALID caiu sem handshake");
                else if (rdata != p_rdata || rresp != p_rresp || rlast != p_rlast || rid != p_rid)
                    report("payload de R mudou antes do handshake");
            end

            // ---------------------------------------------------------
            // Perfil (MAS 4.2)
            // ---------------------------------------------------------
            if (CHECK_PROFILE != 0) begin
                if (ar_hs) begin
                    if (arburst != 2'b01) report("ARBURST diferente de INCR");
                    if (arsize  != 3'b010) report("ARSIZE diferente de 4 bytes");
                    if (arlen   >  8'd15) report("ARLEN maior que 15");
                    if (araddr[1:0] != 2'b00) report("ARADDR desalinhado");
                    if (crosses_4k(araddr, arlen)) report("burst de leitura cruza 4 KB");
                end
                if (aw_hs) begin
                    if (awburst != 2'b01) report("AWBURST diferente de INCR");
                    if (awsize  != 3'b010) report("AWSIZE diferente de 4 bytes");
                    if (awlen   >  8'd15) report("AWLEN maior que 15");
                    if (awaddr[1:0] != 2'b00) report("AWADDR desalinhado");
                    if (crosses_4k(awaddr, awlen)) report("burst de escrita cruza 4 KB");
                end
            end

            // ---------------------------------------------------------
            // Leitura: 1 em andamento, beats = ARLEN + 1, RLAST no ultimo
            // ---------------------------------------------------------
            if (ar_hs) begin
                ar_count = ar_count + 1;
                if (rd_open && !(r_hs && rlast))
                    report("segunda leitura em andamento (outstanding > 1)");
            end
            if (r_hs) begin
                r_beats = r_beats + 1;
                if (!rd_open) begin
                    report("beat de R sem AR aceito");
                end else begin
                    if (rlast && (rd_beat != rd_len))
                        report("RLAST fora do ultimo beat");
                    if (!rlast && (rd_beat == rd_len))
                        report("ultimo beat de R sem RLAST");
                end
            end
            if (r_hs && rlast) begin
                rd_open <= 1'b0;
                rd_beat <= 0;
            end else if (r_hs) begin
                rd_beat <= rd_beat + 1;
            end
            if (ar_hs) begin
                rd_open <= 1'b1;
                rd_len  <= arlen;
                rd_beat <= 0;
            end

            // ---------------------------------------------------------
            // Escrita: 1 em andamento, beats = AWLEN + 1, B depois de tudo
            // ---------------------------------------------------------
            if (aw_hs) begin
                aw_count = aw_count + 1;
                if (aw_open)
                    report("segunda escrita em andamento (outstanding > 1)");
                // W inteiro chegou antes do AW: confere agora
                if (w_closed && (w_len_seen != awlen + 1))
                    report("numero de beats de W diferente de AWLEN + 1");
            end
            if (w_hs) begin
                w_beats = w_beats + 1;
                if (w_closed)
                    report("beat de W depois do WLAST, antes do B");
                if (aw_open || aw_hs) begin
                    if (wlast && (w_beat != (aw_hs ? awlen : aw_len)))
                        report("WLAST fora do ultimo beat");
                    if (!wlast && (w_beat == (aw_hs ? awlen : aw_len)))
                        report("ultimo beat de W sem WLAST");
                end
            end
            if (b_hs) begin
                b_count = b_count + 1;
                if (!aw_open) report("B sem AW aceito");
                if (!w_closed) report("B antes do WLAST");
            end

            if (w_hs && wlast) begin
                w_closed   <= 1'b1;
                w_len_seen <= w_beat + 1;
                w_beat     <= 0;
            end else if (w_hs) begin
                w_beat <= w_beat + 1;
            end
            if (aw_hs) begin
                aw_open <= 1'b1;
                aw_len  <= awlen;
            end
            if (b_hs) begin
                aw_open  <= 1'b0;
                w_closed <= 1'b0;
            end

            // Amostra para o proximo ciclo
            p_awvalid <= awvalid; p_awready <= awready; p_awaddr <= awaddr;
            p_awlen   <= awlen;   p_awid    <= awid;
            p_wvalid  <= wvalid;  p_wready  <= wready;  p_wdata  <= wdata;
            p_wstrb   <= wstrb;   p_wlast   <= wlast;
            p_bvalid  <= bvalid;  p_bready  <= bready;  p_bresp  <= bresp;
            p_bid     <= bid;
            p_arvalid <= arvalid; p_arready <= arready; p_araddr <= araddr;
            p_arlen   <= arlen;   p_arid    <= arid;
            p_rvalid  <= rvalid;  p_rready  <= rready;  p_rdata  <= rdata;
            p_rresp   <= rresp;   p_rlast   <= rlast;   p_rid    <= rid;
        end
    end

    // Ha transacao pendurada? (usado pelos testes de dreno)
    wire idle = !rd_open && !aw_open && !w_closed && (w_beat == 0);

endmodule

`default_nettype wire
