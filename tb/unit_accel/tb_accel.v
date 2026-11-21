`timescale 1ns/1ps

module tb_accel;

    parameter ARRAY_SIZE = 4;
    parameter PINGPONG   = 1;

    localparam T      = ARRAY_SIZE;
    localparam IW     = (T > 1) ? $clog2(T) : 1;
    localparam WPR    = (T + 3) / 4;
    localparam WW     = (WPR > 1) ? $clog2(WPR) : 1;
    localparam CYCLES = 3 * T - 1;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #5 clk = ~clk;

    integer errors = 0;
    integer checks = 0;

    reg           buf_a_we = 0, buf_b_we = 0, buf_bank = 0;
    reg  [IW-1:0] buf_row = 0;
    reg  [WW-1:0] buf_word = 0;
    reg  [31:0]   buf_wdata = 0;
    reg           tile_start = 0, tile_bank = 0, first_k = 0, last_k = 0;
    wire          busy, acc_active, tile_done, c_valid;
    reg           c_release = 0;
    reg           c_rd = 0;
    reg  [IW-1:0] c_row = 0, c_col = 0;
    wire [31:0]   c_rdata;

    accel #(.ARRAY_SIZE(T), .PINGPONG(PINGPONG)) dut (
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
        .busy       (busy),
        .acc_active (acc_active),
        .tile_done  (tile_done),
        .c_valid    (c_valid),
        .c_release  (c_release),
        .c_rd       (c_rd),
        .c_row      (c_row),
        .c_col      (c_col),
        .c_rdata    (c_rdata)
    );

    // O que o TB espera encontrar dentro do acelerador
    integer ref_a   [0:1][0:T-1][0:T-1];
    integer ref_b   [0:1][0:T-1][0:T-1];
    integer ref_acc [0:T-1][0:T-1];
    integer ref_c   [0:T-1][0:T-1];

    integer i, j, k, w, l;

    // com PINGPONG = 0 so existe o banco 0
    function integer bank_of(input integer b);
        bank_of = (PINGPONG != 0) ? b : 0;
    endfunction

    task ref_tile(input integer b, input integer fk);
        integer s;
        begin
            for (i = 0; i < T; i = i + 1)
                for (j = 0; j < T; j = j + 1) begin
                    s = fk ? 0 : ref_acc[i][j];
                    for (k = 0; k < T; k = k + 1)
                        s = s + ref_a[bank_of(b)][i][k] * ref_b[bank_of(b)][k][j];
                    ref_acc[i][j] = s;
                end
        end
    endtask

    task ref_publish;
        begin
            for (i = 0; i < T; i = i + 1)
                for (j = 0; j < T; j = j + 1)
                    ref_c[i][j] = ref_acc[i][j];
        end
    endtask

    // Conta quantos ciclos a malha ficou calculando em cada tile e confere,
    // a cada tile_done, que foram 3T-1 e que c_valid subiu junto quando era last_k.
    integer active_cnt = 0;
    integer tiles_done = 0;
    reg     expect_cvalid_on_done = 0;

    always @(posedge clk) begin
        if (rst_n) begin
            if (acc_active)
                active_cnt = active_cnt + 1;
            if (tile_done) begin
                tiles_done = tiles_done + 1;
                checks = checks + 1;
                if (active_cnt != CYCLES) begin
                    errors = errors + 1;
                    $display("[%0t] ERRO: acc_active ficou %0d ciclos em 1 (esperado %0d)", $time, active_cnt, CYCLES);
                end
                active_cnt = 0;
                if (expect_cvalid_on_done && !c_valid) begin
                    errors = errors + 1;
                    $display("[%0t] ERRO: c_valid nao subiu junto com tile_done", $time);
                end
            end
            if (acc_active && !busy) begin
                errors = errors + 1;
                $display("[%0t] ERRO: acc_active = 1 com busy = 0", $time);
            end
        end
    end

    // Manda uma palavra de 32 bits para o buffer de A (is_b = 0) ou de B
    task send_word(input integer is_b, input integer b, input integer r, input integer wd,
                   input [31:0] data);
        begin
            @(posedge clk);
            buf_a_we  <= (is_b == 0);
            buf_b_we  <= (is_b != 0);
            buf_bank  <= b[0];
            buf_row   <= r[IW-1:0];
            buf_word  <= wd[WW-1:0];
            buf_wdata <= data;
        end
    endtask

    task stop_writes;
        begin
            @(posedge clk);
            buf_a_we <= 1'b0;
            buf_b_we <= 1'b0;
        end
    endtask

    // Gera uma matriz (mode 0: aleatoria, mode 1: tudo -128), guarda na
    // referencia e manda para o banco b. Os bytes que caem em coluna >= T
    // levam lixo de proposito, para provar que o acelerador ignora.
    task write_mat(input integer is_b, input integer b, input integer mode,
                   input integer seed);
        integer v;
        reg [31:0] word;
        begin
            for (i = 0; i < T; i = i + 1) begin
                for (w = 0; w < WPR; w = w + 1) begin
                    for (l = 0; l < 4; l = l + 1) begin
                        j = 4 * w + l;
                        if (j < T) begin
                            v = (mode == 1) ? -128 : ($random(seed) % 128);
                            if (is_b) ref_b[bank_of(b)][i][j] = v;
                            else      ref_a[bank_of(b)][i][j] = v;
                        end else begin
                            v = 8'h7F;
                        end
                        word[8*l +: 8] = v[7:0];
                    end
                    send_word(is_b, b, i, w, word);
                end
            end
            stop_writes;
        end
    endtask

    // Para os casos dirigidos: preenche a referencia com set_val e depois
    // manda a matriz inteira com push_ref
    task set_val(input integer is_b, input integer b, input integer r, input integer c,
                 input integer v);
        begin
            if (is_b) ref_b[bank_of(b)][r][c] = v;
            else      ref_a[bank_of(b)][r][c] = v;
        end
    endtask

    task push_ref(input integer is_b, input integer b);
        reg [31:0] word;
        begin
            for (i = 0; i < T; i = i + 1)
                for (w = 0; w < WPR; w = w + 1) begin
                    for (l = 0; l < 4; l = l + 1) begin
                        j = 4 * w + l;
                        if (j < T)
                            word[8*l +: 8] = is_b ? ref_b[bank_of(b)][i][j][7:0]
                                                  : ref_a[bank_of(b)][i][j][7:0];
                        else
                            word[8*l +: 8] = 8'h7F;
                    end
                    send_word(is_b, b, i, w, word);
                end
            stop_writes;
        end
    endtask

    integer tiles_started = 0;

    task start_tile(input integer b, input integer fk, input integer lk);
        begin
            tiles_started = tiles_started + 1;
            @(posedge clk);
            tile_start <= 1'b1;
            tile_bank  <= b[0];
            first_k    <= fk[0];
            last_k     <= lk[0];
            expect_cvalid_on_done <= lk[0];
            @(posedge clk);
            tile_start <= 1'b0;
            first_k    <= 1'b0;
            last_k     <= 1'b0;
            ref_tile(b, fk);
        end
    endtask

    // Espera pelo contador e nao pelo pulso: no prefetch a carga do outro banco
    // pode demorar mais que o tile, e o tile_done ja ter passado quando chegamos aqui
    task wait_done;
        begin
            @(posedge clk);
            while (tiles_done < tiles_started) @(posedge clk);
        end
    endtask

    task check_c(input [8*32-1:0] name);
        integer got;
        integer bad;
        begin
            bad = 0;
            for (i = 0; i < T; i = i + 1)
                for (j = 0; j < T; j = j + 1) begin
                    @(posedge clk);
                    c_rd  <= 1'b1;
                    c_row <= i[IW-1:0];
                    c_col <= j[IW-1:0];
                    @(posedge clk);
                    c_rd  <= 1'b0;
                    #1;
                    got = $signed(c_rdata);
                    checks = checks + 1;
                    if (got !== ref_c[i][j]) begin
                        bad = bad + 1;
                        errors = errors + 1;
                        if (bad <= 4)
                            $display("[%0t] ERRO %0s: C[%0d][%0d] = %0d, esperado %0d",
                                     $time, name, i, j, got, ref_c[i][j]);
                    end
                end
            if (bad == 0)
                $display("  ok: %0s", name);
        end
    endtask

    // Da o pulso de c_release e confere que c_valid ja esta em 0 no ciclo seguinte
    task release_c;
        begin
            @(posedge clk);
            if (!c_valid) begin
                errors = errors + 1;
                $display("[%0t] ERRO: c_release com c_valid = 0", $time);
            end
            c_release <= 1'b1;
            @(posedge clk);
            c_release <= 1'b0;
            #1;
            checks = checks + 1;
            if (c_valid) begin
                errors = errors + 1;
                $display("[%0t] ERRO: c_valid nao caiu logo depois do c_release", $time);
            end
        end
    endtask

    // Calcula um tile de C acumulando nb blocos de K. Com PINGPONG = 1 o bloco
    // seguinte e carregado no outro banco enquanto a malha ainda calcula, como
    // o DMA faz no prefetch.
    task run_tile(input integer nb, input integer mode, input integer seed,
                  input [8*32-1:0] name);
        integer kb, cur;
        begin
            cur = 0;
            write_mat(0, cur, mode, seed);
            write_mat(1, cur, mode, seed + 1);
            for (kb = 0; kb < nb; kb = kb + 1) begin
                start_tile(cur, kb == 0, kb == nb - 1);
                if (kb < nb - 1) begin
                    if (PINGPONG != 0) begin
                        write_mat(0, 1 - cur, mode, seed + 10 * kb + 2);
                        write_mat(1, 1 - cur, mode, seed + 10 * kb + 3);
                        wait_done;
                        cur = 1 - cur;
                    end else begin
                        wait_done;
                        write_mat(0, cur, mode, seed + 10 * kb + 2);
                        write_mat(1, cur, mode, seed + 10 * kb + 3);
                    end
                end else begin
                    wait_done;
                end
            end
            ref_publish;
            check_c(name);
            release_c;
        end
    endtask

    integer seen_wait, seen_done, t0;

    initial begin
        for (i = 0; i < T; i = i + 1)
            for (j = 0; j < T; j = j + 1) begin
                ref_a[0][i][j] = 0; ref_a[1][i][j] = 0;
                ref_b[0][i][j] = 0; ref_b[1][i][j] = 0;
                ref_acc[i][j] = 0;  ref_c[i][j] = 0;
            end

        $display("TB_ACCEL T=%0d PINGPONG=%0d", T, PINGPONG);
        repeat (3) @(posedge clk);
        rst_n <= 1'b1;
        repeat (2) @(posedge clk);

        // Os mesmos casos da Entrega 2, agora com escrita em palavras e c_release
        if (T == 2) begin
            $display("Teste 1a: 2x2, um tile");
            set_val(0,0,0,0, 2); set_val(0,0,0,1, 3); set_val(0,0,1,0, 4); set_val(0,0,1,1,-1);
            set_val(1,0,0,0, 1); set_val(1,0,0,1, 2); set_val(1,0,1,0, 3); set_val(1,0,1,1, 4);
            push_ref(0, 0); push_ref(1, 0);
            start_tile(0, 1, 1); wait_done; ref_publish;
            if (ref_c[0][0] != 11 || ref_c[0][1] != 16 || ref_c[1][0] != 1 || ref_c[1][1] != 4) begin
                errors = errors + 1; $display("ERRO: referencia do teste 1a nao bate com a Entrega 2");
            end
            check_c("2x2 um tile"); release_c;

            $display("Teste 1b: 2x2, dois blocos de K");
            set_val(0,0,0,0, 1); set_val(0,0,0,1, 2); set_val(0,0,1,0, 3); set_val(0,0,1,1, 4);
            set_val(1,0,0,0, 5); set_val(1,0,0,1, 6); set_val(1,0,1,0, 7); set_val(1,0,1,1, 8);
            push_ref(0, 0); push_ref(1, 0);
            start_tile(0, 1, 0); wait_done;
            set_val(0,1,0,0,-1); set_val(0,1,0,1, 1); set_val(0,1,1,0, 2); set_val(0,1,1,1,-2);
            set_val(1,1,0,0, 1); set_val(1,1,0,1,-1); set_val(1,1,1,0, 2); set_val(1,1,1,1, 1);
            push_ref(0, 1); push_ref(1, 1);
            start_tile(1, 0, 1); wait_done; ref_publish;
            if (ref_c[0][0] != 20 || ref_c[0][1] != 24 || ref_c[1][0] != 41 || ref_c[1][1] != 46) begin
                errors = errors + 1; $display("ERRO: referencia do teste 1b nao bate com a Entrega 2");
            end
            check_c("2x2 dois blocos de K"); release_c;
        end

        if (T == 4) begin
            $display("Teste 1c: 4x4 com B = I, entao C = A");
            set_val(0,0,0,0, 10); set_val(0,0,0,1,-20); set_val(0,0,0,2, 30); set_val(0,0,0,3,-40);
            set_val(0,0,1,0, 15); set_val(0,0,1,1, 25); set_val(0,0,1,2,-35); set_val(0,0,1,3, 45);
            set_val(0,0,2,0, -5); set_val(0,0,2,1,  0); set_val(0,0,2,2, 50); set_val(0,0,2,3,-50);
            set_val(0,0,3,0,100); set_val(0,0,3,1,-80); set_val(0,0,3,2, 60); set_val(0,0,3,3,-40);
            for (i = 0; i < 4; i = i + 1)
                for (j = 0; j < 4; j = j + 1)
                    ref_b[0][i][j] = (i == j) ? 1 : 0;
            push_ref(0, 0); push_ref(1, 0);
            start_tile(0, 1, 1); wait_done; ref_publish;
            check_c("4x4 identidade"); release_c;
        end

        $display("Teste 2: dados aleatorios");
        run_tile(1, 0, 11, "aleatorio, 1 bloco de K");
        run_tile(3, 0, 23, "aleatorio, 3 blocos de K");
        run_tile(8, 0, 37, "aleatorio, 8 blocos de K");

        $display("Teste 3: pior caso de valor (-128 x -128)");
        run_tile(4, 1, 0, "extremos, 4 blocos de K");

        // Logo depois do tile_start, tenta escrever lixo no banco que a malha esta
        // usando. A escrita tem que ser descartada, e um segundo tile sobre o
        // mesmo banco tem que dar o mesmo resultado.
        $display("Teste 4: escrita no banco em uso e descartada");
        write_mat(0, 0, 0, 51);
        write_mat(1, 0, 0, 52);
        start_tile(0, 1, 1);
        send_word(0, 0, 0, 0, 32'h5A5A5A5A);
        send_word(1, 0, 0, 0, 32'h5A5A5A5A);
        stop_writes;
        wait_done; ref_publish;
        check_c("tile com tentativa de escrita");
        release_c;
        start_tile(0, 1, 1); wait_done; ref_publish;
        check_c("banco continua intacto");
        release_c;

        // Um segundo tile_start no meio do calculo nao pode disparar outro tile
        $display("Teste 5: tile_start com a malha ocupada e ignorado");
        t0 = tiles_done;
        start_tile(0, 1, 1);
        repeat (2) @(posedge clk);
        tile_start <= 1'b1; tile_bank <= 1'b0; first_k <= 1'b1;
        @(posedge clk);
        tile_start <= 1'b0; first_k <= 1'b0;
        wait_done;
        repeat (CYCLES + 4) @(posedge clk);
        checks = checks + 1;
        if (tiles_done - t0 != 1 || busy) begin
            errors = errors + 1;
            $display("ERRO: o segundo tile_start disparou outro tile (%0d tiles)", tiles_done - t0);
        end else
            $display("  ok: so um tile executado");
        ref_publish;
        check_c("resultado do tile unico");
        release_c;

        // Dois tiles com last_k seguidos, sem c_release no meio. O segundo tem
        // que parar em A_WAIT_C ate o DMA liberar o banco C, sem estragar o C
        // do primeiro tile, que ainda nao foi gravado.
        if (PINGPONG != 0) begin
            $display("Teste 6: espera em A_WAIT_C");
            write_mat(0, 0, 0, 61);
            write_mat(1, 0, 0, 62);
            write_mat(0, 1, 0, 63);
            write_mat(1, 1, 0, 64);
            start_tile(0, 1, 1); wait_done; ref_publish;
            start_tile(1, 1, 1);
            seen_wait = 0; seen_done = 0;
            repeat (CYCLES + 6) begin
                @(posedge clk); #1;
                if (busy && !acc_active) seen_wait = 1;
                if (tile_done) seen_done = 1;
            end
            checks = checks + 1;
            if (!seen_wait || seen_done || !busy || acc_active || !c_valid) begin
                errors = errors + 1;
                $display("ERRO: esperava A_WAIT_C (busy=%0b acc_active=%0b tile_done=%0b c_valid=%0b)",
                         busy, acc_active, seen_done, c_valid);
            end else
                $display("  ok: malha parada esperando o banco C");
            check_c("C do primeiro tile preservado");
            release_c;
            @(posedge clk); #1;
            checks = checks + 1;
            if (!tile_done || !c_valid || busy) begin
                errors = errors + 1;
                $display("ERRO: depois do release esperava tile_done, c_valid e busy = 0 (%0b %0b %0b)",
                         tile_done, c_valid, busy);
            end else
                $display("  ok: copia feita no ciclo seguinte ao release");
            ref_publish;
            check_c("C do segundo tile");
            release_c;
        end

        repeat (5) @(posedge clk);
        if (errors == 0)
            $display("TB_ACCEL T=%0d PP=%0d: PASS (%0d checagens, %0d tiles)", T, PINGPONG, checks, tiles_done);
        else
            $display("TB_ACCEL T=%0d PP=%0d: FAIL (%0d erros)", T, PINGPONG, errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("TB_ACCEL T=%0d PP=%0d: FAIL (timeout)", T, PINGPONG);
        $finish;
    end

endmodule
