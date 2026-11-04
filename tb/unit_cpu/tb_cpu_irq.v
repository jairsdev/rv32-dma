`timescale 1ns/1ps

// CPU + IMEM rodando o fluxo do firmware (programs/13_dma_wfi.s): configura os
// registradores do DMA, dispara, dorme em wfi e acorda com o irq.
//
// A Porta D decodifica addr[31:28] como o axi_xbar (README, secao 3.1):
//   0x1 -> DMEM de 64 KiB; 0x4 -> modelo dos registradores do DMA (secao 3.2);
//   demais -> leitura 0 e escrita descartada (DECERR, secao 4.1).
// No modelo, START liga BUSY e o DMA termina DMA_CICLOS[n] ciclos depois
// (DONE = 1); irq = DONE & IRQ_EN; STATUS.DONE/ERROR sao W1C.
//
// Confere, alem de x31 = 1 e da parada no ebreak:
//   - os valores de ADDR_A/B/C e DIM_M/N/K escritos pela CPU;
//   - o primeiro wfi leva a CPU ao WAIT, sem acessos nas portas, e ela sai do
//     WAIT no primeiro ciclo com irq = 1;
//   - o segundo wfi (irq ja em 1) nao passa pelo WAIT;
//   - sb/sh com d_wstrb e dado na lane certos; irq em 0 no fim.
//   +DLAT=<n> latencia aleatoria de 0..n ciclos na Porta D (padrao 3)
module tb_cpu_irq;

  localparam PROG     = "tb/unit_cpu/programs/13_dma_wfi.hex";
  localparam PC_OK    = 32'h0000_014C;    // ebreak do fim com sucesso
  localparam S_FETCH  = 3'd0;
  localparam S_EXEC   = 3'd2;
  localparam S_WAIT   = 3'd5;
  localparam WFI      = 32'h1050_0073;
  localparam DWORDS   = 16384;

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  wire        i_valid, i_ready, d_valid, d_ready, halt;
  wire [31:0] i_addr, i_rdata, d_addr, d_wdata;
  reg  [31:0] d_rdata;
  wire [3:0]  d_wstrb;
  wire        irq;

  integer dlat = 3, seed = 7;
  integer errors = 0, checks = 0, cycles = 0, i;

  rv32i_cpu dut (
    .clk(clk), .rst_n(rst_n),
    .i_valid(i_valid), .i_addr(i_addr), .i_ready(i_ready), .i_rdata(i_rdata),
    .d_valid(d_valid), .d_addr(d_addr), .d_wstrb(d_wstrb), .d_wdata(d_wdata),
    .d_ready(d_ready), .d_rdata(d_rdata),
    .irq(irq), .halt(halt)
  );

  imem #(.INIT_FILE(PROG)) u_imem (
    .clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_addr(i_addr),
    .i_ready(i_ready), .i_rdata(i_rdata)
  );

  // ---------------------------------------------------------------- Porta D
  reg [31:0] dmem [0:DWORDS-1];
  integer    d_wait = 0;
  assign d_ready = d_valid && (d_wait == 0);

  wire        sel_mem  = (d_addr[31:28] == 4'h1);
  wire        sel_regs = (d_addr[31:28] == 4'h4);
  wire [31:0] mem_word = dmem[d_addr[15:2]];

  // Registradores do DMA
  reg        irq_en = 0, busy = 0, done = 0, error = 0;
  reg [31:0] addr_a = 0, addr_b = 0, addr_c = 0, dim_m = 0, dim_n = 0, dim_k = 0;
  integer    dma_cnt = 0, starts = 0;
  integer    DMA_CICLOS [0:2];
  initial begin
    DMA_CICLOS[0] = 200;   // 1a operacao: a CPU chega ao wfi antes do fim
    DMA_CICLOS[1] = 1;     // 2a: DONE sobe antes do wfi
    DMA_CICLOS[2] = 60;    // 3a: polling sem IRQ_EN
  end
  assign irq = done && irq_en;

  reg [31:0] reg_rd;
  always @(*) begin
    case (d_addr[11:2])
      10'h000: reg_rd = {30'd0, irq_en, 1'b0};
      10'h001: reg_rd = {29'd0, error, done, busy};
      10'h002: reg_rd = addr_a;
      10'h003: reg_rd = addr_b;
      10'h004: reg_rd = addr_c;
      10'h005: reg_rd = dim_m;
      10'h006: reg_rd = dim_n;
      10'h007: reg_rd = dim_k;
      default: reg_rd = 32'd0;
    endcase
    if (!d_ready)      d_rdata = 32'hxxxx_xxxx;
    else if (sel_mem)  d_rdata = mem_word;
    else if (sel_regs) d_rdata = reg_rd;
    else               d_rdata = 32'd0;
  end

  wire wr = d_ready && (d_wstrb != 4'b0000);

  always @(posedge clk) begin
    if (!d_valid || d_ready)
      d_wait <= (dlat > 0) ? $unsigned($random(seed)) % (dlat + 1) : 0;
    else if (d_wait > 0)
      d_wait <= d_wait - 1;

    if (wr && sel_mem)
      dmem[d_addr[15:2]] <= { d_wstrb[3] ? d_wdata[31:24] : mem_word[31:24],
                              d_wstrb[2] ? d_wdata[23:16] : mem_word[23:16],
                              d_wstrb[1] ? d_wdata[15:8]  : mem_word[15:8],
                              d_wstrb[0] ? d_wdata[7:0]   : mem_word[7:0] };

    // operacao do DMA em andamento
    if (busy) begin
      if (dma_cnt <= 1) begin
        busy <= 0;
        done <= 1;
      end
      dma_cnt <= dma_cnt - 1;
    end

    if (wr && sel_regs) begin
      case (d_addr[11:2])
        10'h000: begin
          irq_en <= d_wdata[1];
          if (d_wdata[0] && !busy) begin
            busy    <= 1;
            dma_cnt <= DMA_CICLOS[starts];
            starts  <= starts + 1;
          end
        end
        10'h001: begin                  // W1C
          if (d_wdata[1]) done  <= 0;
          if (d_wdata[2]) error <= 0;
        end
        10'h002: if (!busy) addr_a <= d_wdata;
        10'h003: if (!busy) addr_b <= d_wdata;
        10'h004: if (!busy) addr_c <= d_wdata;
        10'h005: if (!busy) dim_m  <= d_wdata;
        10'h006: if (!busy) dim_n  <= d_wdata;
        10'h007: if (!busy) dim_k  <= d_wdata;
        default: ;
      endcase
    end
  end

  // ------------------------------------------------------------- Monitores
  wire [2:0] state = dut.u_controller.state;
  integer wfis = 0, wait_ciclos = 0, wait_entradas = 0, acordou = 0;
  integer wfi_ciclo [0:1];
  reg     em_wait_q = 0, irq_q = 0;
  reg     sb_ok = 0, sh_ok = 0;

  always @(posedge clk) begin
    if (rst_n) begin
      cycles = cycles + 1;

      if (state == S_EXEC && dut.ir == WFI) begin
        if (wfis < 2) wfi_ciclo[wfis] = wait_ciclos;
        wfis = wfis + 1;
      end

      if (state == S_WAIT) begin
        wait_ciclos = wait_ciclos + 1;
        if (!em_wait_q) wait_entradas = wait_entradas + 1;
        if (i_valid || d_valid) begin
          errors = errors + 1;
          $display("[ERRO] %0t acesso nas portas durante o WAIT", $time);
        end
      end

      // o ciclo seguinte a uma borda com WAIT e irq = 1 tem de ser FETCH
      if (em_wait_q && irq_q) begin
        if (state != S_FETCH) begin
          errors = errors + 1;
          $display("[ERRO] %0t irq = 1 e a CPU nao saiu do WAIT", $time);
        end else
          acordou = acordou + 1;
      end

      if (wr && d_addr == 32'h1000_0001)
        sb_ok = (d_wstrb === 4'b0010) && (d_wdata[15:8] === 8'hAA);
      if (wr && d_addr == 32'h1000_0002)
        sh_ok = (d_wstrb === 4'b1100) && (d_wdata[31:16] === 16'hBBCC);
    end
    em_wait_q <= rst_n && (state == S_WAIT);
    irq_q     <= irq;
  end

  task check(input [31:0] got, input [31:0] exp, input [8*24-1:0] name);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("[ERRO] %0s = %h, esperado %h", name, got, exp);
      end
    end
  endtask

  initial begin
    if (!$value$plusargs("DLAT=%d", dlat)) dlat = 3;
    for (i = 0; i < DWORDS; i = i + 1)
      dmem[i] = 32'd0;

    repeat (3) @(posedge clk);
    @(negedge clk) rst_n = 1;

    while (halt !== 1'b1 && cycles < 20000)
      @(posedge clk);
    repeat (20) @(posedge clk);
    #1;

    check(halt, 1'b1, "halt");
    check(dut.pc, PC_OK, "pc no ebreak");
    check(dut.u_reg_bank.mem[31], 32'd1, "x31 (status)");
    if (dut.u_reg_bank.mem[31] === 32'hBAD)
      $display("[ERRO] o programa detectou falha no subteste x30 = %0d", dut.u_reg_bank.mem[30]);

    check(addr_a, 32'h1000_1000, "ADDR_A");
    check(addr_b, 32'h1000_4000, "ADDR_B");
    check(addr_c, 32'h1000_8000, "ADDR_C");
    check(dim_m,  32'd6, "DIM_M");
    check(dim_n,  32'd7, "DIM_N");
    check(dim_k,  32'd5, "DIM_K");
    check(starts, 3, "operacoes disparadas");

    check(wfis, 2, "wfi executados");
    check(wait_entradas, 1, "entradas no WAIT");
    check(acordou, 1, "saidas do WAIT por irq");
    check(wfi_ciclo[1] - wfi_ciclo[0] > 0, 1, "1o wfi esperou");
    check(wait_ciclos - wfi_ciclo[1], 0, "2o wfi nao esperou");
    check(sb_ok, 1, "sb: wstrb e lane");
    check(sh_ok, 1, "sh: wstrb e lane");
    check(irq, 1'b0, "irq no fim");

    if (errors == 0)
      $display("tb_cpu_irq: PASSOU (%0d verificacoes, %0d ciclos, %0d no WAIT)", checks, cycles, wait_ciclos);
    else
      $display("tb_cpu_irq: FALHOU (%0d erros em %0d verificacoes)", errors, checks);
    $finish;
  end

endmodule
