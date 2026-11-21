`timescale 1ns/1ps
`default_nettype none

// TB-MEM (MAS 16.2): axi_mem_ctrl sozinho, com um master escrito aqui.
//   master do TB -> axi_checker (m) -> axi_rand_stall -> axi_checker (s) -> axi_mem_ctrl
// O master tem tarefas proprias porque precisa de coisas que o axi_master_bfm
// nao faz: dado e WSTRB por beat, AxBURST diferente de INCR, todos os beats de
// R guardados e o ciclo de cada handshake (medicao de L e W_OV).
// A memoria do DUT e comparada com uma copia de referencia (golden) mantida aqui.
// Os checkers rodam com CHECK_PROFILE = 0 porque o teste 6 manda de proposito
// pedidos fora do perfil; o resto das regras (handshake, beats, LAST, B depois
// de WLAST, 1 leitura + 1 escrita em andamento) continua conferido.
//
// Testes:
//   1. bursts de 1 a 16 beats (escrita e releitura), ID = len % 4
//   2. WSTRB parcial: os 16 padroes em 1 beat e um burst com strobe por beat
//   3. leitura de 1 beat por ciclo e escrita de 1 beat por ciclo   (sem +STALL)
//   4. medicao de L (MAS 4.4 e 7.2)                                  (sem +STALL)
//   5. medicao de W_OV (MAS 7.2)                                     (sem +STALL)
//   6. SLVERR fora do perfil e fora da faixa, burst inteiro, memoria intacta
//   7. addr[31:28] nao e decodificado
//   8. AR e AW pendentes juntos: os dois terminam, um depois do outro
// Plusargs: +STALL +SEED=<s> (backpressure aleatoria), +VCD=<arq>
module tb_axi_mem_ctrl;

    localparam ID_W      = 2;
    localparam MEM_WORDS = 16384;
    localparam [31:0] BASE = 32'h1000_0000;

    localparam [1:0] OKAY = 2'b00, SLVERR = 2'b10;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // contador de ciclos, lido pelas tarefas na borda de descida
    integer cyc = 0;
    always @(posedge clk) cyc = cyc + 1;

    reg        stall_en = 1'b0;
    reg [31:0] seed     = 32'd1;

    // =================================================================
    // Master do TB
    // =================================================================
    reg  [ID_W-1:0] awid = 0, arid = 0;
    reg  [31:0]     awaddr = 0, araddr = 0, wdata = 0;
    reg  [7:0]      awlen = 0, arlen = 0;
    reg  [2:0]      awsize = 3'b010, arsize = 3'b010;
    reg  [1:0]      awburst = 2'b01, arburst = 2'b01;
    reg  [3:0]      wstrb = 4'hF;
    reg             awvalid = 0, wvalid = 0, wlast = 0, bready = 0, arvalid = 0, rready = 0;
    wire            awready, wready, bvalid, arready, rvalid, rlast;
    wire [ID_W-1:0] bid, rid;
    wire [1:0]      bresp, rresp;
    wire [31:0]     rdata;

    // lado do DUT
    wire [ID_W-1:0] s_awid, s_bid, s_arid, s_rid;
    wire [31:0]     s_awaddr, s_wdata, s_araddr, s_rdata;
    wire [7:0]      s_awlen, s_arlen;
    wire [2:0]      s_awsize, s_arsize;
    wire [1:0]      s_awburst, s_arburst, s_bresp, s_rresp;
    wire [3:0]      s_wstrb;
    wire            s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready;
    wire            s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;

    axi_checker #(.ID_W(ID_W), .CHECK_PROFILE(0), .NAME("mem_m")) u_chk_m (
        .clk(clk), .rst_n(rst_n),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
    );

    axi_rand_stall #(.ID_W(ID_W)) u_stall (
        .clk(clk), .rst_n(rst_n), .enable(stall_en), .seed(seed),
        .m_awid(awid), .m_awaddr(awaddr), .m_awlen(awlen), .m_awsize(awsize),
        .m_awburst(awburst), .m_awvalid(awvalid), .m_awready(awready),
        .m_wdata(wdata), .m_wstrb(wstrb), .m_wlast(wlast), .m_wvalid(wvalid), .m_wready(wready),
        .m_bid(bid), .m_bresp(bresp), .m_bvalid(bvalid), .m_bready(bready),
        .m_arid(arid), .m_araddr(araddr), .m_arlen(arlen), .m_arsize(arsize),
        .m_arburst(arburst), .m_arvalid(arvalid), .m_arready(arready),
        .m_rid(rid), .m_rdata(rdata), .m_rresp(rresp), .m_rlast(rlast),
        .m_rvalid(rvalid), .m_rready(rready),
        .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize),
        .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid),
        .s_wready(s_wready),
        .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize),
        .s_arburst(s_arburst), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast),
        .s_rvalid(s_rvalid), .s_rready(s_rready)
    );

    axi_checker #(.ID_W(ID_W), .CHECK_PROFILE(0), .NAME("mem_s")) u_chk_s (
        .clk(clk), .rst_n(rst_n),
        .awid(s_awid), .awaddr(s_awaddr), .awlen(s_awlen), .awsize(s_awsize), .awburst(s_awburst),
        .awvalid(s_awvalid), .awready(s_awready),
        .wdata(s_wdata), .wstrb(s_wstrb), .wlast(s_wlast), .wvalid(s_wvalid), .wready(s_wready),
        .bid(s_bid), .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
        .arid(s_arid), .araddr(s_araddr), .arlen(s_arlen), .arsize(s_arsize), .arburst(s_arburst),
        .arvalid(s_arvalid), .arready(s_arready),
        .rid(s_rid), .rdata(s_rdata), .rresp(s_rresp), .rlast(s_rlast), .rvalid(s_rvalid),
        .rready(s_rready)
    );

    axi_mem_ctrl #(.ID_W(ID_W), .MEM_WORDS(MEM_WORDS)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .awid(s_awid), .awaddr(s_awaddr), .awlen(s_awlen), .awsize(s_awsize),
        .awburst(s_awburst), .awvalid(s_awvalid), .awready(s_awready),
        .wdata(s_wdata), .wstrb(s_wstrb), .wlast(s_wlast), .wvalid(s_wvalid), .wready(s_wready),
        .bid(s_bid), .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
        .arid(s_arid), .araddr(s_araddr), .arlen(s_arlen), .arsize(s_arsize),
        .arburst(s_arburst), .arvalid(s_arvalid), .arready(s_arready),
        .rid(s_rid), .rdata(s_rdata), .rresp(s_rresp), .rlast(s_rlast), .rvalid(s_rvalid),
        .rready(s_rready)
    );

    // =================================================================
    // Referencia e apoio
    // =================================================================
    reg [31:0] golden [0:MEM_WORDS-1];
    integer    errors = 0;
    integer    checks = 0;

    task fail;
        input [8*96-1:0] msg;
        begin
            errors = errors + 1;
            $display("[%0t] FALHA: %0s", $time, msg);
        end
    endtask

    task expect_eq;
        input [8*64-1:0] what;
        input integer    got, exp;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("[%0t] FALHA: %0s = %0d, esperado %0d", $time, what, got, exp);
            end
        end
    endtask

    // Toda a DMEM do DUT tem de bater com a referencia
    task check_mem_all;
        input [8*48-1:0] name;
        integer i, n;
        begin
            n = 0;
            for (i = 0; i < MEM_WORDS; i = i + 1)
                if (u_dut.u_ram.mem[i] !== golden[i]) begin
                    if (n < 5)
                        $display("  %0s: mem[%0d] = %h, esperado %h", name, i, u_dut.u_ram.mem[i], golden[i]);
                    n = n + 1;
                end
            checks = checks + 1;
            if (n != 0) begin
                errors = errors + 1;
                $display("[%0t] FALHA: %0s: %0d palavras diferentes da referencia", $time, name, n);
            end
        end
    endtask

    // =================================================================
    // Escrita: len+1 beats com wbuf/sbuf, AW e W juntos, BREADY desde o inicio
    // =================================================================
    reg [31:0]      wbuf [0:15];
    reg [3:0]       sbuf [0:15];
    integer         w_start_cyc, w_aw_cyc, w_first_cyc, w_last_cyc, w_b_cyc, w_nbeats;
    reg [1:0]       w_resp;
    reg [ID_W-1:0]  w_bid;

    task wr_burst;
        input [31:0]     addr;
        input [7:0]      len;
        input [2:0]      size;
        input [1:0]      burst;
        input [ID_W-1:0] id;
        integer beat;
        reg     aw_done, w_done, b_done, aw_hs, w_hs;
        begin
            @(posedge clk);
            awid    <= id;
            awaddr  <= addr;
            awlen   <= len;
            awsize  <= size;
            awburst <= burst;
            awvalid <= 1'b1;
            wdata   <= wbuf[0];
            wstrb   <= sbuf[0];
            wlast   <= (len == 8'd0);
            wvalid  <= 1'b1;
            bready  <= 1'b1;
            aw_done = 1'b0; w_done = 1'b0; b_done = 1'b0;
            beat = 0; w_nbeats = 0; w_start_cyc = -1;
            while (!(aw_done && w_done && b_done)) begin
                @(negedge clk);
                if (w_start_cyc < 0) w_start_cyc = cyc;
                aw_hs = awvalid & awready;
                w_hs  = wvalid & wready;
                if (aw_hs) w_aw_cyc = cyc;
                if (w_hs) begin
                    if (w_nbeats == 0) w_first_cyc = cyc;
                    w_last_cyc = cyc;
                    w_nbeats   = w_nbeats + 1;
                end
                if (bvalid && bready) begin
                    b_done  = 1'b1;
                    w_resp  = bresp;
                    w_bid   = bid;
                    w_b_cyc = cyc;
                end
                @(posedge clk);
                if (aw_hs) begin
                    awvalid <= 1'b0;
                    aw_done = 1'b1;
                end
                if (w_hs) begin
                    if (beat == len) begin
                        wvalid <= 1'b0;
                        wlast  <= 1'b0;
                        w_done = 1'b1;
                    end else begin
                        beat = beat + 1;
                        wdata <= wbuf[beat];
                        wstrb <= sbuf[beat];
                        wlast <= (beat == len);
                    end
                end
                if (b_done) bready <= 1'b0;
                if (cyc - w_start_cyc > 2000) begin
                    fail("timeout na escrita");
                    awvalid <= 1'b0; wvalid <= 1'b0; bready <= 1'b0;
                    aw_done = 1'b1; w_done = 1'b1; b_done = 1'b1;
                end
            end
        end
    endtask

    // Atualiza a referencia com uma escrita INCR de 4 bytes aceita com OKAY
    task ref_write;
        input [31:0] addr;
        input [7:0]  len;
        integer b, idx;
        begin
            for (b = 0; b <= len; b = b + 1) begin
                idx = (addr[15:2] + b) % MEM_WORDS;
                if (sbuf[b][0]) golden[idx][7:0]   = wbuf[b][7:0];
                if (sbuf[b][1]) golden[idx][15:8]  = wbuf[b][15:8];
                if (sbuf[b][2]) golden[idx][23:16] = wbuf[b][23:16];
                if (sbuf[b][3]) golden[idx][31:24] = wbuf[b][31:24];
            end
        end
    endtask

    // =================================================================
    // Leitura: guarda todos os beats; RREADY desde o ARVALID
    // =================================================================
    reg [31:0] rbuf  [0:15];
    reg [1:0]  rrbuf [0:15];
    integer    r_n, r_start_cyc, r_ar_cyc, r_first_cyc, r_last_cyc, r_bad_last, r_bad_id;

    task rd_burst;
        input [31:0]     addr;
        input [7:0]      len;
        input [2:0]      size;
        input [1:0]      burst;
        input [ID_W-1:0] id;
        reg ar_hs, done;
        begin
            @(posedge clk);
            arid    <= id;
            araddr  <= addr;
            arlen   <= len;
            arsize  <= size;
            arburst <= burst;
            arvalid <= 1'b1;
            rready  <= 1'b1;
            done = 1'b0; r_n = 0; r_start_cyc = -1; r_bad_last = 0; r_bad_id = 0;
            while (!done) begin
                @(negedge clk);
                if (r_start_cyc < 0) r_start_cyc = cyc;
                ar_hs = arvalid & arready;
                if (ar_hs) r_ar_cyc = cyc;
                if (rvalid && rready) begin
                    if (r_n == 0) r_first_cyc = cyc;
                    r_last_cyc = cyc;
                    if (r_n < 16) begin
                        rbuf[r_n]  = rdata;
                        rrbuf[r_n] = rresp;
                    end
                    if (rid !== id) r_bad_id = r_bad_id + 1;
                    if (rlast !== (r_n == len)) r_bad_last = r_bad_last + 1;
                    r_n = r_n + 1;
                    if (rlast || r_n > len) done = 1'b1;
                end
                @(posedge clk);
                if (ar_hs) arvalid <= 1'b0;
                if (cyc - r_start_cyc > 2000) begin
                    fail("timeout na leitura");
                    arvalid <= 1'b0;
                    done = 1'b1;
                end
            end
            rready <= 1'b0;
        end
    endtask

    // Confere a leitura INCR de 4 bytes contra a referencia
    task check_read;
        input [31:0]     addr;
        input [7:0]      len;
        input [ID_W-1:0] id;
        integer b, idx;
        begin
            expect_eq("beats de R", r_n, len + 1);
            expect_eq("RLAST fora do ultimo beat", r_bad_last, 0);
            expect_eq("RID diferente do ARID", r_bad_id, 0);
            for (b = 0; b <= len && b < 16; b = b + 1) begin
                idx = (addr[15:2] + b) % MEM_WORDS;
                checks = checks + 1;
                if (rbuf[b] !== golden[idx] || rrbuf[b] !== OKAY) begin
                    errors = errors + 1;
                    $display("[%0t] FALHA: leitura %h beat %0d: %h/%b, esperado %h/OKAY",
                             $time, addr, b, rbuf[b], rrbuf[b], golden[idx]);
                end
            end
        end
    endtask

    task check_write_ok;
        input [7:0]      len;
        input [ID_W-1:0] id;
        begin
            expect_eq("beats de W aceitos", w_nbeats, len + 1);
            expect_eq("BRESP", w_resp, OKAY);
            expect_eq("BID", w_bid, id);
        end
    endtask

    task fill_wbuf;
        input [3:0] strb;
        integer b;
        begin
            for (b = 0; b < 16; b = b + 1) begin
                wbuf[b] = $random;
                sbuf[b] = strb;
            end
        end
    endtask

    // =================================================================
    // Testes
    // =================================================================
    integer    i, len, s, it, l_arv, l_hs, w_ov, diff, t_aw, t_ar;
    integer    n_aw_first = 0, n_ar_first = 0;
    reg [31:0] a, a2, v;
    reg [8*32-1:0] vcd_file;

    // Pedido fora do perfil: leitura e escrita, com o burst inteiro respondido com SLVERR
    task err_case;
        input [31:0] addr;
        input [7:0]  len;
        input [2:0]  size;
        input [1:0]  burst;
        integer b;
        begin
            rd_burst(addr, len, size, burst, 2'd3);
            expect_eq("SLVERR: beats de R", r_n, len + 1);
            expect_eq("SLVERR: RLAST fora do ultimo beat", r_bad_last, 0);
            expect_eq("SLVERR: RID", r_bad_id, 0);
            for (b = 0; b <= len && b < 16; b = b + 1) begin
                checks = checks + 1;
                if (rrbuf[b] !== SLVERR || rbuf[b] !== 32'd0) begin
                    errors = errors + 1;
                    $display("[%0t] FALHA: leitura invalida %h (size %0d burst %0d) beat %0d: %h/%b",
                             $time, addr, size, burst, b, rbuf[b], rrbuf[b]);
                end
            end
            fill_wbuf(4'hF);
            wr_burst(addr, len, size, burst, 2'd2);
            expect_eq("SLVERR: beats de W consumidos", w_nbeats, len + 1);
            expect_eq("SLVERR: BRESP", w_resp, SLVERR);
            expect_eq("SLVERR: BID", w_bid, 2);
        end
    endtask

    initial begin : main
        if ($test$plusargs("STALL")) stall_en = 1'b1;
        if ($value$plusargs("SEED=%d", seed)) ;
        if ($value$plusargs("VCD=%s", vcd_file)) begin
            $dumpfile(vcd_file);
            $dumpvars(0, tb_axi_mem_ctrl);
        end

        // Memoria e referencia com o mesmo conteudo aleatorio
        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            v = $random;
            golden[i] = v;
            u_dut.u_ram.mem[i] = v;
        end

        repeat (5) @(posedge clk);
        rst_n <= 1'b1;
        repeat (3) @(posedge clk);

        // ---------------------------------------------------------
        // 1. Bursts de 1 a 16 beats
        // ---------------------------------------------------------
        for (len = 0; len < 16; len = len + 1) begin
            a = BASE + len * 32'h400 + 4 * ((len * 3) % 16);
            fill_wbuf(4'hF);
            wr_burst(a, len, 3'b010, 2'b01, len % 4);
            check_write_ok(len, len % 4);
            ref_write(a, len);
            rd_burst(a, len, 3'b010, 2'b01, (len + 1) % 4);
            check_read(a, len, (len + 1) % 4);
        end
        check_mem_all("teste 1");

        // ---------------------------------------------------------
        // 2. WSTRB parcial
        // ---------------------------------------------------------
        for (s = 0; s < 16; s = s + 1) begin
            a = BASE + 32'h5000 + 4 * s;
            wbuf[0] = 32'h1122_3344; sbuf[0] = 4'hF;
            wr_burst(a, 0, 3'b010, 2'b01, 0);
            check_write_ok(0, 0);
            ref_write(a, 0);
            wbuf[0] = 32'hAABB_CCDD; sbuf[0] = s;
            wr_burst(a, 0, 3'b010, 2'b01, 1);
            check_write_ok(0, 1);
            ref_write(a, 0);
            rd_burst(a, 0, 3'b010, 2'b01, 2);
            check_read(a, 0, 2);
        end
        // burst de 16 beats com um strobe diferente em cada beat
        a = BASE + 32'h5100;
        fill_wbuf(4'hF);
        for (i = 0; i < 16; i = i + 1) sbuf[i] = i;
        wr_burst(a, 15, 3'b010, 2'b01, 3);
        check_write_ok(15, 3);
        ref_write(a, 15);
        rd_burst(a, 15, 3'b010, 2'b01, 0);
        check_read(a, 15, 0);
        check_mem_all("teste 2");

        if (!stall_en) begin
            // -----------------------------------------------------
            // 3 e 4. Leitura: 1 beat por ciclo e latencia L
            //   L     = ciclos do ARVALID subir ate o 1o RVALID (como na MAS 4.4)
            //   L_HS  = ciclos do handshake de AR ate o 1o RVALID (MAS 12.2: 2)
            // -----------------------------------------------------
            a = BASE + 32'h6000;
            rd_burst(a, 15, 3'b010, 2'b01, 1);
            check_read(a, 15, 1);
            expect_eq("leitura: ciclos entre o 1o e o 16o beat", r_last_cyc - r_first_cyc, 15);
            l_arv = r_first_cyc - r_start_cyc;
            l_hs  = r_first_cyc - r_ar_cyc;
            expect_eq("leitura: handshake de AR ate o 1o RVALID", l_hs, 2);
            $display("MEDIDA L=%0d L_HS=%0d (leitura de 16 beats em %0d ciclos depois do 1o)",
                     l_arv, l_hs, r_last_cyc - r_first_cyc + 1);

            // -----------------------------------------------------
            // 3 e 5. Escrita: 1 beat por ciclo e custo fixo W_OV
            //   W_OV = (ciclos do AWVALID subir ate o handshake de B, inclusive) - beats
            // -----------------------------------------------------
            for (i = 0; i < 5; i = i + 1) begin
                len = (i == 0) ? 0 : (i == 1) ? 1 : (i == 2) ? 3 : (i == 3) ? 7 : 15;
                a = BASE + 32'h6400 + 32'h80 * i;
                fill_wbuf(4'hF);
                wr_burst(a, len, 3'b010, 2'b01, 0);
                check_write_ok(len, 0);
                ref_write(a, len);
                expect_eq("escrita: ciclos entre o 1o e o ultimo beat de W", w_last_cyc - w_first_cyc, len);
                w_ov = (w_b_cyc - w_start_cyc + 1) - (len + 1);
                $display("MEDIDA W_OV=%0d (burst de %0d beats: AWVALID no ciclo %0d, B no ciclo %0d)",
                         w_ov, len + 1, w_start_cyc, w_b_cyc);
            end
            check_mem_all("testes 3 a 5");
        end

        // ---------------------------------------------------------
        // 6. SLVERR: fora do perfil e fora da faixa, memoria intacta
        // ---------------------------------------------------------
        err_case(BASE + 32'h7000, 3, 3'b000, 2'b01);   // AxSIZE = 1 byte
        err_case(BASE + 32'h7000, 3, 3'b001, 2'b01);   // AxSIZE = 2 bytes
        err_case(BASE + 32'h7000, 3, 3'b011, 2'b01);   // AxSIZE = 8 bytes
        err_case(BASE + 32'h7000, 3, 3'b010, 2'b00);   // FIXED
        err_case(BASE + 32'h7000, 3, 3'b010, 2'b10);   // WRAP
        err_case(32'h1001_0000,    3, 3'b010, 2'b01);   // fora dos 64 KiB
        err_case(32'h1002_0000,    0, 3'b010, 2'b01);   // fora dos 64 KiB (teste 16.4-3)
        err_case(BASE + 32'hFFF0,  7, 3'b010, 2'b01);   // comeca dentro e termina fora
        check_mem_all("teste 6 (memoria intacta)");

        // ---------------------------------------------------------
        // 7. addr[31:28] nao e decodificado (quem separa os slaves e o xbar)
        // ---------------------------------------------------------
        wbuf[0] = 32'hC0FF_EE01; sbuf[0] = 4'hF;
        wr_burst(32'h2000_0100, 0, 3'b010, 2'b01, 0);
        check_write_ok(0, 0);
        ref_write(32'h2000_0100, 0);
        rd_burst(32'h1000_0100, 0, 3'b010, 2'b01, 0);
        check_read(32'h1000_0100, 0, 0);
        rd_burst(32'h0000_0100, 0, 3'b010, 2'b01, 0);
        check_read(32'h0000_0100, 0, 0);

        // ---------------------------------------------------------
        // 8. AR e AW pendentes no mesmo ciclo
        // ---------------------------------------------------------
        for (it = 0; it < 4; it = it + 1) begin
            a  = BASE + 32'h8000 + 32'h100 * it;     // escrita
            a2 = BASE + 32'h9000 + 32'h100 * it;     // leitura
            fill_wbuf(4'hF);
            fork
                wr_burst(a, 15, 3'b010, 2'b01, 1);
                rd_burst(a2, 15, 3'b010, 2'b01, 2);
            join
            // guarda os ciclos antes da releitura, que sobrescreve os r_*
            t_aw = w_aw_cyc;
            t_ar = r_ar_cyc;
            check_write_ok(15, 1);
            check_read(a2, 15, 2);
            ref_write(a, 15);
            rd_burst(a, 15, 3'b010, 2'b01, 3);
            check_read(a, 15, 3);
            if (!stall_en) begin
                // uma transacao por vez: o segundo comando so entra depois dos 16 beats
                // do primeiro irem para a SRAM, e entra logo em seguida
                diff = (t_aw > t_ar) ? (t_aw - t_ar) : (t_ar - t_aw);
                checks = checks + 1;
                if (diff < 16 || diff > 20) begin
                    errors = errors + 1;
                    $display("[%0t] FALHA: AR/AW juntos: %0d ciclos entre os handshakes (esperado 16 a 20)",
                             $time, diff);
                end
                if (t_aw < t_ar) n_aw_first = n_aw_first + 1;
                else             n_ar_first = n_ar_first + 1;
                $display("AR/AW juntos, rodada %0d: %0s primeiro, o outro %0d ciclos depois",
                         it, (t_aw < t_ar) ? "AW" : "AR", diff);
            end
        end
        // round-robin: nas 4 rodadas cada lado tem de ganhar pelo menos uma vez
        if (!stall_en) begin
            checks = checks + 1;
            if (n_aw_first == 0 || n_ar_first == 0) begin
                errors = errors + 1;
                $display("[%0t] FALHA: sem alternancia entre AR e AW (AW primeiro %0d vezes, AR %0d)",
                         $time, n_aw_first, n_ar_first);
            end
        end
        check_mem_all("teste 8");

        // ---------------------------------------------------------
        // Fim
        // ---------------------------------------------------------
        repeat (10) @(posedge clk);
        expect_eq("violacoes do axi_checker (master)", u_chk_m.violations, 0);
        expect_eq("violacoes do axi_checker (DUT)", u_chk_s.violations, 0);

        if (errors == 0)
            $display("TB_MEM STALL=%0d SEED=%0d: PASS (%0d checagens)", stall_en, seed, checks);
        else
            $display("TB_MEM STALL=%0d SEED=%0d: FAIL (%0d erros)", stall_en, seed, errors);
        $display("RESULT: %0s", (errors == 0) ? "PASS" : "FAIL");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FALHA: timeout global");
        $display("RESULT: FAIL");
        $finish;
    end

endmodule

`default_nettype wire
