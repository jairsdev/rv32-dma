`timescale 1ns/1ps

module tb_register_file();
    reg clk = 0;
    reg rst_n = 0;
    reg we = 0;
    reg [4:0] rs1 = 0;
    reg [4:0] rs2 = 0;
    reg [4:0] rd = 0;
    reg [31:0] wr_rd = 0;
    wire [31:0] rs1_o, rs2_o;

    integer errors = 0;
    integer tests  = 0;
    integer i;
    reg [31:0] ref_mem [0:31];   // modelo de referencia

    always #5 clk = ~clk;

    reg_bank dut (
        .clk(clk),
        .rst_n(rst_n),
        .we(we),
        .rs1(rs1),
        .rs2(rs2),
        .rd(rd),
        .wr_rd(wr_rd),
        .rs1_o(rs1_o),
        .rs2_o(rs2_o)
    );

    // ---------------------------------------------------------------
    // Tasks
    // ---------------------------------------------------------------
    task check;
        input [31:0] exp;
        input [31:0] got;
        input [255:0] name;
        begin
            tests = tests + 1;
            if (exp !== got) begin
                errors = errors + 1;
                $display("FAIL [%0t] %0s: esperado 0x%08h, obtido 0x%08h", $time, name, exp, got);
            end
        end
    endtask

    // escreve 1 ciclo com we=1 e atualiza o modelo
    task write;
        input [4:0] addr;
        input [31:0] val;
        begin
            @(posedge clk); #1;
            we = 1;
            wr_rd = val;
            rd = addr;
            @(posedge clk); #1;
            we = 0;
            if (addr != 0) ref_mem[addr] = val;
        end
    endtask

    task read_rs1;
        input [4:0] addr;
        begin
            rs1 = addr;
            #1;
        end
    endtask

    task read_rs2;
        input [4:0] addr;
        begin
            rs2 = addr;
            #1;
        end
    endtask

    task read_simultaneo;
        input [4:0] addr1;
        input [4:0] addr2;
        begin
            rs1 = addr1;
            rs2 = addr2;
            #1;
        end
    endtask

    task do_reset;
        begin
            rst_n = 0;
            repeat (3) @(posedge clk);
            #1;
            for (i = 0; i < 32; i = i + 1) ref_mem[i] = 32'd0;
        end
    endtask

    // ---------------------------------------------------------------
    // Testes
    // ---------------------------------------------------------------
    reg [31:0] v;

    initial begin
        for (i = 0; i < 32; i = i + 1) ref_mem[i] = 32'd0;

        // 1. Reset: tudo lê 0
        do_reset;
        for (i = 0; i < 32; i = i + 1) begin
            read_simultaneo(i[4:0], i[4:0]);
            check(32'd0, rs1_o, "reset rs1");
            check(32'd0, rs2_o, "reset rs2");
        end
        rst_n = 1;
        @(posedge clk); #1;

        // 3/4. Escrita e leitura básica por rs1 e rs2
        write(5'd5, 32'h1234_5678);
        read_rs1(5'd5);
        check(32'h1234_5678, rs1_o, "escrita/leitura x5 via rs1");
        read_rs2(5'd5);
        check(32'h1234_5678, rs2_o, "escrita/leitura x5 via rs2");

        // 5. Todos os registradores com valores distintos
        for (i = 1; i < 32; i = i + 1)
            write(i[4:0], i * 32'h0101_0101);
        for (i = 1; i < 32; i = i + 1) begin
            read_simultaneo(i[4:0], i[4:0]);
            check(ref_mem[i], rs1_o, "todos regs rs1");
            check(ref_mem[i], rs2_o, "todos regs rs2");
        end

        // 6. Sobrescrita
        write(5'd7, 32'hDEAD_BEEF);
        write(5'd7, 32'hCAFE_F00D);
        read_rs1(5'd7);
        check(32'hCAFE_F00D, rs1_o, "sobrescrita x7");

        // 7/8. x0 hard wired em 0
        write(5'd0, 32'hFFFF_FFFF);
        read_simultaneo(5'd0, 5'd0);
        check(32'd0, rs1_o, "x0 apos escrita via rs1");
        check(32'd0, rs2_o, "x0 apos escrita via rs2");

        // 9. we=0 nao escreve
        @(posedge clk); #1;
        we = 0; rd = 5'd9; wr_rd = 32'hBAD0_BAD0;
        @(posedge clk); #1;
        read_rs1(5'd9);
        check(ref_mem[9], rs1_o, "we=0 nao escreve");

        // 10. we pulsa: so o ciclo com we=1 escreve
        write(5'd10, 32'h0000_000A);
        rd = 5'd11; wr_rd = 32'h0000_000B;   // we=0
        @(posedge clk); #1;
        read_simultaneo(5'd10, 5'd11);
        check(32'h0000_000A, rs1_o, "pulso we: x10 escrito");
        check(ref_mem[11],   rs2_o, "pulso we: x11 intacto");

        // 11. escrita so na borda de subida
        @(posedge clk); #1;
        we = 1; rd = 5'd12; wr_rd = 32'h1111_1111;
        @(negedge clk); #1;
        wr_rd = 32'h2222_2222;               // muda antes da proxima borda
        @(posedge clk); #1;
        we = 0;
        ref_mem[12] = 32'h2222_2222;
        read_rs1(5'd12);
        check(32'h2222_2222, rs1_o, "escrita amostrada na borda de subida");

        // 12. leitura simultanea rs1 != rs2
        write(5'd1, 32'd50000);
        write(5'd2, 32'd60000);
        read_simultaneo(5'd1, 5'd2);
        check(32'd50000, rs1_o, "simultaneo rs1");
        check(32'd60000, rs2_o, "simultaneo rs2");

        // 13. rs1 == rs2
        read_simultaneo(5'd2, 5'd2);
        check(32'd60000, rs1_o, "rs1==rs2 rs1");
        check(32'd60000, rs2_o, "rs1==rs2 rs2");

        // 14. x0 numa porta, outro registrador na outra
        read_simultaneo(5'd0, 5'd1);
        check(32'd0,     rs1_o, "x0 em rs1, x1 em rs2: rs1");
        check(32'd50000, rs2_o, "x0 em rs1, x1 em rs2: rs2");

        // 15/16. escrita e leitura do mesmo reg no mesmo ciclo
        // (so confere o valor apos a borda; antes depende de ter bypass)
        write(5'd20, 32'h0000_0001);
        rs1 = 5'd20; rs2 = 5'd20;
        @(posedge clk); #1;
        we = 1; rd = 5'd20; wr_rd = 32'h0000_0002;
        @(posedge clk); #1;
        we = 0;
        ref_mem[20] = 32'h0000_0002;
        check(32'h0000_0002, rs1_o, "rd==rs1 apos a borda");
        check(32'h0000_0002, rs2_o, "rd==rs2 apos a borda");

        // 17. rd == 0, rs1 == 0
        rs1 = 5'd0;
        write(5'd0, 32'h1234_ABCD);
        check(32'd0, rs1_o, "rd==0 e rs1==0");

        // 18/19. valores limite e enderecos extremos
        write(5'd1,  32'h0000_0000);
        write(5'd31, 32'hFFFF_FFFF);
        read_simultaneo(5'd1, 5'd31);
        check(32'h0000_0000, rs1_o, "limite x1=0");
        check(32'hFFFF_FFFF, rs2_o, "limite x31=FFFFFFFF");
        write(5'd1,  32'hAAAA_AAAA);
        write(5'd31, 32'h5555_5555);
        read_simultaneo(5'd1, 5'd31);
        check(32'hAAAA_AAAA, rs1_o, "limite AAAAAAAA");
        check(32'h5555_5555, rs2_o, "limite 55555555");
        write(5'd1,  32'h8000_0000);
        write(5'd31, 32'h7FFF_FFFF);
        read_simultaneo(5'd1, 5'd31);
        check(32'h8000_0000, rs1_o, "limite 80000000");
        check(32'h7FFF_FFFF, rs2_o, "limite 7FFFFFFF");

        // 2. Reset no meio da operacao
        do_reset;
        rst_n = 1;
        for (i = 0; i < 32; i = i + 1) begin
            read_simultaneo(i[4:0], i[4:0]);
            check(32'd0, rs1_o, "reset no meio rs1");
            check(32'd0, rs2_o, "reset no meio rs2");
        end

        // 20. Aleatorio contra o modelo de referencia
        for (i = 0; i < 500; i = i + 1) begin
            @(posedge clk); #1;
            we    = $random;
            rd    = $random;
            wr_rd = $random;
            rs1   = $random;
            rs2   = $random;
            @(posedge clk); #1;
            if (we && rd != 0) ref_mem[rd] = wr_rd;
            we = 0;
            #1;
            check(ref_mem[rs1], rs1_o, "aleatorio rs1");
            check(ref_mem[rs2], rs2_o, "aleatorio rs2");
        end

        if (errors == 0)
            $display("tb_register_file: PASSOU (%0d verificacoes)", tests);
        else
            $display("tb_register_file: FALHOU (%0d erros em %0d verificacoes)", errors, tests);
        $finish;
    end

    initial begin
        #1000000;
        $display("TIMEOUT");
        $finish;
    end
endmodule
