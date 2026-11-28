`timescale 1ns/1ps
`default_nettype none

// TB-FW: o firmware (sw/firmware.s) rodando na CPU RV32I de verdade, com o
// DMA, o systolic array e a DMEM de verdade. O testbench faz o papel do UVM:
// escreve cada job na caixa de correio (sw/mailbox.inc) por backdoor, toca a
// campainha e confere o que o firmware devolve quando escreve MB_END.
//
// Enquanto o top.v (xbar + cpu_axi_adapter) nao existe, a Porta D da CPU passa
// por uma ponte comportamental deste TB, que decodifica addr[31:28] como o xbar
// (README §3.1):
//   0x4 -> transacao AXI de 1 beat no slave S1 do DMA (pelo axi_master_bfm);
//   0x1 -> DMEM por backdoor (a CPU so toca na caixa, entao nao disputa
//          palavra com o DMA);
//   demais -> leitura 0 e escrita descartada, como o adapter faz com DECERR.
// O M1 do DMA vai para a DMEM pelo checker AXI e pelo gerador de
// backpressure, como no TB-DMA.
//
// Jobs, na ordem (os numeros saem no log):
//   1 caso 3 com wfi           5 dimensao zero (ERR 1)      9 DECERR em C (ERR 4)*
//   2 caso 3 com polling       6 ADDR_B desalinhado (ERR 2) 10 SOFT_RESET no meio
//   3 caso 3 disputando a DMEM 7 SLVERR na leitura (ERR 3)  11 caso 3 depois do aborto
//   4 escritas com BUSY = 1    8 SLVERR na escrita (ERR 4)  12 caso 6 (3x64x3)
//   e MB_EXIT no fim.  (* so com MEM=model; o axi_mem_ctrl nao da DECERR)
//
// Em todo job: MB_END com o numero certo, STATUS esperado, STATUS depois do
// W1C so com o ERR_CODE, irq em 0, MB_STATE = ocioso, INFO certo. Nos jobs bons: C igual ao
// golden e a palavra logo depois de C intacta. O tempo todo: a CPU so acessa a
// caixa na DMEM e os registradores do DMA.
//
// Plusargs: +DMEM=<dmem.hex> +CEXP=<c_expected.hex> (caso 3, 6x5x7)
//           +DMEM6=<dmem.hex> +CEXP6=<c_expected.hex> (caso 6, 3x64x3)
//           +STALL +SEED=<s> (backpressure no M1)   +VCD=<arq>
module tb_fw;
    import mailbox_pkg::*;

    parameter ARRAY_SIZE = 4;
    parameter PINGPONG   = 1;
    parameter FW_HEX     = "build/fw/firmware.hex";

    localparam T   = ARRAY_SIZE;
    localparam IW  = (T > 1) ? $clog2(T) : 1;
    localparam WPR = (T + 3) / 4;
    localparam WW  = (WPR > 1) ? $clog2(WPR) : 1;

    localparam [31:0] DEF_A = 32'h1000_1000, DEF_B = 32'h1000_4000, DEF_C = 32'h1000_8000;
    localparam [31:0] POISON = 32'hDEAD_BEEF;
    localparam [2:0]  S_WAIT = 3'd5;            // estado WAIT da FSM da CPU

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        stall_en = 1'b0;
    reg [31:0] seed = 32'd1;
    integer    errors = 0;

    task fail;
        input [8*96-1:0] msg;
        begin
            errors = errors + 1;
            $display("[%0t] FALHA: %0s", $time, msg);
        end
    endtask

    // ------------------------------------------------------------------ CPU
    wire        i_valid, i_ready, d_valid, halt, irq;
    wire [31:0] i_addr, i_rdata, d_addr, d_wdata;
    wire [3:0]  d_wstrb;
    reg         d_ready = 1'b0;
    reg  [31:0] d_rdata = 32'd0;

    rv32i_cpu u_cpu (
        .clk(clk), .rst_n(rst_n),
        .i_valid(i_valid), .i_addr(i_addr), .i_ready(i_ready), .i_rdata(i_rdata),
        .d_valid(d_valid), .d_addr(d_addr), .d_wstrb(d_wstrb), .d_wdata(d_wdata),
        .d_ready(d_ready), .d_rdata(d_rdata),
        .irq(irq), .halt(halt)
    );

    imem #(.INIT_FILE(FW_HEX)) u_imem (
        .clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_addr(i_addr),
        .i_ready(i_ready), .i_rdata(i_rdata)
    );

    // ------------------------------------------------------------------ S1
    wire [1:0]  s_awid, s_bid, s_arid, s_rid;
    wire [31:0] s_awaddr, s_wdata, s_araddr, s_rdata;
    wire [7:0]  s_awlen, s_arlen;
    wire [2:0]  s_awsize, s_arsize;
    wire [1:0]  s_awburst, s_arburst, s_bresp, s_rresp;
    wire [3:0]  s_wstrb;
    wire        s_awvalid, s_awready, s_wlast, s_wvalid, s_wready, s_bvalid, s_bready;
    wire        s_arvalid, s_arready, s_rlast, s_rvalid, s_rready;

    axi_master_bfm #(.ID_W(2)) u_bfm (
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

    axi_checker #(.ID_W(2), .NAME("S1")) u_chk_s1 (
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

    // ------------------------------------------------------------------ M1 -> DMEM
    wire [0:0]  m_awid, m_bid, m_arid, m_rid;
    wire [31:0] m_awaddr, m_wdata, m_araddr, m_rdata;
    wire [7:0]  m_awlen, m_arlen;
    wire [2:0]  m_awsize, m_arsize, m_awprot, m_arprot;
    wire [1:0]  m_awburst, m_arburst, m_bresp, m_rresp;
    wire [3:0]  m_wstrb, m_awcache, m_arcache;
    wire        m_awlock, m_arlock;
    wire        m_awvalid, m_awready, m_wlast, m_wvalid, m_wready, m_bvalid, m_bready;
    wire        m_arvalid, m_arready, m_rlast, m_rvalid, m_rready;

    wire [0:0]  d_awid, d_bid, d_arid, d_rid;
    wire [31:0] d_awaddr, d_wdata_m, d_araddr, d_rdata_m;
    wire [7:0]  d_awlen, d_arlen;
    wire [2:0]  d_awsize, d_arsize;
    wire [1:0]  d_awburst, d_arburst, d_bresp, d_rresp;
    wire [3:0]  d_wstrb_m;
    wire        d_awvalid, d_awready, d_wlast, d_wvalid, d_wready, d_bvalid, d_bready;
    wire        d_arvalid, d_arready, d_rlast, d_rvalid, d_rready;

    axi_checker #(.ID_W(1), .NAME("M1")) u_chk_m1 (
        .clk(clk), .rst_n(rst_n),
        .awid(m_awid), .awaddr(m_awaddr), .awlen(m_awlen), .awsize(m_awsize),
        .awburst(m_awburst), .awvalid(m_awvalid), .awready(m_awready),
        .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast), .wvalid(m_wvalid), .wready(m_wready),
        .bid(m_bid), .bresp(m_bresp), .bvalid(m_bvalid), .bready(m_bready),
        .arid(m_arid), .araddr(m_araddr), .arlen(m_arlen), .arsize(m_arsize),
        .arburst(m_arburst), .arvalid(m_arvalid), .arready(m_arready),
        .rid(m_rid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rvalid(m_rvalid),
        .rready(m_rready)
    );

    axi_rand_stall #(.ID_W(1)) u_stall (
        .clk(clk), .rst_n(rst_n), .enable(stall_en), .seed(seed),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
        .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
        .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rvalid(m_rvalid), .m_rready(m_rready),
        .s_awid(d_awid), .s_awaddr(d_awaddr), .s_awlen(d_awlen), .s_awsize(d_awsize),
        .s_awburst(d_awburst), .s_awvalid(d_awvalid), .s_awready(d_awready),
        .s_wdata(d_wdata_m), .s_wstrb(d_wstrb_m), .s_wlast(d_wlast), .s_wvalid(d_wvalid),
        .s_wready(d_wready),
        .s_bid(d_bid), .s_bresp(d_bresp), .s_bvalid(d_bvalid), .s_bready(d_bready),
        .s_arid(d_arid), .s_araddr(d_araddr), .s_arlen(d_arlen), .s_arsize(d_arsize),
        .s_arburst(d_arburst), .s_arvalid(d_arvalid), .s_arready(d_arready),
        .s_rid(d_rid), .s_rdata(d_rdata_m), .s_rresp(d_rresp), .s_rlast(d_rlast),
        .s_rvalid(d_rvalid), .s_rready(d_rready)
    );

