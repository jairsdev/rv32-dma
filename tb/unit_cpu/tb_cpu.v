`timescale 1ns/1ps

// CPU multiciclo + IMEM: roda um programa de tb/unit_cpu/programs/ e confere o
// estado final com o simulador de referencia (<TEST>.regs: x0..x31 e PC final).
//
//   +TEST=<nome>  programa (padrao: 01_alu_reg)
//   +ILAT=<n>     espera extra aleatoria de 0..n ciclos antes da IMEM aceitar a busca
//   +DLAT=<n>     latencia aleatoria de 0..n ciclos na Porta D (0 = ready no mesmo ciclo)
//   +SEED=<n>     semente das latencias
//
// A Porta D e um modelo de memoria de 64 KiB (addr[15:2]) que respeita d_wstrb.
// Um monitor confere o protocolo das duas portas: depois de valid = 1 sem ready,
// valid e endereco/dados ficam estaveis ate o ready; i_addr alinhado a 4;
// I e D nunca ao mesmo tempo.
// O programa termina no laco "fim: j fim" (0000006F) ou em ecall/ebreak (halt).
// Execute a partir da raiz do repositorio (scripts/run_cpu_tests.sh).
module tb_cpu;

  localparam MAX_CYCLES = 100000;
  localparam LOOP_END   = 32'h0000_006F;   // jal x0, 0
  localparam EXTRA      = 40;              // ciclos observados depois do fim
  localparam DWORDS     = 16384;           // 64 KiB

  reg clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  wire        i_valid, i_ready, d_valid, d_ready, halt;
  wire [31:0] i_addr, i_rdata, d_addr, d_wdata, d_rdata;
  wire [3:0]  d_wstrb;

  reg [8*64-1:0]  test;
  reg [8*128-1:0] hex_file, regs_file;
  reg [31:0]      expected [0:32];
  integer ilat = 0, dlat = 0, seed = 1;
  integer errors = 0, checks = 0, cycles = 0, retired = 0;
  integer n_cycles, n_instr;
  integer fd, i;
  reg [31:0] pc_end;
  reg        fim = 0;

  rv32i_cpu dut (
    .clk(clk), .rst_n(rst_n),
    .i_valid(i_valid), .i_addr(i_addr), .i_ready(i_ready), .i_rdata(i_rdata),
    .d_valid(d_valid), .d_addr(d_addr), .d_wstrb(d_wstrb), .d_wdata(d_wdata),
    .d_ready(d_ready), .d_rdata(d_rdata),
    .irq(1'b0), .halt(halt)
  );

  // Porta I: a IMEM so ve o valid depois de i_wait ciclos (latencia variavel)
  integer i_wait = 0;
  wire    imem_valid = i_valid && (i_wait == 0);

  imem u_imem (
    .clk(clk), .rst_n(rst_n), .i_valid(imem_valid), .i_addr(i_addr),
    .i_ready(i_ready), .i_rdata(i_rdata)
  );

  always @(posedge clk) begin
    if (!i_valid || i_ready)
      i_wait <= (ilat > 0) ? $unsigned($random(seed)) % (ilat + 1) : 0;
    else if (i_wait > 0)
      i_wait <= i_wait - 1;
  end

  // Porta D: memoria com latencia aleatoria; rdata so e valido com ready
  reg [31:0] dmem [0:DWORDS-1];
  integer    d_wait = 0;
  wire [31:0] d_word = dmem[d_addr[15:2]];

  assign d_ready = d_valid && (d_wait == 0);
  assign d_rdata = d_ready ? d_word : 32'hxxxx_xxxx;

  always @(posedge clk) begin
    if (!d_valid || d_ready)
      d_wait <= (dlat > 0) ? $unsigned($random(seed)) % (dlat + 1) : 0;
    else if (d_wait > 0)
      d_wait <= d_wait - 1;

    if (d_ready && d_wstrb != 4'b0000)
      dmem[d_addr[15:2]] <= { d_wstrb[3] ? d_wdata[31:24] : d_word[31:24],
                              d_wstrb[2] ? d_wdata[23:16] : d_word[23:16],
                              d_wstrb[1] ? d_wdata[15:8]  : d_word[15:8],
                              d_wstrb[0] ? d_wdata[7:0]   : d_word[7:0] };
  end

  // Monitor do protocolo valid/ready
  reg        i_pend = 0, d_pend = 0;
  reg [31:0] i_addr_q, d_addr_q, d_wdata_q;
  reg [3:0]  d_wstrb_q;

  always @(posedge clk) begin
    if (rst_n) begin
      if (i_pend && (i_valid !== 1'b1 || i_addr !== i_addr_q)) begin
        errors = errors + 1;
        $display("[ERRO] %0t Porta I: valid/addr mudou antes do ready", $time);
      end
      if (d_pend && (d_valid !== 1'b1 || d_addr !== d_addr_q ||
                     d_wstrb !== d_wstrb_q || d_wdata !== d_wdata_q)) begin
        errors = errors + 1;
        $display("[ERRO] %0t Porta D: valid/addr/wstrb/wdata mudou antes do ready", $time);
      end
      if (i_valid && i_addr[1:0] != 2'b00) begin
        errors = errors + 1;
        $display("[ERRO] %0t Porta I: i_addr = %h desalinhado", $time, i_addr);
      end
      if (i_valid && d_valid) begin
        errors = errors + 1;
        $display("[ERRO] %0t Portas I e D ativas ao mesmo tempo", $time);
      end
    end
    i_pend    <= rst_n && i_valid && !i_ready;
    d_pend    <= rst_n && d_valid && !d_ready;
    i_addr_q  <= i_addr;
    d_addr_q  <= d_addr;
    d_wstrb_q <= d_wstrb;
    d_wdata_q <= d_wdata;
  end

  // Contadores e deteccao do laco final
  always @(posedge clk) begin
    if (rst_n) begin
      cycles = cycles + 1;
      if (dut.pc_we) retired = retired + 1;
      if (i_ready && i_rdata === LOOP_END) fim = 1;
    end
  end

  function [31:0] reg_x(input integer r);
    reg_x = (r == 0) ? 32'd0 : dut.u_reg_bank.mem[r];
  endfunction

  task check(input [31:0] got, input [31:0] exp, input [8*16-1:0] name);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("[ERRO] %0s = %h, esperado %h", name, got, exp);
      end
    end
  endtask

  initial begin
    if (!$value$plusargs("TEST=%s", test)) test = "01_alu_reg";
    if (!$value$plusargs("ILAT=%d", ilat)) ilat = 0;
    if (!$value$plusargs("DLAT=%d", dlat)) dlat = 0;
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    $sformat(hex_file,  "tb/unit_cpu/programs/%0s.hex",  test);
    $sformat(regs_file, "tb/unit_cpu/programs/%0s.regs", test);

    fd = $fopen(hex_file, "r");
    if (fd == 0) begin
      $display("tb_cpu %0s: FALHOU (programa nao encontrado: %0s)", test, hex_file);
      $finish;
    end
    $fclose(fd);

    for (i = 0; i < DWORDS; i = i + 1)
      dmem[i] = 32'd0;
    #1;
    $readmemh(hex_file, u_imem.mem);
    $readmemh(regs_file, expected);

    repeat (3) @(posedge clk);
    @(negedge clk) rst_n = 1;

    while (!fim && halt !== 1'b1 && cycles < MAX_CYCLES)
      @(posedge clk);

    n_cycles = cycles;
    n_instr  = retired;
    if (!fim && halt !== 1'b1) begin
      errors = errors + 1;
      $display("[ERRO] %0s: nao chegou ao fim em %0d ciclos (pc=%h)", test, MAX_CYCLES, dut.pc);
    end

    // Depois do fim, o PC nao sai do lugar (laco em si mesmo ou HALT)
    repeat (EXTRA) @(posedge clk);
    #1;
    pc_end = dut.pc;
    repeat (EXTRA) @(posedge clk);
    #1;
    check(dut.pc, pc_end, "pc parado");

    check(reg_x(31), 32'd1, "x31 (status)");
    if (reg_x(31) === 32'hBAD)
      $display("[ERRO] %0s: o programa detectou falha no subteste x30 = %0d", test, reg_x(30));
    check(dut.pc, expected[32], "pc final");
    for (i = 0; i < 32; i = i + 1)
      check(reg_x(i), expected[i], "registrador");

    if (errors != 0)
      for (i = 0; i < 32; i = i + 1)
        if (reg_x(i) !== expected[i])
          $display("    x%0d = %h / esperado %h", i, reg_x(i), expected[i]);

    if (errors == 0)
      $display("tb_cpu %0s ILAT=%0d DLAT=%0d: PASSOU (%0d verificacoes, %0d instrucoes, %0d ciclos)",
               test, ilat, dlat, checks, n_instr, n_cycles);
    else
      $display("tb_cpu %0s ILAT=%0d DLAT=%0d: FALHOU (%0d erros em %0d verificacoes)",
               test, ilat, dlat, errors, checks);
    $finish;
  end

endmodule
