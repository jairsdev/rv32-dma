`timescale 1ns/1ps
`default_nettype none

// TB-RD (MAS 16.2): dma_rd_engine + axi_rand_stall + DMEM (axi_mem_ctrl com
// MEM_CTRL definido, axi_mem_model sem ele).
// Entrega linhas em ciclos seguidos e confere, a cada rd_done:
//   - a ordem dos rd_done (igual a dos comandos);
//   - WPR palavras escritas no buffer certo (sel, bank, row);
//   - bytes alinhados (off = 2 com T = 2) e padding zerado (nbytes 0 ... T);
// Cobre ainda a divisao em 4 KB (T = 8), MAX_BURST pequeno (parametro) e
// RRESP de erro (rd_err e err_clr).
// Plusargs: +STALL=1 liga backpressure aleatoria; +SEED=n.
module tb_dma_rd_engine;

    parameter ARRAY_SIZE = 4;
    parameter MAX_BURST  = 16;

    localparam T   = ARRAY_SIZE;
    localparam IW  = (T > 1) ? $clog2(T) : 1;
    localparam CW  = $clog2(T + 1);
    localparam WPR = (T + 3) / 4;
    localparam WW  = (WPR > 1) ? $clog2(WPR) : 1;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        stall_en = 1'b0;
    reg [31:0] seed = 32'd1;

    // ---------------------------------------------------------------
    // Comandos
    // ---------------------------------------------------------------
    localparam MAXC = 256;
    reg [31:0]   c_addr   [0:MAXC-1];
    reg [CW-1:0] c_nbytes [0:MAXC-1];
    reg          c_sel    [0:MAXC-1];
    reg          c_bank   [0:MAXC-1];
    reg [IW-1:0] c_row    [0:MAXC-1];
    reg          c_chk    [0:MAXC-1];   // conferir os dados?
    integer      n_cmds = 0;
    integer      cmd_idx = 0;
    integer      done_idx = 0;

    wire          rd_cmd_valid = (cmd_idx < n_cmds);
    wire          rd_cmd_ready;
    wire [31:0]   rd_cmd_addr   = c_addr[cmd_idx];
    wire [CW-1:0] rd_cmd_nbytes = c_nbytes[cmd_idx];
    wire          rd_cmd_sel    = c_sel[cmd_idx];
    wire          rd_cmd_bank   = c_bank[cmd_idx];
    wire [IW-1:0] rd_cmd_row    = c_row[cmd_idx];
    wire          rd_done, rd_idle, rd_err;
    reg           err_clr = 1'b0;

    always @(posedge clk)
        if (rd_cmd_valid && rd_cmd_ready) cmd_idx <= cmd_idx + 1;

    // ---------------------------------------------------------------
    // AXI
    // ---------------------------------------------------------------
    wire [31:0] m_araddr, s_araddr, m_rdata, s_rdata;
    wire [7:0]  m_arlen, s_arlen;
    wire [2:0]  s_arsize;
    wire [1:0]  s_arburst, m_rresp, s_rresp;
    wire [0:0]  s_arid, m_rid, s_rid;
    wire        m_arvalid, m_arready, s_arvalid, s_arready;
    wire        m_rlast, m_rvalid, m_rready, s_rlast, s_rvalid, s_rready;

    // Canal de escrita sem uso
    wire [0:0]  s_awid, s_bid, m_bid;
    wire [31:0] s_awaddr, s_wdata;
    wire [7:0]  s_awlen;
    wire [2:0]  s_awsize;
    wire [1:0]  s_awburst, s_bresp, m_bresp;
    wire [3:0]  s_wstrb;
    wire        s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready;
    wire        m_awready, m_wready, m_bvalid;

    // Porta do buffer
    wire          buf_a_we, buf_b_we, buf_bank;
    wire [IW-1:0] buf_row;
    wire [WW-1:0] buf_word;
    wire [31:0]   buf_wdata;

    dma_rd_engine #(
        .ARRAY_SIZE (T),
        .MAX_BURST  (MAX_BURST)
    ) u_dut (
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
        .err_clr       (err_clr),
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

    axi_checker #(.ID_W(1), .NAME("M_RD")) u_chk (
        .clk(clk), .rst_n(rst_n),
        .awid(1'b0), .awaddr(32'd0), .awlen(8'd0), .awsize(3'b010), .awburst(2'b01),
        .awvalid(1'b0), .awready(1'b0),
        .wdata(32'd0), .wstrb(4'hF), .wlast(1'b0), .wvalid(1'b0), .wready(1'b0),
        .bid(1'b0), .bresp(2'b00), .bvalid(1'b0), .bready(1'b0),
        .arid(1'b0), .araddr(m_araddr), .arlen(m_arlen), .arsize(3'b010), .arburst(2'b01),
        .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast),
        .rvalid(m_rvalid), .rready(m_rready)
    );

    axi_rand_stall #(.ID_W(1)) u_stall (
        .clk(clk), .rst_n(rst_n), .enable(stall_en), .seed(seed),
        .m_awid(1'b0), .m_awaddr(32'd0), .m_awlen(8'd0), .m_awsize(3'b010), .m_awburst(2'b01),
        .m_awvalid(1'b0), .m_awready(m_awready),
        .m_wdata(32'd0), .m_wstrb(4'hF), .m_wlast(1'b0), .m_wvalid(1'b0), .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(1'b0),
        .m_arid(1'b0), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(3'b010),
        .m_arburst(2'b01), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rvalid(m_rvalid), .m_rready(m_rready),
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

    // DMEM: axi_mem_ctrl (MEM=ctrl, define MEM_CTRL) ou axi_mem_model (MEM=model)
`ifdef MEM_CTRL
    axi_mem_ctrl #(.ID_W(1)) u_mem (
        .clk(clk), .rst_n(rst_n),
    `define MEM_ARR u_mem.u_ram.mem
`else
    axi_mem_model #(.ID_W(1)) u_mem (
        .clk(clk), .rst_n(rst_n), .w_first(1'b0),
    `define MEM_ARR u_mem.mem
`endif
        .awid(s_awid), .awaddr(s_awaddr), .awlen(s_awlen), .awsize(s_awsize),
        .awburst(s_awburst), .awvalid(s_awvalid), .awready(s_awready),
        .wdata(s_wdata), .wstrb(s_wstrb), .wlast(s_wlast), .wvalid(s_wvalid), .wready(s_wready),
        .bid(s_bid), .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
        .arid(s_arid), .araddr(s_araddr), .arlen(s_arlen), .arsize(s_arsize),
        .arburst(s_arburst), .arvalid(s_arvalid), .arready(s_arready),
        .rid(s_rid), .rdata(s_rdata), .rresp(s_rresp), .rlast(s_rlast), .rvalid(s_rvalid),
        .rready(s_rready)
    );

    // ---------------------------------------------------------------
    // Captura das escritas no buffer: [sel][bank][row][word]
    // ---------------------------------------------------------------
    reg [31:0] cap   [0:4*T*WPR-1];
    integer    wcnt  [0:4*T-1];       // escritas por linha desde o ultimo rd_done
    integer    errors = 0;

    function integer loc;
        input sel, bank;
        input integer row;
        begin
            loc = (sel * 2 + bank) * T + row;
        end
    endfunction

    // Palavra esperada w da linha (addr, nbytes)
    function [31:0] exp_word;
        input [31:0] addr;
        input integer nbytes;
        input integer w;
        integer l, col;
        reg [31:0] a, word;
        begin
            exp_word = 32'd0;
            for (l = 0; l < 4; l = l + 1) begin
                col = 4 * w + l;
                if (col < nbytes && col < T) begin
                    a    = addr + col;
                    word = `MEM_ARR[a[15:2]];
                    exp_word[8*l +: 8] = word[8*a[1:0] +: 8];
                end
            end
        end
    endfunction

    integer w, li;
    always @(posedge clk) begin
        if (rst_n) begin
            // rd_done do comando done_idx (pulso registrado: as escritas da
            // linha ja aconteceram nos ciclos anteriores)
            if (rd_done) begin
                li = loc(c_sel[done_idx], c_bank[done_idx], c_row[done_idx]);
                if (wcnt[li] != WPR) begin
                    errors = errors + 1;
                    $display("FALHA cmd %0d: %0d palavras escritas, esperado %0d",
                             done_idx, wcnt[li], WPR);
                end
                if (c_chk[done_idx]) begin
                    for (w = 0; w < WPR; w = w + 1)
                        if (cap[li * WPR + w] !== exp_word(c_addr[done_idx], c_nbytes[done_idx], w)) begin
                            errors = errors + 1;
                            $display("FALHA cmd %0d (addr %h nbytes %0d) palavra %0d: %h, esperado %h",
                                     done_idx, c_addr[done_idx], c_nbytes[done_idx], w,
                                     cap[li * WPR + w],
                                     exp_word(c_addr[done_idx], c_nbytes[done_idx], w));
                        end
                end
                wcnt[li] = 0;
                done_idx = done_idx + 1;
            end
            // Escrita no buffer neste ciclo
            if (buf_a_we || buf_b_we) begin
                li = loc(buf_b_we, buf_bank, buf_row);
                cap[li * WPR + buf_word] = buf_wdata;
                wcnt[li] = wcnt[li] + 1;
            end
        end
    end

    // ---------------------------------------------------------------
    // Sequencia de teste
    // ---------------------------------------------------------------
    integer slot = 0;     // gira (sel, bank, row) para nao sobrescrever cedo

    task add_cmd;
        input [31:0] addr;
        input integer nbytes;
        input        chk;
        begin
            c_addr[n_cmds]   = addr;
            c_nbytes[n_cmds] = nbytes;
            c_sel[n_cmds]    = slot[0];
            c_bank[n_cmds]   = slot[1];
            c_row[n_cmds]    = slot / 4;
            c_chk[n_cmds]    = chk;
            slot   = (slot + 1) % (4 * T);
            n_cmds = n_cmds + 1;
        end
    endtask

    task wait_all;
        integer guard;
        begin
            guard = 0;
            while ((done_idx < n_cmds || !rd_idle) && guard < 100000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 100000) begin
                errors = errors + 1;
                $display("FALHA: timeout esperando %0d linhas (feitas %0d)", n_cmds, done_idx);
            end
        end
    endtask

    integer i, nb, k, plus;
    initial begin
        if ($test$plusargs("STALL")) stall_en = 1'b1;
        if ($value$plusargs("SEED=%d", seed)) ;
        for (i = 0; i < 4 * T; i = i + 1) wcnt[i] = 0;
        #1;
        for (i = 0; i < 16384; i = i + 1)
            `MEM_ARR[i] = (i * 32'h9E37_79B1) ^ 32'hA5A5_5A5A;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        // Os lotes de comandos entram na borda de descida, longe da borda em
        // que o TB e o DUT avaliam o handshake (evita corrida de simulacao)
        @(negedge clk);

        // 1. nbytes = 0 ... T, enderecos alinhados (e off = 2 com T = 2)
        for (k = 0; k < 3; k = k + 1)
            for (nb = 0; nb <= T; nb = nb + 1) begin
                plus = (T == 2 && (nb + k) % 2 == 1) ? 2 : 0;
                add_cmd(32'h1000_1000 + 64 * (nb + 8 * k) + plus, nb, 1'b1);
            end

        // 2. Linhas que cruzam 4 KB (so possivel com 2 palavras por linha)
        if (T == 8) begin
            add_cmd(32'h1000_1FFC, 8, 1'b1);
            add_cmd(32'h1000_2FFC, 5, 1'b1);
            add_cmd(32'h1000_3FFC, 4, 1'b1);
        end

        // 3. Rajada de linhas de padding seguidas
        for (k = 0; k < 4; k = k + 1)
            add_cmd(32'h1000_0000, 0, 1'b1);

        wait_all;

        // 4. RRESP de erro: endereco fora da DMEM -> SLVERR -> rd_err
        if (rd_err !== 1'b0) begin
            errors = errors + 1;
            $display("FALHA: rd_err antes do erro");
        end
        @(negedge clk);
        add_cmd(32'h1002_0000, T, 1'b0);
        wait_all;
        if (rd_err !== 1'b1) begin
            errors = errors + 1;
            $display("FALHA: rd_err nao subiu com SLVERR");
        end
        @(posedge clk); err_clr <= 1'b1;
        @(posedge clk); err_clr <= 1'b0;
        @(posedge clk);
        if (rd_err !== 1'b0) begin
            errors = errors + 1;
            $display("FALHA: err_clr nao limpou rd_err");
        end

        // 5. Depois do erro o motor continua funcionando
        @(negedge clk);
        add_cmd(32'h1000_1100, T, 1'b1);
        wait_all;

        repeat (5) @(posedge clk);
        if (u_chk.violations != 0) begin
            errors = errors + 1;
            $display("FALHA: %0d violacoes do axi_checker", u_chk.violations);
        end

        if (errors == 0)
            $display("TB_DMA_RD_ENGINE T=%0d MAX_BURST=%0d STALL=%0d: PASS (%0d linhas, %0d AR)",
                     T, MAX_BURST, stall_en, n_cmds, u_chk.ar_count);
        else
            $display("TB_DMA_RD_ENGINE T=%0d MAX_BURST=%0d STALL=%0d: FAIL (%0d)",
                     T, MAX_BURST, stall_en, errors);
        $finish;
    end

endmodule

`undef MEM_ARR
`default_nettype wire
