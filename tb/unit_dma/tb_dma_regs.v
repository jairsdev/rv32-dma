`timescale 1ns/1ps
`default_nettype none

// TB-REGS (MAS 16.2): banco de registradores do DMA isolado.
// O TB faz o papel do dma_ctrl (ctrl_busy, ctrl_done, ctrl_error) e da malha
// (acc_active); o BFM faz o papel da CPU.
module tb_dma_regs;

    parameter ARRAY_SIZE = 4;
    parameter PINGPONG   = 1;

    localparam [31:0] BASE = 32'h4000_0000;
    localparam [31:0] CTRL = BASE + 32'h00, STATUS = BASE + 32'h04,
                      ADDR_A = BASE + 32'h08, ADDR_B = BASE + 32'h0C, ADDR_C = BASE + 32'h10,
                      DIM_M = BASE + 32'h14, DIM_N = BASE + 32'h18, DIM_K = BASE + 32'h1C,
                      CYCLES = BASE + 32'h20, INFO = BASE + 32'h24, CYC_COMPUTE = BASE + 32'h28;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    // AXI S1
    wire [1:0]  awid, bid, arid, rid;
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire [7:0]  awlen, arlen;
    wire [2:0]  awsize, arsize;
    wire [1:0]  awburst, arburst, bresp, rresp;
    wire [3:0]  wstrb;
    wire        awvalid, awready, wlast, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rlast, rvalid, rready;

    // Lado do controle
    reg         ctrl_busy = 0, ctrl_done = 0, ctrl_error = 0, acc_active = 0;
    reg  [3:0]  ctrl_err_code = 0;
    wire        start, soft_reset, irq;
    wire [31:0] addr_a, addr_b, addr_c;
    wire [15:0] dim_m, dim_n, dim_k;

    axi_master_bfm #(.ID_W(2)) u_bfm (
        .clk(clk), .rst_n(rst_n),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
    );

    axi_checker #(.ID_W(2), .CHECK_PROFILE(0), .NAME("S1")) u_chk (
        .clk(clk), .rst_n(rst_n),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
    );

    dma_regs #(
        .ARRAY_SIZE (ARRAY_SIZE),
        .PINGPONG   (PINGPONG)
    ) u_dut (
        .clk(clk), .rst_n(rst_n),
        .s_awid(awid), .s_awaddr(awaddr), .s_awlen(awlen), .s_awsize(awsize),
        .s_awburst(awburst), .s_awvalid(awvalid), .s_awready(awready),
        .s_wdata(wdata), .s_wstrb(wstrb), .s_wlast(wlast), .s_wvalid(wvalid), .s_wready(wready),
        .s_bid(bid), .s_bresp(bresp), .s_bvalid(bvalid), .s_bready(bready),
        .s_arid(arid), .s_araddr(araddr), .s_arlen(arlen), .s_arsize(arsize),
        .s_arburst(arburst), .s_arvalid(arvalid), .s_arready(arready),
        .s_rid(rid), .s_rdata(rdata), .s_rresp(rresp), .s_rlast(rlast), .s_rvalid(rvalid),
        .s_rready(rready),
        .start(start), .soft_reset(soft_reset),
        .addr_a(addr_a), .addr_b(addr_b), .addr_c(addr_c),
        .dim_m(dim_m), .dim_n(dim_n), .dim_k(dim_k),
        .ctrl_busy(ctrl_busy), .ctrl_done(ctrl_done), .ctrl_error(ctrl_error),
        .ctrl_err_code(ctrl_err_code), .acc_active(acc_active),
        .irq(irq)
    );

    // Contadores de pulsos
    integer n_start = 0, n_soft = 0;
    always @(posedge clk) begin
        if (start)      n_start = n_start + 1;
        if (soft_reset) n_soft  = n_soft + 1;
    end

    integer    errors = 0;
    reg [31:0] rd;
    reg [1:0]  resp;
    integer    nb;

    task check_rd;
        input [31:0]     addr;
        input [31:0]     exp;
        input [8*40-1:0] what;
        begin
            u_bfm.axi_read(addr, rd, resp);
            if (rd !== exp || resp !== 2'b00) begin
                errors = errors + 1;
                $display("FALHA %0s: lido %h resp %0d, esperado %h", what, rd, resp, exp);
            end
        end
    endtask

    task wr;
        input [31:0] addr;
        input [31:0] data;
        begin
            u_bfm.axi_write(addr, data, resp);
            if (resp !== 2'b00) begin
                errors = errors + 1;
                $display("FALHA escrita em %h: resp %0d", addr, resp);
            end
        end
    endtask

    task check;
        input            cond;
        input [8*48-1:0] what;
        begin
            if (!cond) begin
                errors = errors + 1;
                $display("FALHA: %0s", what);
            end
        end
    endtask

    integer i;
    localparam [31:0] INFO_EXP = {3'd0, (PINGPONG != 0), 4'd2, 8'd32, 8'd8, 8'(ARRAY_SIZE)};

    initial begin
        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // 1. Valores de reset
        check_rd(CTRL,   32'd0, "reset CTRL");
        check_rd(STATUS, 32'd0, "reset STATUS");
        check_rd(ADDR_A, 32'd0, "reset ADDR_A");
        check_rd(DIM_K,  32'd0, "reset DIM_K");
        check_rd(CYCLES, 32'd0, "reset CYCLES");
        check_rd(INFO,   INFO_EXP, "INFO");
        check_rd(CYC_COMPUTE, 32'd0, "reset CYC_COMPUTE");

        // 2. Leitura e escrita de configuracao
        wr(ADDR_A, 32'h1000_1000);
        wr(ADDR_B, 32'h1000_4002);           // [1:0] guardados (v2)
        wr(ADDR_C, 32'h1000_8000);
        wr(DIM_M, 32'hFFFF_0006);
        wr(DIM_N, 32'h0000_0007);
        wr(DIM_K, 32'h0000_0005);
        check_rd(ADDR_A, 32'h1000_1000, "ADDR_A");
        check_rd(ADDR_B, 32'h1000_4002, "ADDR_B com [1:0]");
        check_rd(ADDR_C, 32'h1000_8000, "ADDR_C");
        check_rd(DIM_M,  32'h0000_0006, "DIM_M so [15:0]");
        check_rd(DIM_N,  32'h0000_0007, "DIM_N");
        check_rd(DIM_K,  32'h0000_0005, "DIM_K");
        check(addr_b == 32'h1000_4002 && dim_m == 16'd6, "saidas para o dma_ctrl");

        // 3. WSTRB parcial
        wr(ADDR_C, 32'h1122_3344);
        u_bfm.axi_write_strb(ADDR_C, 32'hAABB_CCDD, 4'b0010, resp);
        check_rd(ADDR_C, 32'h1122_CC44, "WSTRB parcial");

        // 4. Offset nao mapeado e aliasing a cada 4 KiB
        wr(BASE + 32'h30, 32'hDEAD_BEEF);
        check_rd(BASE + 32'h30, 32'd0, "offset nao mapeado");
        check_rd(BASE + 32'h1008, 32'h1000_1000, "aliasing de ADDR_A");

        // 5. START: um pulso, CTRL le so IRQ_EN, contadores e status zerados
        n_start = 0;
        wr(CTRL, 32'h0000_0003);
        repeat (2) @(posedge clk);
        check(n_start == 1, "START gera exatamente 1 pulso");
        check_rd(CTRL, 32'h0000_0002, "CTRL le IRQ_EN sem START");

        // 6. Com BUSY: configuracao e START ignorados, IRQ_EN e SOFT_RESET aceitos
        @(posedge clk); ctrl_busy <= 1'b1;
        n_start = 0; n_soft = 0;
        wr(ADDR_A, 32'h1000_2000);
        wr(DIM_N,  32'h0000_0010);
        wr(CTRL,   32'h0000_0001);           // START e IRQ_EN = 0
        check_rd(ADDR_A, 32'h1000_1000, "ADDR_A bloqueado com BUSY");
        check_rd(DIM_N,  32'h0000_0007, "DIM_N bloqueado com BUSY");
        check(n_start == 0, "START ignorado com BUSY");
        check_rd(CTRL,   32'h0000_0000, "IRQ_EN aceito com BUSY");
        check_rd(STATUS, 32'h0000_0001, "STATUS.BUSY");
        wr(CTRL, 32'h0000_0006);             // SOFT_RESET + IRQ_EN
        repeat (2) @(posedge clk);
        check(n_soft == 1, "SOFT_RESET aceito com BUSY");
        @(posedge clk); ctrl_busy <= 1'b0;

        // 7. START + SOFT_RESET na mesma escrita: vale o SOFT_RESET
        n_start = 0; n_soft = 0;
        wr(CTRL, 32'h0000_0007);
        repeat (2) @(posedge clk);
        check(n_start == 0 && n_soft == 1, "START + SOFT_RESET: so SOFT_RESET");

        // 8. Contadores: 50 ciclos de BUSY, 20 de acc_active
        wr(CTRL, 32'h0000_0003);             // START (zera os contadores)
        @(posedge clk);
        ctrl_busy <= 1'b1;
        for (i = 0; i < 50; i = i + 1) begin
            acc_active <= (i >= 10 && i < 30);
            @(posedge clk);
        end
        ctrl_busy  <= 1'b0;
        acc_active <= 1'b0;
        @(posedge clk);
        check_rd(CYCLES,      32'd50, "CYCLES");
        check_rd(CYC_COMPUTE, 32'd20, "CYC_COMPUTE");

        // 9. ERROR/DONE, irq e W1C
        @(posedge clk);
        ctrl_error    <= 1'b1;
        ctrl_err_code <= 4'd3;
        @(posedge clk);
        ctrl_error    <= 1'b0;
        ctrl_done     <= 1'b1;
        @(posedge clk);
        ctrl_done     <= 1'b0;
        @(posedge clk);
        check(irq === 1'b1, "irq com DONE e IRQ_EN");
        check_rd(STATUS, 32'h0000_0036, "STATUS DONE|ERROR|ERR_CODE=3");
        wr(STATUS, 32'h0000_0002);           // W1C DONE
        check(irq === 1'b0, "irq cai com W1C de DONE");
        check_rd(STATUS, 32'h0000_0034, "W1C DONE");
        wr(STATUS, 32'h0000_0004);           // W1C ERROR
        check_rd(STATUS, 32'h0000_0030, "W1C ERROR (ERR_CODE e RO)");
        wr(CTRL, 32'h0000_0001);             // START zera ERR_CODE
        check_rd(STATUS, 32'h0000_0000, "START zera STATUS");

        // 10. Pedidos fora do perfil: SLVERR, sem efeito
        u_bfm.axi_read_burst(ADDR_A, 8'd3, 3'b010, resp, nb);
        check(resp == 2'b10 && nb == 4, "AR com ARLEN = 3: 4 beats SLVERR");
        u_bfm.axi_read_burst(ADDR_A, 8'd0, 3'b001, resp, nb);
        check(resp == 2'b10 && nb == 1, "AR com ARSIZE = 1: SLVERR");
        u_bfm.axi_write_burst(ADDR_A, 8'd2, 3'b010, resp);
        check(resp == 2'b10, "AW com AWLEN = 2: SLVERR");
        u_bfm.axi_write_burst(ADDR_A, 8'd0, 3'b000, resp);
        check(resp == 2'b10, "AW com AWSIZE = 0: SLVERR");
        check_rd(ADDR_A, 32'h1000_1000, "burst sem efeito");

        repeat (5) @(posedge clk);
        if (u_chk.violations != 0) begin
            errors = errors + 1;
            $display("FALHA: %0d violacoes do axi_checker", u_chk.violations);
        end

        if (errors == 0) $display("TB_DMA_REGS T=%0d PP=%0d: PASS", ARRAY_SIZE, PINGPONG);
        else             $display("TB_DMA_REGS T=%0d PP=%0d: FAIL (%0d)", ARRAY_SIZE, PINGPONG, errors);
        $finish;
    end

    initial begin
        #200000;
        $display("TB_DMA_REGS: FAIL (timeout)");
        $finish;
    end

endmodule

`default_nettype wire
