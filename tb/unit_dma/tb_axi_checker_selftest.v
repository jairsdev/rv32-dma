`timescale 1ns/1ps
`default_nettype none

// Autoteste do axi_checker (MAS 17, passo 1).
// Primeiro roda transacoes legais (nenhuma violacao esperada); depois injeta
// uma violacao por vez e confere que o contador do checker sobe.
module tb_axi_checker_selftest;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg  [0:0]  awid = 0, bid = 0, arid = 0, rid = 0;
    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0, rdata = 0;
    reg  [7:0]  awlen = 0, arlen = 0;
    reg  [2:0]  awsize = 3'b010, arsize = 3'b010;
    reg  [1:0]  awburst = 2'b01, arburst = 2'b01, bresp = 0, rresp = 0;
    reg  [3:0]  wstrb = 4'hF;
    reg         awvalid = 0, awready = 0, wlast = 0, wvalid = 0, wready = 0;
    reg         bvalid = 0, bready = 0, arvalid = 0, arready = 0;
    reg         rlast = 0, rvalid = 0, rready = 0;

    axi_checker #(.ID_W(1), .NAME("selftest")) u_chk (
        .clk(clk), .rst_n(rst_n),
        .awid(awid), .awaddr(awaddr), .awlen(awlen), .awsize(awsize), .awburst(awburst),
        .awvalid(awvalid), .awready(awready),
        .wdata(wdata), .wstrb(wstrb), .wlast(wlast), .wvalid(wvalid), .wready(wready),
        .bid(bid), .bresp(bresp), .bvalid(bvalid), .bready(bready),
        .arid(arid), .araddr(araddr), .arlen(arlen), .arsize(arsize), .arburst(arburst),
        .arvalid(arvalid), .arready(arready),
        .rid(rid), .rdata(rdata), .rresp(rresp), .rlast(rlast), .rvalid(rvalid), .rready(rready)
    );

    integer fails = 0;
    integer base_cnt;

    task cyc;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task idle_all;
        begin
            awvalid = 0; awready = 0; wvalid = 0; wready = 0; wlast = 0;
            bvalid = 0; bready = 0; arvalid = 0; arready = 0;
            rvalid = 0; rready = 0; rlast = 0;
            awsize = 3'b010; arsize = 3'b010; awburst = 2'b01; arburst = 2'b01;
            awlen = 0; arlen = 0; awaddr = 32'h1000_0000; araddr = 32'h1000_0000;
        end
    endtask

    // Escrita legal de len+1 beats
    task legal_write;
        input [31:0] addr;
        input [7:0]  len;
        integer b;
        begin
            awaddr = addr; awlen = len; awvalid = 1; awready = 1;
            cyc;
            awvalid = 0; awready = 0;
            for (b = 0; b <= len; b = b + 1) begin
                wvalid = 1; wready = 1; wlast = (b == len); wdata = b;
                cyc;
            end
            wvalid = 0; wready = 0; wlast = 0;
            bvalid = 1; bready = 1;
            cyc;
            bvalid = 0; bready = 0;
        end
    endtask

    // Leitura legal de len+1 beats
    task legal_read;
        input [31:0] addr;
        input [7:0]  len;
        integer b;
        begin
            araddr = addr; arlen = len; arvalid = 1; arready = 1;
            cyc;
            arvalid = 0; arready = 0;
            for (b = 0; b <= len; b = b + 1) begin
                rvalid = 1; rready = 1; rlast = (b == len);
                cyc;
            end
            rvalid = 0; rready = 0; rlast = 0;
        end
    endtask

    task expect_violation;
        input [8*48-1:0] what;
        begin
            cyc;
            if (u_chk.violations == base_cnt) begin
                fails = fails + 1;
                $display("FALHA: checker nao acusou: %0s", what);
            end else begin
                $display("ok: acusou %0s", what);
            end
            idle_all;
            // Reset entre injecoes para limpar o estado de rastreamento
            rst_n = 0; cyc; rst_n = 1; cyc;
            base_cnt = u_chk.violations;
        end
    endtask

    initial begin
        idle_all;
        cyc; cyc;
        rst_n = 1;
        cyc;

        // ---- Transacoes legais ----
        legal_write(32'h1000_0000, 8'd3);
        legal_read (32'h1000_0FF8, 8'd1);     // termina exatamente na fronteira
        legal_write(32'h1000_0100, 8'd0);
        if (u_chk.violations != 0) begin
            fails = fails + 1;
            $display("FALHA: violacao em transacoes legais (%0d)", u_chk.violations);
        end
        base_cnt = u_chk.violations;

        // ---- Injecoes ----
        // 1. AWVALID cai sem handshake
        awvalid = 1; cyc; awvalid = 0;
        expect_violation("AWVALID caiu sem handshake");

        // 2. Payload de AR muda antes do handshake
        arvalid = 1; araddr = 32'h1000_0000; cyc; araddr = 32'h1000_0004;
        expect_violation("payload de AR mudou");

        // 3. ARBURST != INCR
        arvalid = 1; arready = 1; arburst = 2'b10; cyc; arvalid = 0; arready = 0;
        expect_violation("ARBURST != INCR");

        // 4. AWSIZE != 4 bytes
        awvalid = 1; awready = 1; awsize = 3'b001; cyc; awvalid = 0; awready = 0;
        expect_violation("AWSIZE != 4 B");

        // 5. Burst cruza 4 KB
        arvalid = 1; arready = 1; araddr = 32'h1000_0FFC; arlen = 8'd1; cyc;
        arvalid = 0; arready = 0;
        expect_violation("burst cruza 4 KB");

        // 6. RLAST cedo
        arvalid = 1; arready = 1; arlen = 8'd2; cyc; arvalid = 0; arready = 0;
        rvalid = 1; rready = 1; rlast = 1; cyc;
        expect_violation("RLAST fora do ultimo beat");

        // 7. Ultimo beat de W sem WLAST
        awvalid = 1; awready = 1; awlen = 8'd0; cyc; awvalid = 0; awready = 0;
        wvalid = 1; wready = 1; wlast = 0; cyc;
        expect_violation("ultimo beat de W sem WLAST");

        // 8. B antes do WLAST
        awvalid = 1; awready = 1; awlen = 8'd1; cyc; awvalid = 0; awready = 0;
        wvalid = 1; wready = 1; wlast = 0; cyc; wvalid = 0; wready = 0;
        bvalid = 1; bready = 1; cyc;
        expect_violation("B antes do WLAST");

        // 9. Duas leituras em andamento
        arvalid = 1; arready = 1; arlen = 8'd1; cyc;
        araddr = 32'h1000_0100; cyc; arvalid = 0; arready = 0;
        expect_violation("outstanding de leitura > 1");

        // 10. Beat de R sem AR
        rvalid = 1; rready = 1; rlast = 1; cyc;
        expect_violation("R sem AR");

        // 11. Payload de W muda antes do handshake
        wvalid = 1; wdata = 32'h1; cyc; wdata = 32'h2;
        expect_violation("payload de W mudou");

        if (fails == 0)
            $display("TB_AXI_CHECKER_SELFTEST: PASS");
        else
            $display("TB_AXI_CHECKER_SELFTEST: FAIL (%0d)", fails);
        $finish;
    end

endmodule

`default_nettype wire
