`timescale 1ns/1ps

module accel #(
    parameter ARRAY_SIZE = 4,
    parameter PINGPONG   = 1,
    parameter IW  = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1,
    parameter WPR = (ARRAY_SIZE + 3) / 4,          // palavras de 32 bits por linha
    parameter WW  = (WPR > 1) ? $clog2(WPR) : 1
)(
    input  wire          clk,
    input  wire          rst_n,

    // escrita dos buffers pelo DMA: o byte l da palavra vai para a coluna 4*buf_word + l
    input  wire          buf_a_we,
    input  wire          buf_b_we,
    input  wire          buf_bank,      // sem efeito com PINGPONG = 0
    input  wire [IW-1:0] buf_row,
    input  wire [WW-1:0] buf_word,
    input  wire [31:0]   buf_wdata,

    input  wire          tile_start,    // ignorado se a malha estiver ocupada
    input  wire          tile_bank,
    input  wire          first_k,       // zera os acumuladores antes do tile
    input  wire          last_k,        // no fim do tile, C fica pronto para o DMA
    output wire          busy,
    output wire          acc_active,    // so enquanto a malha calcula (usado no CYC_COMPUTE)
    output reg           tile_done,
    output reg           c_valid,
    input  wire          c_release,     // o DMA avisa que ja gravou C

    // leitura de C: o dado sai no ciclo seguinte ao c_rd
    input  wire          c_rd,
    input  wire [IW-1:0] c_row,
    input  wire [IW-1:0] c_col,
    output reg  [31:0]   c_rdata
);

    localparam T            = ARRAY_SIZE;
    localparam NBANK        = (PINGPONG != 0) ? 2 : 1;
    localparam TOTAL_CYCLES = 3 * T - 1;      // clear + T passos + 2(T-1) de skew
    localparam CNT_W        = $clog2(TOTAL_CYCLES + 1);

    localparam [1:0] A_IDLE   = 2'd0,
                     A_RUN    = 2'd1,
                     A_WAIT_C = 2'd2;

    reg [1:0]       state;
    reg [CNT_W-1:0] cnt;
    reg             first_k_reg;
    reg             last_k_reg;
    reg             tile_bank_reg;

    assign busy       = (state == A_RUN) || (state == A_WAIT_C);
    assign acc_active = (state == A_RUN);

    wire last_cycle = (state == A_RUN) && (cnt == TOTAL_CYCLES - 1);

    // Quando copiar os acumuladores para o banco C (so existe com PINGPONG = 1).
    // A copia nunca sobrescreve um C que o DMA ainda nao gravou (H3).
    wire copy_run  = (PINGPONG != 0) && last_cycle && last_k_reg && !c_valid;
    wire copy_wait = (PINGPONG != 0) && (state == A_WAIT_C) && !c_valid;

    // Buffers de A e B, indexados por [banco][linha][coluna]
    reg signed [7:0] buf_a [0:NBANK-1][0:T-1][0:T-1];
    reg signed [7:0] buf_b [0:NBANK-1][0:T-1][0:T-1];

    wire wr_bank  = (PINGPONG != 0) ? buf_bank : 1'b0;
    // enquanto a malha usa um banco, escrita nele e descartada; o outro banco continua livre
    wire wr_block = busy && (wr_bank == tile_bank_reg);

    integer bk, r_idx, c_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (bk = 0; bk < NBANK; bk = bk + 1)
                for (r_idx = 0; r_idx < T; r_idx = r_idx + 1)
                    for (c_idx = 0; c_idx < T; c_idx = c_idx + 1) begin
                        buf_a[bk][r_idx][c_idx] <= 8'sd0;
                        buf_b[bk][r_idx][c_idx] <= 8'sd0;
                    end
        end else if (!wr_block) begin
            // bytes que cairiam numa coluna >= T simplesmente nao tem onde ir
            for (c_idx = 0; c_idx < T; c_idx = c_idx + 1) begin
                if (buf_word == (c_idx / 4)) begin
                    if (buf_a_we)
                        buf_a[wr_bank][buf_row][c_idx] <= $signed(buf_wdata[8*(c_idx%4) +: 8]);
                    if (buf_b_we)
                        buf_b[wr_bank][buf_row][c_idx] <= $signed(buf_wdata[8*(c_idx%4) +: 8]);
                end
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= A_IDLE;
            cnt           <= {CNT_W{1'b0}};
            first_k_reg   <= 1'b0;
            last_k_reg    <= 1'b0;
            tile_bank_reg <= 1'b0;
            tile_done     <= 1'b0;
            c_valid       <= 1'b0;
        end else begin
            tile_done <= 1'b0;

            // c_valid cai na mesma borda que fecha o ciclo do c_release, entao o DMA
            // ja ve 0 no ciclo seguinte. As atribuicoes do case vem depois e ganham,
            // mas elas so acontecem com c_valid = 0, quando nao ha release valido.
            if (c_release)
                c_valid <= 1'b0;

            case (state)
                A_IDLE: begin
                    if (tile_start) begin
                        state         <= A_RUN;
                        cnt           <= {CNT_W{1'b0}};
                        first_k_reg   <= first_k;
                        last_k_reg    <= last_k;
                        tile_bank_reg <= (PINGPONG != 0) ? tile_bank : 1'b0;
                    end
                end

                A_RUN: begin
                    if (cnt == TOTAL_CYCLES - 1) begin
                        cnt <= {CNT_W{1'b0}};
                        if (!last_k_reg) begin
                            tile_done <= 1'b1;
                            state     <= A_IDLE;
                        end else if (PINGPONG == 0) begin
                            // sem banco C: o resultado fica nos acumuladores ate o release
                            tile_done <= 1'b1;
                            c_valid   <= 1'b1;
                            state     <= A_IDLE;
                        end else if (!c_valid) begin
                            // banco C livre: a copia acontece nesta mesma borda (copy_run)
                            tile_done <= 1'b1;
                            c_valid   <= 1'b1;
                            state     <= A_IDLE;
                        end else begin
                            // o DMA ainda nao gravou o C anterior, entao a malha espera
                            state <= A_WAIT_C;
                        end
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                A_WAIT_C: begin
                    if (!c_valid) begin
                        // banco C liberado: copia agora (copy_wait)
                        tile_done <= 1'b1;
                        c_valid   <= 1'b1;
                        state     <= A_IDLE;
                    end
                end

                default: state <= A_IDLE;
            endcase
        end
    end

    // no primeiro ciclo do tile os acumuladores sao zerados, se for o primeiro bloco de K
    wire clr_acc = (state == A_RUN) && (cnt == 0) && first_k_reg;
    wire pe_en   = (state == A_RUN);

    // os operandos saem do banco escolhido no tile_start, um passo de k por ciclo
    wire stream_valid = (state == A_RUN) && (cnt >= 1) && (cnt <= T);
    wire [CNT_W-1:0] k_full = cnt - 1'b1;
    wire [IW-1:0]    step_k = k_full[IW-1:0];

    wire signed [7:0] a_stream [0:T-1];
    wire signed [7:0] b_stream [0:T-1];

    genvar gi, gj;
    generate
        for (gi = 0; gi < T; gi = gi + 1) begin : gen_stream
            assign a_stream[gi] = stream_valid ? buf_a[tile_bank_reg][gi][step_k] : 8'sd0;
            assign b_stream[gi] = stream_valid ? buf_b[tile_bank_reg][step_k][gi] : 8'sd0;
        end
    endgenerate

    // skew: a linha i de A entra com i ciclos de atraso e a coluna j de B com j ciclos
    wire signed [7:0] a_pe_in [0:T-1];
    wire signed [7:0] b_pe_in [0:T-1];

    generate
        for (gi = 0; gi < T; gi = gi + 1) begin : gen_skew_a
            if (gi == 0) begin : gen_skew_a_direct
                assign a_pe_in[0] = a_stream[0];
            end else begin : gen_skew_a_regs
                reg signed [7:0] pipe [0:gi-1];
                integer p;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (p = 0; p < gi; p = p + 1)
                            pipe[p] <= 8'sd0;
                    end else if (acc_active) begin
                        pipe[0] <= a_stream[gi];
                        for (p = 1; p < gi; p = p + 1)
                            pipe[p] <= pipe[p-1];
                    end
                end
                assign a_pe_in[gi] = pipe[gi-1];
            end
        end

        for (gj = 0; gj < T; gj = gj + 1) begin : gen_skew_b
            if (gj == 0) begin : gen_skew_b_direct
                assign b_pe_in[0] = b_stream[0];
            end else begin : gen_skew_b_regs
                reg signed [7:0] pipe [0:gj-1];
                integer p;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (p = 0; p < gj; p = p + 1)
                            pipe[p] <= 8'sd0;
                    end else if (acc_active) begin
                        pipe[0] <= b_stream[gj];
                        for (p = 1; p < gj; p = p + 1)
                            pipe[p] <= pipe[p-1];
                    end
                end
                assign b_pe_in[gj] = pipe[gj-1];
            end
        end
    endgenerate

    wire signed [7:0]  pe_a_wire [0:T-1][0:T];
    wire signed [7:0]  pe_b_wire [0:T][0:T-1];
    wire signed [31:0] pe_acc    [0:T-1][0:T-1];
    wire signed [31:0] pe_acc_nx [0:T-1][0:T-1];

    generate
        for (gi = 0; gi < T; gi = gi + 1) begin : gen_row_conn
            assign pe_a_wire[gi][0] = a_pe_in[gi];
        end
        for (gj = 0; gj < T; gj = gj + 1) begin : gen_col_conn
            assign pe_b_wire[0][gj] = b_pe_in[gj];
        end

        for (gi = 0; gi < T; gi = gi + 1) begin : gen_pe_row
            for (gj = 0; gj < T; gj = gj + 1) begin : gen_pe_col
                pe u_pe (
                    .clk      (clk),
                    .rst_n    (rst_n),
                    .en       (pe_en),
                    .clr_acc  (clr_acc),
                    .a_in     (pe_a_wire[gi][gj]),
                    .b_in     (pe_b_wire[gi][gj]),
                    .a_out    (pe_a_wire[gi][gj+1]),
                    .b_out    (pe_b_wire[gi+1][gj]),
                    .acc_out  (pe_acc[gi][gj]),
                    .acc_next (pe_acc_nx[gi][gj])
                );
            end
        end
    endgenerate

    wire signed [31:0] c_src;

    generate
        if (PINGPONG != 0) begin : gen_cbank
            // No ultimo ciclo do tile o PE do canto ainda soma o ultimo produto,
            // por isso copy_run pega acc_next. Em A_WAIT_C a malha esta parada e
            // os acumuladores ja tem o valor final.
            reg signed [31:0] c_bank [0:T-1][0:T-1];
            integer ci, cj;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    for (ci = 0; ci < T; ci = ci + 1)
                        for (cj = 0; cj < T; cj = cj + 1)
                            c_bank[ci][cj] <= 32'sd0;
                end else if (copy_run || copy_wait) begin
                    for (ci = 0; ci < T; ci = ci + 1)
                        for (cj = 0; cj < T; cj = cj + 1)
                            c_bank[ci][cj] <= copy_run ? pe_acc_nx[ci][cj] : pe_acc[ci][cj];
                end
            end
            assign c_src = c_bank[c_row][c_col];
        end else begin : gen_no_cbank
            assign c_src = pe_acc[c_row][c_col];
        end
    endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            c_rdata <= 32'd0;
        else if (c_rd)
            c_rdata <= c_src;
    end

endmodule
