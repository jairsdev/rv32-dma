`timescale 1ns/1ps

// IMEM local (rtl/cpu/imem.v): carga por $readmemh e handshake da Porta I.
// Um master faz requisicoes em enderecos aleatorios (dentro e fora do programa),
// com intervalos de 0 a 2 ciclos entre elas, e confere:
//   - ready chega no ciclo seguinte ao valid e dura 1 ciclo; numa requisicao
//     colada na anterior (valid sem cair), a borda do ready anterior nao conta;
//   - rdata = palavra do .hex (0 fora do programa);
//   - ready fica em 0 durante o reset e sem requisicao.
module tb_imem;

  localparam PROG  = "tb/unit_cpu/programs/10_algoritmo_final.hex";
  localparam WORDS = 16384;
  localparam N_REQ = 3000;

  reg         clk = 0, rst_n = 0;
  reg         i_valid = 0;
  reg  [31:0] i_addr = 0;
  wire        i_ready;
  wire [31:0] i_rdata;

  reg [31:0] expected [0:WORDS-1];
  integer errors = 0, checks = 0, i, n, gap, seed = 3;
  reg [31:0] exp_word;

  always #5 clk = ~clk;

  imem #(.INIT_FILE(PROG)) dut (
    .clk(clk), .rst_n(rst_n), .i_valid(i_valid), .i_addr(i_addr),
    .i_ready(i_ready), .i_rdata(i_rdata)
  );

  task check(input [31:0] got, input [31:0] exp, input [8*16-1:0] name);
    begin
      checks = checks + 1;
      if (got !== exp) begin
        errors = errors + 1;
        $display("[ERRO] %0t %0s = %h, esperado %h (addr %h)", $time, name, got, exp, i_addr);
      end
    end
  endtask

  initial begin
    for (i = 0; i < WORDS; i = i + 1)
      expected[i] = 32'd0;
    $readmemh(PROG, expected);

    // valid em 1 durante o reset: ready nao pode subir
    i_valid = 1;
    repeat (3) begin
      @(posedge clk); #1;
      check(i_ready, 1'b0, "ready no reset");
    end
    @(negedge clk) begin
      rst_n   = 1;
      i_valid = 0;
    end

    gap = 1;
    for (n = 0; n < N_REQ; n = n + 1) begin
      // 3/4 das requisicoes no trecho do programa, 1/4 em qualquer lugar
      if ($random(seed) & 3)
        i_addr = {$unsigned($random(seed)) % 128, 2'b00};
      else
        i_addr = {$unsigned($random(seed)) % WORDS, 2'b00};
      exp_word = expected[i_addr[15:2]];
      i_valid  = 1;

      if (gap == 0) begin               // colada: a 1a borda e a do ready anterior
        @(posedge clk); #1;
        check(i_ready, 1'b0, "ready repetido");
      end
      @(posedge clk); #1;               // latencia de 1 ciclo
      check(i_ready, 1'b1, "ready");
      check(i_rdata, exp_word, "rdata");

      // proxima requisicao em seguida (gap = 0) ou depois de 1-2 ciclos ociosos
      gap = $unsigned($random(seed)) % 3;
      if (gap > 0) begin
        i_valid = 0;
        repeat (gap) begin
          @(posedge clk); #1;
          check(i_ready, 1'b0, "ready sem valid");
        end
      end
    end

    if (errors == 0)
      $display("tb_imem: PASSOU (%0d verificacoes)", checks);
    else
      $display("tb_imem: FALHOU (%0d erros em %0d verificacoes)", errors, checks);
    $finish;
  end

endmodule
