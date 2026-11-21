`timescale 1ns/1ps
`default_nettype none

module tb_dma;

    parameter ARRAY_SIZE = 4;
    parameter PINGPONG   = 1;
    parameter MAX_BURST  = 16;

    localparam T   = ARRAY_SIZE;
    localparam IW  = (T > 1) ? $clog2(T) : 1;
    localparam WPR = (T + 3) / 4;
    localparam WW  = (WPR > 1) ? $clog2(WPR) : 1;

    localparam [31:0] REGS = 32'h4000_0000;
    localparam [31:0] R_CTRL = REGS + 32'h00, R_STATUS = REGS + 32'h04,
                      R_ADDR_A = REGS + 32'h08, R_ADDR_B = REGS + 32'h0C,
                      R_ADDR_C = REGS + 32'h10, R_DIM_M = REGS + 32'h14,
                      R_DIM_N = REGS + 32'h18, R_DIM_K = REGS + 32'h1C,
                      R_CYCLES = REGS + 32'h20, R_INFO = REGS + 32'h24,
                      R_CYC_COMPUTE = REGS + 32'h28;

    localparam [31:0] DEF_A = 32'h1000_1000, DEF_B = 32'h1000_4000, DEF_C = 32'h1000_8000;

    localparam [31:0] CTRL_START = 32'h1, CTRL_IRQ_EN = 32'h2, CTRL_SOFT_RESET = 32'h4;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    reg        stall_en = 1'b0;
    reg [31:0] seed = 32'd1;

    // S1: o BFM faz o papel da CPU e acessa os registradores do DMA
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

    // M1: o master do DMA passa pelo checker e pelo gerador de backpressure
    // antes de chegar na memoria
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
    wire [31:0] d_awaddr, d_wdata, d_araddr, d_rdata;
    wire [7:0]  d_awlen, d_arlen;
    wire [2:0]  d_awsize, d_arsize;
    wire [1:0]  d_awburst, d_arburst, d_bresp, d_rresp;
    wire [3:0]  d_wstrb;
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
        .s_wdata(d_wdata), .s_wstrb(d_wstrb), .s_wlast(d_wlast), .s_wvalid(d_wvalid),
        .s_wready(d_wready),
        .s_bid(d_bid), .s_bresp(d_bresp), .s_bvalid(d_bvalid), .s_bready(d_bready),
        .s_arid(d_arid), .s_araddr(d_araddr), .s_arlen(d_arlen), .s_arsize(d_arsize),
        .s_arburst(d_arburst), .s_arvalid(d_arvalid), .s_arready(d_arready),
        .s_rid(d_rid), .s_rdata(d_rdata), .s_rresp(d_rresp), .s_rlast(d_rlast),
        .s_rvalid(d_rvalid), .s_rready(d_rready)
    );

    // Memoria comportamental. Quando o axi_mem_ctrl (passo 2 do MAS) ficar
    // pronto, ele entra aqui no lugar deste modelo.
    axi_mem_model #(.ID_W(1)) u_mem (
        .clk(clk), .rst_n(rst_n), .w_first(1'b0),
        .awid(d_awid), .awaddr(d_awaddr), .awlen(d_awlen), .awsize(d_awsize),
        .awburst(d_awburst), .awvalid(d_awvalid), .awready(d_awready),
        .wdata(d_wdata), .wstrb(d_wstrb), .wlast(d_wlast), .wvalid(d_wvalid), .wready(d_wready),
        .bid(d_bid), .bresp(d_bresp), .bvalid(d_bvalid), .bready(d_bready),
        .arid(d_arid), .araddr(d_araddr), .arlen(d_arlen), .arsize(d_arsize),
        .arburst(d_arburst), .arvalid(d_arvalid), .arready(d_arready),
        .rid(d_rid), .rdata(d_rdata), .rresp(d_rresp), .rlast(d_rlast), .rvalid(d_rvalid),
        .rready(d_rready)
    );

    wire          buf_a_we, buf_b_we, buf_bank;
    wire [IW-1:0] buf_row;
    wire [WW-1:0] buf_word;
    wire [31:0]   buf_wdata;
    wire          tile_start, tile_bank, first_k, last_k;
    wire          acc_busy, acc_active, tile_done, c_valid, c_release, c_rd;
    wire [IW-1:0] c_row, c_col;
    wire [31:0]   c_rdata;
    wire          irq;

    // O systolic array de verdade (rtl/accel)
    accel #(
        .ARRAY_SIZE (T),
        .PINGPONG   (PINGPONG)
    ) u_acc (
        .clk        (clk),
        .rst_n      (rst_n),
        .buf_a_we   (buf_a_we),
        .buf_b_we   (buf_b_we),
        .buf_bank   (buf_bank),
        .buf_row    (buf_row),
        .buf_word   (buf_word),
        .buf_wdata  (buf_wdata),
        .tile_start (tile_start),
        .tile_bank  (tile_bank),
        .first_k    (first_k),
        .last_k     (last_k),
        .busy       (acc_busy),
        .acc_active (acc_active),
        .tile_done  (tile_done),
        .c_valid    (c_valid),
        .c_release  (c_release),
        .c_rd       (c_rd),
        .c_row      (c_row),
        .c_col      (c_col),
        .c_rdata    (c_rdata)
    );

    dma #(
        .ARRAY_SIZE (T),
        .PINGPONG   (PINGPONG),
        .MAX_BURST  (MAX_BURST)
    ) u_dma (
        .clk        (clk),
        .rst_n      (rst_n),
        .irq        (irq),
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
        .buf_a_we   (buf_a_we),
        .buf_b_we   (buf_b_we),
        .buf_bank   (buf_bank),
        .buf_row    (buf_row),
        .buf_word   (buf_word),
        .buf_wdata  (buf_wdata),
        .tile_start (tile_start),
        .tile_bank  (tile_bank),
        .first_k    (first_k),
        .last_k     (last_k),
        .busy       (acc_busy),
        .acc_active (acc_active),
        .tile_done  (tile_done),
        .c_valid    (c_valid),
        .c_release  (c_release),
        .c_rd       (c_rd),
        .c_row      (c_row),
        .c_col      (c_col),
        .c_rdata    (c_rdata)
    );

    // BUSY interno do DMA, usado nos testes de dreno
    wire ctrl_busy = u_dma.ctrl_busy;

    // H6 olhando de fora: com o DMA parado nenhum AR/AW pode ser aceito
    integer errors = 0;
    always @(posedge clk)
        if (rst_n && !ctrl_busy && ((m_arvalid && m_arready) || (m_awvalid && m_awready))) begin
            errors = errors + 1;
            $display("[%0t] FALHA H6: AR/AW aceito com BUSY = 0", $time);
        end

    // Protocolo entre DMA e acelerador. Essas checagens ficavam dentro do
    // accel_model; com o acelerador real elas passam a ser feitas aqui.
    integer side_errors = 0;
    reg     mon_bank = 1'b0;

    task side_fail;
        input [8*64-1:0] msg;
        begin
            side_errors = side_errors + 1;
            $display("[%0t] FALHA sideband: %0s", $time, msg);
        end
    endtask

    always @(posedge clk)
        if (rst_n) begin
            if (tile_start && acc_busy)
                side_fail("tile_start com a malha ocupada");
            if (tile_start && !acc_busy)
                mon_bank <= (PINGPONG != 0) ? tile_bank : 1'b0;
            if ((buf_a_we || buf_b_we) && acc_busy
                    && (((PINGPONG != 0) ? buf_bank : 1'b0) == mon_bank))
                side_fail("escrita no banco que a malha esta usando");
            if (c_release && !c_valid)
                side_fail("c_release sem c_valid");
            if (PINGPONG == 0 && tile_start && first_k && c_valid)
                side_fail("first_k com o C anterior ainda nao gravado");
        end

    // +TRACE mostra cada AR/AW aceito, util para conferir a tabela 8.3 do MAS
    reg trace = 1'b0;
    always @(posedge clk)
        if (trace && rst_n) begin
            if (m_arvalid && m_arready) $display("TRACE AR %h %0d", m_araddr, m_arlen);
            if (m_awvalid && m_awready) $display("TRACE AW %h %0d", m_awaddr, m_awlen);
        end

    reg [31:0] mem_init [0:16383];
    reg [31:0] cexp     [0:4095];
    integer    dim_m = 6, dim_n = 7, dim_k = 5;
    reg [8*256-1:0] dmem_file, cexp_file, vcd_file;

    reg [31:0] rd;
    reg [1:0]  resp;

    task fail;
        input [8*80-1:0] msg;
        begin
            errors = errors + 1;
            $display("[%0t] FALHA: %0s", $time, msg);
        end
    endtask

    task reg_wr;
        input [31:0] addr;
        input [31:0] data;
        begin
            u_bfm.axi_write(addr, data, resp);
            if (resp !== 2'b00) fail("resposta de escrita em registrador");
        end
    endtask

    task reg_rd;
        input  [31:0] addr;
        output [31:0] data;
        begin
            u_bfm.axi_read(addr, data, resp);
            if (resp !== 2'b00) fail("resposta de leitura de registrador");
        end
    endtask

    task configure;
        input [31:0] a, b, c;
        input integer m, n, k;
        begin
            reg_wr(R_ADDR_A, a);
            reg_wr(R_ADDR_B, b);
            reg_wr(R_ADDR_C, c);
            reg_wr(R_DIM_M, m);
            reg_wr(R_DIM_N, n);
            reg_wr(R_DIM_K, k);
        end
    endtask

    // Suja os bytes de preenchimento das linhas de A e B (entre a dimensao e o
    // stride). O golden deixa zero ali; com lixo, da para ver que o resultado
    // nao depende desses zeros. No resultado final a mascara de padding do
    // dma_rd_engine acaba sendo redundante (o lixo de A alem de K multiplica
    // linhas de B zeradas em R_ZERO, e o lixo de B alem de N cai em colunas de C
    // que nao sao gravadas), por isso a mascara em si e testada no TB-RD.
    task poison_padding;
        input [31:0]  base;
        input integer rows, cols;
        integer r, c, stride, idx;
        reg [31:0] addr, w;
        begin
            stride = ((cols + 3) / 4) * 4;
            for (r = 0; r < rows; r = r + 1)
                for (c = cols; c < stride; c = c + 1) begin
                    addr = base + r * stride + c;
                    idx  = addr[15:2];
                    w    = u_mem.mem[idx];
                    w[8 * addr[1:0] +: 8] = 8'hA5 ^ r[7:0] ^ c[7:0];
                    u_mem.mem[idx] = w;
                end
        end
    endtask

    // Volta a DMEM ao estado inicial e zera os contadores de escrita
    task restore_mem;
        integer i;
        begin
            for (i = 0; i < 16384; i = i + 1) begin
                u_mem.mem[i]      = mem_init[i];
                u_mem.wr_count[i] = 0;
            end
        end
    endtask

    task wait_irq;
        integer guard;
        begin
            guard = 0;
            while (!irq && guard < 400000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (!irq) fail("timeout esperando irq");
        end
    endtask

    task wait_idle;
        integer guard;
        begin
            guard = 0;
            while (ctrl_busy && guard < 400000) begin
                @(posedge clk);
                guard = guard + 1;
            end
            if (ctrl_busy) fail("timeout esperando BUSY = 0");
        end
    endtask

    // Confere C contra o golden. Com strict = 1 tambem exige que cada palavra
    // de C tenha sido gravada uma unica vez (H7) e que nada fora de C mudou.
    task check_c;
        input [31:0]  c_base;
        input integer m, n;
        input         strict;
        integer i, j, idx, n_bad;
        reg is_c [0:16383];
        begin
            n_bad = 0;
            for (i = 0; i < 16384; i = i + 1) is_c[i] = 1'b0;
            for (i = 0; i < m; i = i + 1)
                for (j = 0; j < n; j = j + 1) begin
                    idx = c_base[15:2] + i * n + j;
                    is_c[idx] = 1'b1;
                    if (u_mem.mem[idx] !== cexp[i * n + j]) begin
                        n_bad = n_bad + 1;
                        if (n_bad <= 8)
                            $display("  C[%0d][%0d] = %h, esperado %h", i, j, u_mem.mem[idx], cexp[i * n + j]);
                    end
                    if (strict && u_mem.wr_count[idx] != 1) begin
                        n_bad = n_bad + 1;
                        if (n_bad <= 8)
                            $display("  C[%0d][%0d] gravado %0d vezes (H7)", i, j, u_mem.wr_count[idx]);
                    end
                end
            if (strict)
                for (i = 0; i < 16384; i = i + 1)
                    if (!is_c[i] && (u_mem.wr_count[i] != 0 || u_mem.mem[i] !== mem_init[i])) begin
                        n_bad = n_bad + 1;
                        if (n_bad <= 8)
                            $display("  palavra fora de C alterada: %h", 32'h1000_0000 + 4 * i);
                    end
            if (n_bad != 0) fail("conteudo de C / DMEM");
        end
    endtask

    // Uma operacao inteira: configura, da START, espera o irq e confere o STATUS.
    // exp_code = 0 quer dizer que a operacao tem que terminar sem erro.
    task run_op;
        input [31:0]  a, b, c;
        input integer m, n, k;
        input [3:0]   exp_code;
        output [31:0] cycles;
        begin
            configure(a, b, c, m, n, k);
            reg_wr(R_CTRL, CTRL_START | CTRL_IRQ_EN);
            wait_irq;
            reg_rd(R_STATUS, rd);
            if (exp_code == 4'd0) begin
                if (rd !== 32'h0000_0002) begin
                    $display("  STATUS = %h", rd);
                    fail("STATUS esperado DONE sem ERROR");
                end
            end else begin
                if (rd !== {24'd0, exp_code, 4'b0110}) begin
                    $display("  STATUS = %h, ERR_CODE esperado %0d", rd, exp_code);
                    fail("STATUS de erro");
                end
            end
            reg_rd(R_CYCLES, cycles);
            reg_wr(R_STATUS, 32'h0000_0006);        // limpa DONE e ERROR (W1C)
            @(posedge clk);
            if (irq !== 1'b0) fail("irq nao caiu com W1C");
        end
    endtask

    integer n_sr_abort = 0, n_sr_late = 0;

    // Dispara uma operacao e manda SOFT_RESET depois de "delay" ciclos
    task run_soft_reset;
        input integer delay;
        begin
            configure(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k);
            reg_wr(R_CTRL, CTRL_START | CTRL_IRQ_EN);
            repeat (delay) @(posedge clk);
            reg_wr(R_CTRL, CTRL_SOFT_RESET | CTRL_IRQ_EN);
            wait_idle;
            repeat (3) @(posedge clk);
            if (!u_chk_m1.idle) fail("transacao AXI pendurada depois do dreno");
            reg_rd(R_STATUS, rd);
            if (rd == 32'h0000_0002) begin
                // A operacao acabou antes do SOFT_RESET chegar. O pulso caiu em
                // IDLE e nao faz nada, entao DONE e irq estao certos.
                if (irq !== 1'b1) fail("DONE sem irq");
                n_sr_late = n_sr_late + 1;
                reg_wr(R_STATUS, 32'h2);
            end else if (rd == 32'd0) begin
                // Abortou: nem DONE, nem ERROR, nem irq
                if (irq !== 1'b0) fail("irq subiu depois de SOFT_RESET");
                n_sr_abort = n_sr_abort + 1;
            end else begin
                $display("  STATUS = %h", rd);
                fail("STATUS depois do SOFT_RESET");
            end
        end
    endtask

    integer    test = 0;
    integer    sr_step = 1;
    integer    i;
    reg [31:0] cycles, cycles2, cyc_compute, info;
    integer    ar0, aw0;

    initial begin
        if (!$value$plusargs("DMEM=%s", dmem_file)) dmem_file = "model/dmem.hex";
        if (!$value$plusargs("CEXP=%s", cexp_file)) cexp_file = "model/c_expected.hex";
        if ($value$plusargs("M=%d", dim_m)) ;
        if ($value$plusargs("N=%d", dim_n)) ;
        if ($value$plusargs("K=%d", dim_k)) ;
        if ($value$plusargs("TEST=%d", test)) ;
        if ($value$plusargs("SR_STEP=%d", sr_step)) ;
        if ($value$plusargs("SEED=%d", seed)) ;
        if ($test$plusargs("STALL")) stall_en = 1'b1;
        if ($test$plusargs("TRACE")) trace = 1'b1;
        if ($value$plusargs("VCD=%s", vcd_file)) begin
            $dumpfile(vcd_file);
            $dumpvars(0, tb_dma);
        end

        #1;
        $readmemh(dmem_file, u_mem.mem);
        for (i = 0; i < 4096; i = i + 1) cexp[i] = 32'hxxxx_xxxx;
        $readmemh(cexp_file, cexp, 0, dim_m * dim_n - 1);
        poison_padding(DEF_A, dim_m, dim_k);
        poison_padding(DEF_B, dim_k, dim_n);
        for (i = 0; i < 16384; i = i + 1) mem_init[i] = u_mem.mem[i];

        repeat (3) @(posedge clk);
        rst_n = 1'b1;
        repeat (2) @(posedge clk);

        reg_rd(R_INFO, info);
        if (info !== {3'd0, (PINGPONG != 0), 4'd2, 8'd32, 8'd8, 8'(T)}) fail("INFO");

        case (test)
            0, 9: begin
                // Operacao normal. O teste 9 (gravacao unica) e o mesmo, porque o
                // check_c estrito ja confere H7 em toda execucao.
                run_op(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k, 4'd0, cycles);
                reg_rd(R_CYC_COMPUTE, cyc_compute);
                check_c(DEF_C, dim_m, dim_n, 1'b1);
                $display("RESULT CYCLES=%0d CYC_COMPUTE=%0d", cycles, cyc_compute);
                if (cyc_compute !== ((dim_m + T - 1) / T) * ((dim_n + T - 1) / T)
                                    * ((dim_k + T - 1) / T) * (3 * T - 1))
                    fail("CYC_COMPUTE diferente de tiles * blocos * (3T - 1)");
            end

            1: begin   // DIM_K = 0: ERR_CODE 1 e nenhum acesso a memoria
                ar0 = u_chk_m1.ar_count; aw0 = u_chk_m1.aw_count;
                run_op(DEF_A, DEF_B, DEF_C, dim_m, dim_n, 0, 4'd1, cycles);
                if (u_chk_m1.ar_count != ar0 || u_chk_m1.aw_count != aw0)
                    fail("acesso a memoria com dimensao zero");
            end

            2: begin   // ADDR_B desalinhado: ERR_CODE 2 e nenhum acesso a memoria
                ar0 = u_chk_m1.ar_count; aw0 = u_chk_m1.aw_count;
                run_op(DEF_A, 32'h1000_4002, DEF_C, dim_m, dim_n, dim_k, 4'd2, cycles);
                if (u_chk_m1.ar_count != ar0 || u_chk_m1.aw_count != aw0)
                    fail("acesso a memoria com endereco desalinhado");
            end

            3, 7: begin   // ADDR_A fora da DMEM: SLVERR e ERR_CODE 3
                run_op(32'h1002_0000, DEF_B, DEF_C, dim_m, dim_n, dim_k, 4'd3, cycles);
                if (!u_chk_m1.idle) fail("transacao pendurada depois do erro");
                if (test == 7) begin
                    // uma operacao boa logo depois do erro prova que os bancos foram zerados
                    restore_mem;
                    run_op(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k, 4'd0, cycles);
                    check_c(DEF_C, dim_m, dim_n, 1'b1);
                end
            end

            4: begin   // ADDR_C sem slave: DECERR e ERR_CODE 4
                run_op(DEF_A, DEF_B, 32'h2000_0000, dim_m, dim_n, dim_k, 4'd4, cycles);
                if (!u_chk_m1.idle) fail("transacao pendurada depois do erro");
            end

            5: begin   // SOFT_RESET no meio da operacao
                run_op(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k, 4'd0, cycles);
                restore_mem;
                run_soft_reset(cycles / 2);
                if (n_sr_abort != 1) fail("SOFT_RESET no meio da operacao nao abortou");
                reg_rd(R_CYCLES, cycles);
                repeat (10) @(posedge clk);
                reg_rd(R_CYCLES, cycles2);
                if (cycles !== cycles2) fail("CYCLES nao congelou depois do SOFT_RESET");
                // e a operacao seguinte tem que sair certa
                restore_mem;
                run_op(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k, 4'd0, cycles);
                check_c(DEF_C, dim_m, dim_n, 1'b1);
            end

            6: begin   // SOFT_RESET em ciclos sucessivos, cobrindo todos os estados
                run_op(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k, 4'd0, cycles);
                for (i = 0; i <= cycles; i = i + sr_step)
                    run_soft_reset(i);
                restore_mem;
                run_op(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k, 4'd0, cycles);
                check_c(DEF_C, dim_m, dim_n, 1'b1);
                $display("  varredura: %0d abortadas, %0d terminaram antes do SOFT_RESET",
                         n_sr_abort, n_sr_late);
                if (n_sr_abort == 0) fail("varredura nao abortou nenhuma operacao");
            end

            8: begin   // SOFT_RESET em IDLE e em CHECK
                ar0 = u_chk_m1.ar_count; aw0 = u_chk_m1.aw_count;
                configure(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k);
                reg_wr(R_CTRL, CTRL_SOFT_RESET | CTRL_IRQ_EN);      // em IDLE
                repeat (5) @(posedge clk);
                if (ctrl_busy) fail("SOFT_RESET em IDLE tirou o DMA de IDLE");
                // CHECK dura um ciclo so, e uma escrita AXI nao consegue acertar
                // esse ciclo. Por isso o TB forca o sinal interno.
                fork
                    reg_wr(R_CTRL, CTRL_START | CTRL_IRQ_EN);
                    begin
                        @(posedge clk);
                        while (u_dma.u_ctrl.state_q != 3'd1) @(posedge clk);
                        #1 force u_dma.soft_reset = 1'b1;
                        @(posedge clk);
                        #1 release u_dma.soft_reset;
                    end
                join
                repeat (5) @(posedge clk);
                if (ctrl_busy) fail("SOFT_RESET em CHECK nao voltou a IDLE");
                if (u_chk_m1.ar_count != ar0 || u_chk_m1.aw_count != aw0)
                    fail("acesso a memoria depois de SOFT_RESET em CHECK");
                reg_rd(R_STATUS, rd);
                if (rd !== 32'd0) fail("STATUS depois de SOFT_RESET em CHECK");
                run_op(DEF_A, DEF_B, DEF_C, dim_m, dim_n, dim_k, 4'd0, cycles);
                check_c(DEF_C, dim_m, dim_n, 1'b1);
            end

            default: fail("TEST desconhecido");
        endcase

        repeat (5) @(posedge clk);
        if (u_chk_m1.violations != 0 || u_chk_s1.violations != 0)
            fail("violacoes do axi_checker");
        if (side_errors != 0)
            fail("protocolo entre DMA e acelerador");
`ifdef DMA_ASSERT
        if (u_dma.u_assert.n_fail != 0)
            fail("assercoes H1-H6 falharam");
`endif

        if (errors == 0)
            $display("TB_DMA T=%0d PP=%0d MB=%0d STALL=%0d TEST=%0d %0dx%0dx%0d: PASS CYCLES=%0d",
                     T, PINGPONG, MAX_BURST, stall_en, test, dim_m, dim_k, dim_n, cycles);
        else
            $display("TB_DMA T=%0d PP=%0d MB=%0d STALL=%0d TEST=%0d %0dx%0dx%0d: FAIL (%0d)",
                     T, PINGPONG, MAX_BURST, stall_en, test, dim_m, dim_k, dim_n, errors);
        $finish;
    end

endmodule

`default_nettype wire
