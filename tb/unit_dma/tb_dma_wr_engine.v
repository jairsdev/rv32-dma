`timescale 1ns/1ps
`default_nettype none

// TB-WR (MAS 16.2): dma_wr_engine + axi_rand_stall + axi_mem_model + modelo de C.
// Confere: nwords = 1 ... T, linha de C certa (c_row), cada palavra gravada
// exatamente uma vez, divisao em 4 KB, MAX_BURST pequeno (parametro), fila de
// C sob backpressure (+STALL), W inteiro antes do AW (+WFIRST) e BRESP de erro.
module tb_dma_wr_engine;

    parameter ARRAY_SIZE = 4;
    parameter MAX_BURST  = 16;

    localparam T  = ARRAY_SIZE;
    localparam IW = (T > 1) ? $clog2(T) : 1;
    localparam CW = $clog2(T + 1);

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        stall_en = 1'b0;
    reg        w_first  = 1'b0;
    reg [31:0] seed     = 32'd1;

    // ---------------------------------------------------------------
    // Comandos
    // ---------------------------------------------------------------
    localparam MAXC = 64;
    reg [31:0]   c_addr   [0:MAXC-1];
    reg [CW-1:0] c_nwords [0:MAXC-1];
    reg [IW-1:0] c_rowv   [0:MAXC-1];
    reg          c_chk    [0:MAXC-1];
    integer      n_cmds = 0, cmd_idx = 0, done_cnt = 0;

    wire          wr_cmd_valid  = (cmd_idx < n_cmds);
    wire          wr_cmd_ready;
    wire [31:0]   wr_cmd_addr   = c_addr[cmd_idx];
    wire [CW-1:0] wr_cmd_nwords = c_nwords[cmd_idx];
    wire [IW-1:0] wr_cmd_row    = c_rowv[cmd_idx];
    wire          wr_done, wr_idle, wr_err;
    reg           err_clr = 1'b0;

    always @(posedge clk) begin
        if (wr_cmd_valid && wr_cmd_ready) cmd_idx <= cmd_idx + 1;
        if (wr_done) done_cnt <= done_cnt + 1;
    end

    // ---------------------------------------------------------------
    // Modelo da leitura de C: valor = f(linha, coluna), 1 ciclo de latencia
    // ---------------------------------------------------------------
    wire          c_rd;
    wire [IW-1:0] c_row, c_col;
    reg  [31:0]   c_rdata = 32'd0;

    function [31:0] c_val;
        input integer row, col;
        begin
            c_val = 32'hC000_0000 | (row << 8) | col;
        end
    endfunction

    always @(posedge clk)
        if (c_rd) c_rdata <= c_val(c_row, c_col);

    // ---------------------------------------------------------------
    // AXI
    // ---------------------------------------------------------------
    wire [31:0] m_awaddr, m_wdata, s_awaddr, s_wdata;
    wire [7:0]  m_awlen, s_awlen;
    wire [3:0]  m_wstrb, s_wstrb;
    wire [2:0]  s_awsize;
    wire [1:0]  s_awburst, s_bresp, m_bresp;
    wire [0:0]  s_awid, s_bid, m_bid;
    wire        m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
    wire        s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready;

    // Canal de leitura sem uso
    wire [0:0]  s_arid, s_rid, m_rid;
    wire [31:0] s_araddr, s_rdata, m_rdata;
    wire [7:0]  s_arlen;
    wire [2:0]  s_arsize;
    wire [1:0]  s_arburst, s_rresp, m_rresp;
    wire        s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;
    wire        m_arready, m_rlast, m_rvalid;

    dma_wr_engine #(
        .ARRAY_SIZE (T),
        .MAX_BURST  (MAX_BURST)
    ) u_dut (
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
        .err_clr       (err_clr),
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

    axi_checker #(.ID_W(1), .NAME("M_WR")) u_chk (
        .clk(clk), .rst_n(rst_n),
        .awid(1'b0), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(3'b010), .awburst(2'b01),
        .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(1'b0), .araddr(32'd0), .arlen(8'd0), .arsize(3'b010), .arburst(2'b01),
        .arvalid(1'b0), .arready(1'b0),
        .rid(1'b0), .rdata(32'd0), .rresp(2'b00), .rlast(1'b0), .rvalid(1'b0), .rready(1'b0)
    );

    axi_rand_stall #(.ID_W(1)) u_stall (
        .clk(clk), .rst_n(rst_n), .enable(stall_en), .seed(seed),
        .m_awid(1'b0), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(3'b010),
        .m_awburst(2'b01), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arid(1'b0), .m_araddr(32'd0), .m_arlen(8'd0), .m_arsize(3'b010), .m_arburst(2'b01),
        .m_arvalid(1'b0), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rvalid(m_rvalid), .m_rready(1'b0),
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

    axi_mem_model #(.ID_W(1)) u_mem (
        .clk(clk), .rst_n(rst_n), .w_first(w_first),
        .awid(s_awid), .awaddr(s_awaddr), .awlen(s_awlen), .awsize(s_awsize),
        .awburst(s_awburst), .awvalid(s_awvalid), .awready(s_awready),
        .wdata(s_wdata), .wstrb(s_wstrb), .wlast(s_wlast), .wvalid(s_wvalid), .wready(s_wready),
        .bid(s_bid), .bresp(s_bresp), .bvalid(s_bvalid), .bready(s_bready),
        .arid(s_arid), .araddr(s_araddr), .arlen(s_arlen), .arsize(s_arsize),
        .arburst(s_arburst), .arvalid(s_arvalid), .arready(s_arready),
        .rid(s_rid), .rdata(s_rdata), .rresp(s_rresp), .rlast(s_rlast), .rvalid(s_rvalid),
        .rready(s_rready)
    );

    // Cobertura: transicao W_ADDR -> W_RESP (W inteiro aceito antes do AW)
    integer n_addr_to_resp = 0;
    always @(posedge clk)
        if (rst_n && u_dut.state_q == 2'd1 && u_dut.state_d == 2'd3)
            n_addr_to_resp = n_addr_to_resp + 1;

    // ---------------------------------------------------------------
    // Sequencia
    // ---------------------------------------------------------------
    integer errors = 0;

    task add_cmd;
        input [31:0] addr;
        input integer nwords;
        input integer row;
        input        chk;
        begin
            c_addr[n_cmds]   = addr;
            c_nwords[n_cmds] = nwords;
            c_rowv[n_cmds]   = row;
            c_chk[n_cmds]    = chk;
            n_cmds = n_cmds + 1;
        end
    endtask

    task wait_all;
        integer guard;
        begin
            guard = 0;
            while ((done_cnt < n_cmds || !wr_idle) && guard < 100000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 100000) begin
                errors = errors + 1;
                $display("FALHA: timeout (%0d de %0d linhas)", done_cnt, n_cmds);
            end
        end
    endtask

    // Confere a memoria: palavras dos comandos com chk = 1 gravadas uma vez
    // com o valor certo; nenhuma outra palavra da DMEM escrita
    integer expected_writes [0:16383];

    task check_mem;
        integer i, w, idx;
        begin
            for (i = 0; i < 16384; i = i + 1) expected_writes[i] = 0;
            for (i = 0; i < n_cmds; i = i + 1)
                if (c_chk[i])
                    for (w = 0; w < c_nwords[i]; w = w + 1) begin
                        idx = (c_addr[i][15:2] + w) % 16384;
                        expected_writes[idx] = expected_writes[idx] + 1;
                        if (u_mem.mem[idx] !== c_val(c_rowv[i], w)) begin
                            errors = errors + 1;
                            $display("FALHA cmd %0d palavra %0d (%h): %h, esperado %h",
                                     i, w, c_addr[i] + 4 * w, u_mem.mem[idx], c_val(c_rowv[i], w));
                        end
                    end
            for (i = 0; i < 16384; i = i + 1)
                if (u_mem.wr_count[i] != expected_writes[i]) begin
                    errors = errors + 1;
                    $display("FALHA: palavra %h escrita %0d vezes, esperado %0d",
                             32'h1000_0000 + 4 * i, u_mem.wr_count[i], expected_writes[i]);
                end
        end
    endtask

    integer i, nw;
    initial begin
        if ($test$plusargs("STALL"))  stall_en = 1'b1;
        if ($test$plusargs("WFIRST")) w_first  = 1'b1;
        if ($value$plusargs("SEED=%d", seed)) ;

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        @(negedge clk);

        // 1. nwords = 1 ... T em linhas seguidas, linhas de C variadas
        for (i = 0; i < 3; i = i + 1)
            for (nw = 1; nw <= T; nw = nw + 1)
                add_cmd(32'h1000_2000 + 64 * (nw + 10 * i), nw, (nw + i) % T, 1'b1);

        // 2. Linha que cruza 4 KB: 2 segmentos
        add_cmd(32'h1000_3000 - 4 * (T / 2), T, T - 1, 1'b1);
        if (T == 8) add_cmd(32'h1000_4000 - 4, 8, 3, 1'b1);

        wait_all;

        // 3. BRESP de erro: fora da DMEM -> SLVERR -> wr_err
        if (wr_err !== 1'b0) begin
            errors = errors + 1;
            $display("FALHA: wr_err antes do erro");
        end
        @(negedge clk);
        add_cmd(32'h1002_0000, T, 0, 1'b0);
        wait_all;
        if (wr_err !== 1'b1) begin
            errors = errors + 1;
            $display("FALHA: wr_err nao subiu com SLVERR");
        end
        @(posedge clk); err_clr <= 1'b1;
        @(posedge clk); err_clr <= 1'b0;
        @(posedge clk);
        if (wr_err !== 1'b0) begin
            errors = errors + 1;
            $display("FALHA: err_clr nao limpou wr_err");
        end

        // 4. Continua funcionando depois do erro
        @(negedge clk);
        add_cmd(32'h1000_5000, T, 1, 1'b1);
        wait_all;

        repeat (5) @(posedge clk);
        check_mem;
        if (u_chk.violations != 0) begin
            errors = errors + 1;
            $display("FALHA: %0d violacoes do axi_checker", u_chk.violations);
        end

        if (w_first && n_addr_to_resp == 0) begin
            errors = errors + 1;
            $display("FALHA: caminho W_ADDR -> W_RESP nao exercitado com WFIRST");
        end

        if (errors == 0)
            $display("TB_DMA_WR_ENGINE T=%0d MAX_BURST=%0d STALL=%0d WFIRST=%0d: PASS (%0d linhas, %0d AW)",
                     T, MAX_BURST, stall_en, w_first, n_cmds, u_chk.aw_count);
        else
            $display("TB_DMA_WR_ENGINE T=%0d MAX_BURST=%0d STALL=%0d WFIRST=%0d: FAIL (%0d)",
                     T, MAX_BURST, stall_en, w_first, errors);
        $finish;
    end

endmodule

`default_nettype wire