`ifdef MEM_CTRL
    axi_mem_ctrl #(.ID_W(1)) u_mem (
        .clk(clk), .rst_n(rst_n),
`else
    axi_mem_model #(.ID_W(1)) u_mem (
        .clk(clk), .rst_n(rst_n), .w_first(1'b0),
`endif
        .awid(d_awid), .awaddr(d_awaddr), .awlen(d_awlen), .awsize(d_awsize),
        .awburst(d_awburst), .awvalid(d_awvalid), .awready(d_awready),
        .wdata(d_wdata_m), .wstrb(d_wstrb_m), .wlast(d_wlast), .wvalid(d_wvalid),
        .wready(d_wready),
        .bid(d_bid), .bresp(d_bresp), .bvalid(d_bvalid), .bready(d_bready),
        .arid(d_arid), .araddr(d_araddr), .arlen(d_arlen), .arsize(d_arsize),
        .arburst(d_arburst), .arvalid(d_arvalid), .arready(d_arready),
        .rid(d_rid), .rdata(d_rdata_m), .rresp(d_rresp), .rlast(d_rlast), .rvalid(d_rvalid),
        .rready(d_rready)
    );

`ifdef MEM_CTRL
    `define MEM_ARR u_mem.u_ram.mem
`else
    `define MEM_ARR u_mem.mem
`endif

    // ------------------------------------------------------------------ DMA + acelerador
    wire          buf_a_we, buf_b_we, buf_bank;
    wire [IW-1:0] buf_row;
    wire [WW-1:0] buf_word;
    wire [31:0]   buf_wdata;
    wire          tile_start, tile_bank, first_k, last_k;
    wire          acc_busy, acc_active, tile_done, c_valid, c_release, c_rd;
    wire [IW-1:0] c_row, c_col;
    wire [31:0]   c_rdata;

    accel #(.ARRAY_SIZE(T), .PINGPONG(PINGPONG)) u_acc (
        .clk(clk), .rst_n(rst_n),
        .buf_a_we(buf_a_we), .buf_b_we(buf_b_we), .buf_bank(buf_bank), .buf_row(buf_row),
        .buf_word(buf_word), .buf_wdata(buf_wdata),
        .tile_start(tile_start), .tile_bank(tile_bank), .first_k(first_k), .last_k(last_k),
        .busy(acc_busy), .acc_active(acc_active), .tile_done(tile_done),
        .c_valid(c_valid), .c_release(c_release), .c_rd(c_rd), .c_row(c_row), .c_col(c_col),
        .c_rdata(c_rdata)
    );

    dma #(.ARRAY_SIZE(T), .PINGPONG(PINGPONG)) u_dma (
        .clk(clk), .rst_n(rst_n), .irq(irq),
        .s_awid(s_awid), .s_awaddr(s_awaddr), .s_awlen(s_awlen), .s_awsize(s_awsize),
        .s_awburst(s_awburst), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wstrb(s_wstrb), .s_wlast(s_wlast), .s_wvalid(s_wvalid),
        .s_wready(s_wready),
        .s_bid(s_bid), .s_bresp(s_bresp), .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_arid(s_arid), .s_araddr(s_araddr), .s_arlen(s_arlen), .s_arsize(s_arsize),
        .s_arburst(s_arburst), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rid(s_rid), .s_rdata(s_rdata), .s_rresp(s_rresp), .s_rlast(s_rlast),
        .s_rvalid(s_rvalid), .s_rready(s_rready),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
        .m_awburst(m_awburst), .m_awlock(m_awlock), .m_awcache(m_awcache), .m_awprot(m_awprot),
        .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
        .m_wready(m_wready),
        .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
        .m_arburst(m_arburst), .m_arlock(m_arlock), .m_arcache(m_arcache), .m_arprot(m_arprot),
        .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rresp(m_rresp), .m_rlast(m_rlast),
        .m_rvalid(m_rvalid), .m_rready(m_rready),
        .buf_a_we(buf_a_we), .buf_b_we(buf_b_we), .buf_bank(buf_bank), .buf_row(buf_row),
        .buf_word(buf_word), .buf_wdata(buf_wdata),
        .tile_start(tile_start), .tile_bank(tile_bank), .first_k(first_k), .last_k(last_k),
        .busy(acc_busy), .acc_active(acc_active), .tile_done(tile_done),
        .c_valid(c_valid), .c_release(c_release), .c_rd(c_rd), .c_row(c_row), .c_col(c_col),
        .c_rdata(c_rdata)
    );

    // ------------------------------------------------------------------ ponte da Porta D
    // Faz o papel do cpu_axi_adapter + xbar ate o top.v existir (ver cabecalho).
    reg [31:0] bridge_rd;
    reg [1:0]  bridge_resp;
    reg [31:0] w;
    integer    widx, b;

    initial begin
        forever begin
            @(posedge clk);
            d_ready <= 1'b0;
            if (rst_n && d_valid && !d_ready) begin
                bridge_rd = 32'd0;
                case (d_addr[31:28])
                    4'h4: begin
                        if (d_wstrb != 4'd0)
                            u_bfm.axi_write_strb(d_addr, d_wdata, d_wstrb, bridge_resp);
                        else
                            u_bfm.axi_read(d_addr, bridge_rd, bridge_resp);
                        if (bridge_resp !== 2'b00) fail("resposta de erro do S1 a um acesso da CPU");
                    end
                    4'h1: begin
                        // 1 ciclo a mais de latencia, como uma leitura curta da SRAM
                        @(posedge clk);
                        if (d_addr[27:16] == 12'd0) begin
                            widx = d_addr[15:2];
                            w    = `MEM_ARR[widx];
                            if (d_wstrb != 4'd0) begin
                                for (b = 0; b < 4; b = b + 1)
                                    if (d_wstrb[b]) w[8 * b +: 8] = d_wdata[8 * b +: 8];
                                `MEM_ARR[widx] = w;
                            end
                            bridge_rd = w;
                        end
                    end
                    default: ;
                endcase
                d_rdata <= bridge_rd;
                d_ready <= 1'b1;
            end
        end
    end

    // A CPU so pode tocar na caixa (DMEM) e nos registradores do DMA: e o que
    // garante que A, B e C ficam so com o DMA (requisito "CPU nao move dados").
    integer cpu_out_of_box = 0;
    always @(posedge clk)
        if (rst_n && d_valid && d_ready) begin
            if (!((d_addr >= MB_BASE && d_addr < MB_BASE + MB_SIZE)
                  || (d_addr >= 32'h4000_0000 && d_addr < 32'h4000_002C))) begin
                cpu_out_of_box = cpu_out_of_box + 1;
                $display("[%0t] FALHA: CPU acessou %h (fora da caixa e dos registradores)",
                         $time, d_addr);
            end
            if (d_wstrb != 4'd0 && d_wstrb != 4'hF)
                fail("firmware fez escrita parcial (so deveria usar sw)");
        end

    // Ciclos da CPU no estado WAIT (wfi), por job
    integer wait_cycles = 0;
    always @(posedge clk)
        if (rst_n && u_cpu.u_controller.state == S_WAIT) wait_cycles = wait_cycles + 1;

    // ------------------------------------------------------------------ caixa de correio
    function [31:0] mb_rd;
        input [31:0] off;
        mb_rd = `MEM_ARR[((MB_BASE + off) & 32'hFFFF) >> 2];
    endfunction

    task mb_wr;
        input [31:0] off;
        input [31:0] val;
        `MEM_ARR[((MB_BASE + off) & 32'hFFFF) >> 2] = val;
    endtask

    reg [31:0] cexp3 [0:4095];
    reg [31:0] cexp6 [0:4095];
    reg [31:0] info_exp;
    reg [8*256-1:0] dmem_file, cexp_file, dmem6_file, cexp6_file, vcd_file;
    integer job = 0;
    integer i;

    // Suja C (e a palavra logo depois) para ver que o DMA gravou tudo
    task poison_c;
        input [31:0]  base;
        input integer m, n;
        begin
            for (i = 0; i <= m * n; i = i + 1)
                `MEM_ARR[base[15:2] + i] = POISON;
        end
    endtask

    task check_c;
        input [31:0]  base;
        input integer m, n, which;
        integer bad;
        reg [31:0] exp;
        begin
            bad = 0;
            for (i = 0; i < m * n; i = i + 1) begin
                exp = (which == 6) ? cexp6[i] : cexp3[i];
                if (`MEM_ARR[base[15:2] + i] !== exp) begin
                    if (bad < 4)
                        $display("  C[%0d][%0d] = %h, esperado %h", i / n, i % n,
                                 `MEM_ARR[base[15:2] + i], exp);
                    bad = bad + 1;
                end
            end
            if (bad != 0) fail("C diferente do golden");
            if (`MEM_ARR[base[15:2] + m * n] !== POISON) fail("palavra depois de C foi alterada");
        end
    endtask

    // Escreve o job na caixa, toca a campainha e espera o END
    task run_job;
        input [31:0]  flags, a, bb, c;
        input integer m, n, k, sr_delay;
        integer guard;
        begin
            job = job + 1;
            mb_wr(MB_FLAGS, flags);
            mb_wr(MB_ADDR_A, a);
            mb_wr(MB_ADDR_B, bb);
            mb_wr(MB_ADDR_C, c);
            mb_wr(MB_DIM_M, m);
            mb_wr(MB_DIM_N, n);
            mb_wr(MB_DIM_K, k);
            mb_wr(MB_SR_DELAY, sr_delay);
            wait_cycles = 0;
            mb_wr(MB_DOORBELL, job);                // por ultimo
            guard = 0;
            while (mb_rd(MB_END) !== job && guard < 200000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (guard >= 200000) begin
                fail("timeout esperando MB_END");
                $display("TB_FW T=%0d PP=%0d: FAIL (timeout no job %0d)", T, PINGPONG, job);
                $finish;
            end
            repeat (2) @(posedge clk);
        end
    endtask

    // Conferencias comuns a todo job
    task check_common;
        input [31:0] status_exp;
        input [8*40-1:0] name;
        begin
            $display("job %0d (%0s): STATUS=%h CYCLES=%0d CYC_COMPUTE=%0d WAIT_COUNT=%0d wfi=%0d ciclos",
                     job, name, mb_rd(MB_STATUS), mb_rd(MB_CYCLES), mb_rd(MB_CYC_COMPUTE),
                     mb_rd(MB_WAIT_COUNT), wait_cycles);
            if (mb_rd(MB_STATUS) !== status_exp) begin
                $display("  STATUS = %h, esperado %h", mb_rd(MB_STATUS), status_exp);
                fail("STATUS no fim do job");
            end
            // o W1C limpa DONE e ERROR; ERR_CODE e RO e so zera no proximo START
            if (mb_rd(MB_STATUS_W1C) !== (status_exp & 32'hF0))
                fail("STATUS depois do W1C diferente de ERR_CODE << 4");
            if (irq !== 1'b0) fail("irq ainda em 1 depois do W1C");
            if (mb_rd(MB_STATE) !== ST_IDLE) fail("MB_STATE diferente de ST_IDLE no fim do job");
            if (mb_rd(MB_INFO) !== info_exp) fail("INFO");
            if (u_dma.ctrl_busy !== 1'b0) fail("DMA ainda ocupado depois do END");
        end
    endtask

    task good_job;
        input [31:0] flags;
        input integer m, n, k, which;
        input [8*40-1:0] name;
        begin
            poison_c(DEF_C, m, n);
            run_job(flags, DEF_A, DEF_B, DEF_C, m, n, k, 0);
            check_common(32'h2, name);
            check_c(DEF_C, m, n, which);
            if (mb_rd(MB_CYCLES) == 0) fail("CYCLES = 0");
            if (mb_rd(MB_CYC_COMPUTE) !== ((m + T - 1) / T) * ((n + T - 1) / T)
                                          * ((k + T - 1) / T) * (3 * T - 1))
                fail("CYC_COMPUTE diferente de tiles * blocos * (3T - 1)");
        end
    endtask

    reg [31:0] scratch_sum0, scratch_sum1;

    task scratch_sum;
        output [31:0] s;
        integer j;
        begin
            s = 0;
            for (j = 0; j < MB_SCRATCH_WORDS; j = j + 1)
                s = s + mb_rd(MB_SCRATCH + 4 * j);
        end
    endtask

    initial begin
        if (!$value$plusargs("DMEM=%s", dmem_file))   dmem_file  = "build/vec/smoke/dmem.hex";
        if (!$value$plusargs("CEXP=%s", cexp_file))   cexp_file  = "build/vec/smoke/c_expected.hex";
        if (!$value$plusargs("DMEM6=%s", dmem6_file)) dmem6_file = "build/vec/case6/dmem.hex";
        if (!$value$plusargs("CEXP6=%s", cexp6_file)) cexp6_file = "build/vec/case6/c_expected.hex";
        if ($value$plusargs("SEED=%d", seed)) ;
        if ($test$plusargs("STALL")) stall_en = 1'b1;
        if ($value$plusargs("VCD=%s", vcd_file)) begin
            $dumpfile(vcd_file);
            $dumpvars(0, tb_fw);
        end
        info_exp = {3'd0, (PINGPONG != 0), 4'd2, 8'd32, 8'd8, 8'(T)};

        #1;
        $readmemh(dmem_file, `MEM_ARR);
        $readmemh(cexp_file, cexp3, 0, 6 * 7 - 1);
        $readmemh(cexp6_file, cexp6, 0, 3 * 3 - 1);

        repeat (3) @(posedge clk);
        rst_n = 1'b1;

        // o firmware sobe e fica esperando
        i = 0;
        while (mb_rd(MB_STATE) !== ST_IDLE && i < 1000) begin @(posedge clk); i = i + 1; end
        if (mb_rd(MB_STATE) !== ST_IDLE) fail("firmware nao chegou em ST_IDLE");

        // 1: wfi. A CPU tem de dormir no WAIT (o job dura bem mais que a
        // configuracao, entao o wfi roda com o DMA ocupado)
        good_job(F_IRQ, 6, 7, 5, 3, "caso 3, wfi");
        if (wait_cycles == 0 || mb_rd(MB_WAIT_COUNT) == 0) fail("a CPU nao dormiu no wfi");

        // 2: polling. Sem IRQ_EN a CPU nunca entra no WAIT
        good_job(32'd0, 6, 7, 5, 3, "caso 3, polling");
        if (wait_cycles != 0) fail("a CPU entrou no WAIT sem F_IRQ");
        if (mb_rd(MB_WAIT_COUNT) == 0) fail("polling sem nenhuma leitura de STATUS");

        // 3: disputa. O que entrou no rascunho = MB_WAIT_COUNT
        scratch_sum(scratch_sum0);
        good_job(F_CONTEND | F_IRQ, 6, 7, 5, 3, "caso 3, disputa na DMEM");
        scratch_sum(scratch_sum1);
        if (mb_rd(MB_WAIT_COUNT) == 0) fail("disputa sem nenhuma volta");
        if (scratch_sum1 - scratch_sum0 !== mb_rd(MB_WAIT_COUNT))
            fail("rascunho nao bate com MB_WAIT_COUNT");

        // 4: com BUSY = 1, ADDR_A, DIM_M e START sao ignorados
        good_job(F_BUSY_WR | F_IRQ, 6, 7, 5, 3, "caso 3, escritas com BUSY");
        if ((mb_rd(MB_BUSY_STATUS) & 32'h1) !== 32'h1) fail("BUSY nao estava em 1 no teste");
        if (mb_rd(MB_RB_ADDR_A) !== DEF_A) fail("ADDR_A mudou com BUSY = 1");
        if (mb_rd(MB_RB_DIM_M) !== 32'd6)  fail("DIM_M mudou com BUSY = 1");

        // 5 a 9: erros. DONE | ERROR | ERR_CODE << 4
        run_job(F_IRQ, DEF_A, DEF_B, DEF_C, 6, 7, 0, 0);
        check_common(32'h16, "dimensao zero");
        run_job(32'd0, DEF_A, 32'h1000_4002, DEF_C, 6, 7, 5, 0);
        check_common(32'h26, "ADDR_B desalinhado");
        run_job(F_IRQ, 32'h1003_0000, DEF_B, DEF_C, 6, 7, 5, 0);
        check_common(32'h36, "SLVERR na leitura");
        run_job(F_IRQ, DEF_A, DEF_B, 32'h1003_0000, 6, 7, 5, 0);
        check_common(32'h46, "SLVERR na escrita");
`ifdef MEM_CTRL
        $display("job -  (DECERR na escrita): SKIP, o axi_mem_ctrl nao da DECERR (vem do xbar)");
`else
        run_job(F_IRQ, DEF_A, DEF_B, 32'h2000_0000, 6, 7, 5, 0);
        check_common(32'h46, "DECERR na escrita");
`endif

        // 10: SOFT_RESET no meio da operacao: sem DONE, STATUS zerado
        run_job(F_SOFT_RESET | F_IRQ, DEF_A, DEF_B, DEF_C, 6, 7, 5, 2);
        check_common(32'h0, "SOFT_RESET");

        // 11: retomada depois do aborto
        good_job(F_IRQ, 6, 7, 5, 3, "caso 3 depois do SOFT_RESET");

        // 12: outro job, com outras dimensoes (caso 6, K longo)
        $readmemh(dmem6_file, `MEM_ARR);
        good_job(F_IRQ, 3, 3, 64, 6, "caso 6 (3x64x3), wfi");

        // fim: MB_EXIT para a CPU
        mb_wr(MB_DOORBELL, MB_EXIT);
        i = 0;
        while (!halt && i < 2000) begin @(posedge clk); i = i + 1; end
        if (!halt) fail("CPU nao parou depois do MB_EXIT");
        if (mb_rd(MB_END) !== MB_EXIT) fail("MB_END diferente de MB_EXIT");
        if (mb_rd(MB_STATE) !== ST_HALT) fail("MB_STATE diferente de ST_HALT");

        errors = errors + cpu_out_of_box + u_chk_s1.violations + u_chk_m1.violations;
        if (errors == 0)
            $display("TB_FW T=%0d PP=%0d: PASS (%0d jobs)", T, PINGPONG, job);
        else
            $display("TB_FW T=%0d PP=%0d: FAIL (%0d erros)", T, PINGPONG, errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("TB_FW: FAIL (timeout global)");
        $finish;
    end

endmodule

`undef MEM_ARR
`default_nettype wire
