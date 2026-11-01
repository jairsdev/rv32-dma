`timescale 1ns/1ps

// Testbench unitario do acelerador (systolic array).
// Simula o comportamento do DMA injetando dados via interface sideband,
// disparando o processamento do tile e conferindo a matriz C resultante.
// Valida o funcionamento para ARRAY_SIZE = 2 e ARRAY_SIZE = 4.
module tb_accel;

    reg clk;
    reg rst_n;
    integer total_errors = 0;

    // Gerador de clock (periodo = 10ns -> 100 MHz)
    always #5 clk = ~clk;

    // =========================================================================
    // 1. Instanciacao e sinais para ARRAY_SIZE = 2
    // =========================================================================
    localparam T2 = 2;
    localparam IW2 = 1;

    reg             t2_buf_a_we, t2_buf_b_we;
    reg  [IW2-1:0]  t2_buf_row, t2_buf_col;
    reg  [7:0]      t2_buf_wdata;
    reg             t2_tile_start, t2_first_k;
    wire            t2_busy, t2_tile_done;
    reg             t2_c_rd;
    reg  [IW2-1:0]  t2_c_row, t2_c_col;
    wire [31:0]     t2_c_rdata;

    accel #(.ARRAY_SIZE(T2)) u_accel_2x2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .buf_a_we   (t2_buf_a_we),
        .buf_b_we   (t2_buf_b_we),
        .buf_row    (t2_buf_row),
        .buf_col    (t2_buf_col),
        .buf_wdata  (t2_buf_wdata),
        .tile_start (t2_tile_start),
        .first_k    (t2_first_k),
        .busy       (t2_busy),
        .tile_done  (t2_tile_done),
        .c_rd       (t2_c_rd),
        .c_row      (t2_c_row),
        .c_col      (t2_c_col),
        .c_rdata    (t2_c_rdata)
    );

    // =========================================================================
    // 2. Instanciacao e sinais para ARRAY_SIZE = 4
    // =========================================================================
    localparam T4 = 4;
    localparam IW4 = 2;

    reg             t4_buf_a_we, t4_buf_b_we;
    reg  [IW4-1:0]  t4_buf_row, t4_buf_col;
    reg  [7:0]      t4_buf_wdata;
    reg             t4_tile_start, t4_first_k;
    wire            t4_busy, t4_tile_done;
    reg             t4_c_rd;
    reg  [IW4-1:0]  t4_c_row, t4_c_col;
    wire [31:0]     t4_c_rdata;

    accel #(.ARRAY_SIZE(T4)) u_accel_4x4 (
        .clk        (clk),
        .rst_n      (rst_n),
        .buf_a_we   (t4_buf_a_we),
        .buf_b_we   (t4_buf_b_we),
        .buf_row    (t4_buf_row),
        .buf_col    (t4_buf_col),
        .buf_wdata  (t4_buf_wdata),
        .tile_start (t4_tile_start),
        .first_k    (t4_first_k),
        .busy       (t4_busy),
        .tile_done  (t4_tile_done),
        .c_rd       (t4_c_rd),
        .c_row      (t4_c_row),
        .c_col      (t4_c_col),
        .c_rdata    (t4_c_rdata)
    );

    // =========================================================================
    // Tarefas auxiliares para o teste 2x2
    // =========================================================================
    task write_buf_a_2x2(input [0:0] r, input [0:0] c, input signed [7:0] val);
        begin
            @(posedge clk);
            t2_buf_a_we  <= 1'b1;
            t2_buf_row   <= r;
            t2_buf_col   <= c;
            t2_buf_wdata <= val;
            @(posedge clk);
            t2_buf_a_we  <= 1'b0;
        end
    endtask

    task write_buf_b_2x2(input [0:0] r, input [0:0] c, input signed [7:0] val);
        begin
            @(posedge clk);
            t2_buf_b_we  <= 1'b1;
            t2_buf_row   <= r;
            t2_buf_col   <= c;
            t2_buf_wdata <= val;
            @(posedge clk);
            t2_buf_b_we  <= 1'b0;
        end
    endtask

    task start_tile_2x2(input first);
        begin
            @(posedge clk);
            t2_tile_start <= 1'b1;
            t2_first_k    <= first;
            @(posedge clk);
            t2_tile_start <= 1'b0;
            t2_first_k    <= 1'b0;

            // Aguarda o pulso de conclusao
            @(posedge t2_tile_done);
            @(posedge clk);
        end
    endtask

    task check_c_2x2(input [0:0] r, input [0:0] c, input signed [31:0] expected);
        begin
            @(posedge clk);
            t2_c_rd  <= 1'b1;
            t2_c_row <= r;
            t2_c_col <= c;
            @(posedge clk);
            t2_c_rd  <= 1'b0;
            @(posedge clk); // c_rdata valido 1 ciclo apos c_rd

            if ($signed(t2_c_rdata) !== expected) begin
                $display("  [ERRO 2x2] C[%0d][%0d]: obtido=%0d, esperado=%0d", r, c, $signed(t2_c_rdata), expected);
                total_errors = total_errors + 1;
            end else begin
                $display("  [OK 2x2]   C[%0d][%0d] = %0d", r, c, $signed(t2_c_rdata));
            end
        end
    endtask

    // =========================================================================
    // Tarefas auxiliares para o teste 4x4
    // =========================================================================
    task write_buf_a_4x4(input [1:0] r, input [1:0] c, input signed [7:0] val);
        begin
            @(posedge clk);
            t4_buf_a_we  <= 1'b1;
            t4_buf_row   <= r;
            t4_buf_col   <= c;
            t4_buf_wdata <= val;
            @(posedge clk);
            t4_buf_a_we  <= 1'b0;
        end
    endtask

    task write_buf_b_4x4(input [1:0] r, input [1:0] c, input signed [7:0] val);
        begin
            @(posedge clk);
            t4_buf_b_we  <= 1'b1;
            t4_buf_row   <= r;
            t4_buf_col   <= c;
            t4_buf_wdata <= val;
            @(posedge clk);
            t4_buf_b_we  <= 1'b0;
        end
    endtask

    task start_tile_4x4(input first);
        begin
            @(posedge clk);
            t4_tile_start <= 1'b1;
            t4_first_k    <= first;
            @(posedge clk);
            t4_tile_start <= 1'b0;
            t4_first_k    <= 1'b0;

            @(posedge t4_tile_done);
            @(posedge clk);
        end
    endtask

    task check_c_4x4(input [1:0] r, input [1:0] c, input signed [31:0] expected);
        begin
            @(posedge clk);
            t4_c_rd  <= 1'b1;
            t4_c_row <= r;
            t4_c_col <= c;
            @(posedge clk);
            t4_c_rd  <= 1'b0;
            @(posedge clk);

            if ($signed(t4_c_rdata) !== expected) begin
                $display("  [ERRO 4x4] C[%0d][%0d]: obtido=%0d, esperado=%0d", r, c, $signed(t4_c_rdata), expected);
                total_errors = total_errors + 1;
            end else begin
                $display("  [OK 4x4]   C[%0d][%0d] = %0d", r, c, $signed(t4_c_rdata));
            end
        end
    endtask

    // =========================================================================
    // Sequencia principal de testes
    // =========================================================================
    initial begin
        clk   = 0;
        rst_n = 0;

        t2_buf_a_we = 0; t2_buf_b_we = 0; t2_buf_row = 0; t2_buf_col = 0; t2_buf_wdata = 0;
        t2_tile_start = 0; t2_first_k = 0; t2_c_rd = 0; t2_c_row = 0; t2_c_col = 0;

        t4_buf_a_we = 0; t4_buf_b_we = 0; t4_buf_row = 0; t4_buf_col = 0; t4_buf_wdata = 0;
        t4_tile_start = 0; t4_first_k = 0; t4_c_rd = 0; t4_c_row = 0; t4_c_col = 0;

        $display("Iniciando simulacao do testbench unitario do acelerador...");

        // Pulso de reset global
        #20;
        @(posedge clk);
        rst_n = 1;
        #10;

        // ---------------------------------------------------------------------
        // TESTE 1: Malha 2x2 — Multiplicacao basica (1 tile)
        // A = [[2, 3], [4, -1]]
        // B = [[1, 2], [3,  4]]
        // C esperado = A x B:
        // C[0][0] = 2*1 + 3*3 = 11
        // C[0][1] = 2*2 + 3*4 = 16
        // C[1][0] = 4*1 + (-1)*3 = 1
        // C[1][1] = 4*2 + (-1)*4 = 4
        // ---------------------------------------------------------------------
        $display("\n--- Teste 1: Malha 2x2 (1 tile basico) ---");

        write_buf_a_2x2(0, 0, 8'sd2);
        write_buf_a_2x2(0, 1, 8'sd3);
        write_buf_a_2x2(1, 0, 8'sd4);
        write_buf_a_2x2(1, 1, -8'sd1);

        write_buf_b_2x2(0, 0, 8'sd1);
        write_buf_b_2x2(0, 1, 8'sd2);
        write_buf_b_2x2(1, 0, 8'sd3);
        write_buf_b_2x2(1, 1, 8'sd4);

        start_tile_2x2(1'b1); // first_k = 1

        check_c_2x2(0, 0, 32'sd11);
        check_c_2x2(0, 1, 32'sd16);
        check_c_2x2(1, 0, 32'sd1);
        check_c_2x2(1, 1, 32'sd4);

        // ---------------------------------------------------------------------
        // TESTE 2: Malha 2x2 — Multiplicacao com 2 blocos de K (acumulacao)
        // Bloco k0 = 0 (first_k = 1):
        // A_0 = [[1, 2], [3, 4]], B_0 = [[5, 6], [7, 8]]
        // C_0 = [[19, 22], [43, 50]]
        // Bloco k0 = 2 (first_k = 0):
        // A_1 = [[-1, 1], [2, -2]], B_1 = [[1, -1], [2, 1]]
        // Parcial = [[1, 2], [-2, -4]]
        // C_final = C_0 + Parcial = [[20, 24], [41, 46]]
        // ---------------------------------------------------------------------
        $display("\n--- Teste 2: Malha 2x2 (acumulando 2 blocos de K) ---");

        // Bloco 0
        write_buf_a_2x2(0, 0, 8'sd1); write_buf_a_2x2(0, 1, 8'sd2);
        write_buf_a_2x2(1, 0, 8'sd3); write_buf_a_2x2(1, 1, 8'sd4);
        write_buf_b_2x2(0, 0, 8'sd5); write_buf_b_2x2(0, 1, 8'sd6);
        write_buf_b_2x2(1, 0, 8'sd7); write_buf_b_2x2(1, 1, 8'sd8);
        start_tile_2x2(1'b1);

        // Bloco 1 (sem zerar acc: first_k = 0)
        write_buf_a_2x2(0, 0, -8'sd1); write_buf_a_2x2(0, 1, 8'sd1);
        write_buf_a_2x2(1, 0, 8'sd2);  write_buf_a_2x2(1, 1, -8'sd2);
        write_buf_b_2x2(0, 0, 8'sd1);  write_buf_b_2x2(0, 1, -8'sd1);
        write_buf_b_2x2(1, 0, 8'sd2);  write_buf_b_2x2(1, 1, 8'sd1);
        start_tile_2x2(1'b0);

        check_c_2x2(0, 0, 32'sd20);
        check_c_2x2(0, 1, 32'sd24);
        check_c_2x2(1, 0, 32'sd41);
        check_c_2x2(1, 1, 32'sd46);

        // ---------------------------------------------------------------------
        // TESTE 3: Malha 4x4 — Multiplicacao basica (1 tile completo)
        // Testando matriz identidade 4x4: B = I_4 -> C = A
        // A com valores variados (positivos e negativos)
        // ---------------------------------------------------------------------
        $display("\n--- Teste 3: Malha 4x4 (matriz identidade: B = I -> C = A) ---");

        // Preenche A
        write_buf_a_4x4(0, 0, 8'sd10);  write_buf_a_4x4(0, 1, -8'sd20); write_buf_a_4x4(0, 2, 8'sd30);  write_buf_a_4x4(0, 3, -8'sd40);
        write_buf_a_4x4(1, 0, 8'sd15);  write_buf_a_4x4(1, 1, 8'sd25);  write_buf_a_4x4(1, 2, -8'sd35); write_buf_a_4x4(1, 3, 8'sd45);
        write_buf_a_4x4(2, 0, -8'sd5);  write_buf_a_4x4(2, 1, 8'sd0);   write_buf_a_4x4(2, 2, 8'sd50);  write_buf_a_4x4(2, 3, -8'sd50);
        write_buf_a_4x4(3, 0, 8'sd100); write_buf_a_4x4(3, 1, -8'sd80); write_buf_a_4x4(3, 2, 8'sd60);  write_buf_a_4x4(3, 3, -8'sd40);

        // Preenche B com matriz identidade I_4
        write_buf_b_4x4(0, 0, 8'sd1); write_buf_b_4x4(0, 1, 8'sd0); write_buf_b_4x4(0, 2, 8'sd0); write_buf_b_4x4(0, 3, 8'sd0);
        write_buf_b_4x4(1, 0, 8'sd0); write_buf_b_4x4(1, 1, 8'sd1); write_buf_b_4x4(1, 2, 8'sd0); write_buf_b_4x4(1, 3, 8'sd0);
        write_buf_b_4x4(2, 0, 8'sd0); write_buf_b_4x4(2, 1, 8'sd0); write_buf_b_4x4(2, 2, 8'sd1); write_buf_b_4x4(2, 3, 8'sd0);
        write_buf_b_4x4(3, 0, 8'sd0); write_buf_b_4x4(3, 1, 8'sd0); write_buf_b_4x4(3, 2, 8'sd0); write_buf_b_4x4(3, 3, 8'sd1);

        start_tile_4x4(1'b1);

        // Confere se C == A
        check_c_4x4(0, 0, 32'sd10);  check_c_4x4(0, 1, -32'sd20); check_c_4x4(0, 2, 32'sd30);  check_c_4x4(0, 3, -32'sd40);
        check_c_4x4(1, 0, 32'sd15);  check_c_4x4(1, 1, 32'sd25);  check_c_4x4(1, 2, -32'sd35); check_c_4x4(1, 3, 32'sd45);
        check_c_4x4(2, 0, -32'sd5);  check_c_4x4(2, 1, 32'sd0);   check_c_4x4(2, 2, 32'sd50);  check_c_4x4(2, 3, -32'sd50);
        check_c_4x4(3, 0, 32'sd100); check_c_4x4(3, 1, -32'sd80); check_c_4x4(3, 2, 32'sd60);  check_c_4x4(3, 3, -32'sd40);

        // ---------------------------------------------------------------------
        // Finalizacao e relatorio
        // ---------------------------------------------------------------------
        #50;
        $display("\n=================================================");
        if (total_errors == 0) begin
            $display("  SUCESSO: Todos os testes passaram sem erros!");
        end else begin
            $display("  FALHA: %0d erros encontrados durante o teste.", total_errors);
        end
        $display("=================================================\n");

        $finish;
    end

endmodule

