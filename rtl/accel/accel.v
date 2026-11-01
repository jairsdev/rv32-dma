`timescale 1ns/1ps

// Acelerador de multiplicacao matricial baseado em malha sistolica.
// Topologia: output-stationary, operando sobre blocos T x T (ARRAY_SIZE).
// - Operandos A e B: int8 (armazenados nos buffers locais)
// - Acumuladores de C: int32 (dentro de cada PE)
// - Latencia por tile: 1 ciclo de clear (se first_k) + T passos + 2(T-1) skew = 3T - 1 ciclos.
module accel #(
    parameter ARRAY_SIZE = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // Escrita nos buffers locais pelo DMA
    input  wire        buf_a_we,
    input  wire        buf_b_we,
    input  wire [IW-1:0] buf_row,
    input  wire [IW-1:0] buf_col,
    input  wire [7:0]  buf_wdata,

    // Controle do tile
    input  wire        tile_start,
    input  wire        first_k,
    output reg         busy,
    output reg         tile_done,

    // Leitura dos resultados de C pelo DMA
    input  wire        c_rd,
    input  wire [IW-1:0] c_row,
    input  wire [IW-1:0] c_col,
    output reg  [31:0] c_rdata
);

    // Largura de indice dos buffers e contadores
    localparam IW = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1;
    localparam TOTAL_CYCLES = 3 * ARRAY_SIZE - 1;
    localparam CNT_W = $clog2(TOTAL_CYCLES + 1);

    localparam S_IDLE = 1'b0;
    localparam S_RUN  = 1'b1;

    // Buffers locais para os blocos T x T de A e B
    reg signed [7:0] buf_a [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];
    reg signed [7:0] buf_b [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    integer r_idx, c_idx;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (r_idx = 0; r_idx < ARRAY_SIZE; r_idx = r_idx + 1) begin
                for (c_idx = 0; c_idx < ARRAY_SIZE; c_idx = c_idx + 1) begin
                    buf_a[r_idx][c_idx] <= 8'sd0;
                    buf_b[r_idx][c_idx] <= 8'sd0;
                end
            end
        end else begin
            if (buf_a_we && !busy)
                buf_a[buf_row][buf_col] <= $signed(buf_wdata);
            if (buf_b_we && !busy)
                buf_b[buf_row][buf_col] <= $signed(buf_wdata);
        end
    end

    // Controle e FSM do processamento
    reg             state;
    reg [CNT_W-1:0] cnt;
    reg             first_k_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_IDLE;
            cnt         <= {CNT_W{1'b0}};
            busy        <= 1'b0;
            tile_done   <= 1'b0;
            first_k_reg <= 1'b0;
        end else begin
            tile_done <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (tile_start && !busy) begin
                        busy        <= 1'b1;
                        state       <= S_RUN;
                        cnt         <= {CNT_W{1'b0}};
                        first_k_reg <= first_k;
                    end
                end

                S_RUN: begin
                    if (cnt == TOTAL_CYCLES - 1) begin
                        state     <= S_IDLE;
                        busy      <= 1'b0;
                        tile_done <= 1'b1;
                        cnt       <= {CNT_W{1'b0}};
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end
            endcase
        end
    end

    // No primeiro ciclo (cnt == 0), zera os acumuladores se first_k estiver ativo
    wire clr_acc = (state == S_RUN) && (cnt == 0) && first_k_reg;
    wire pe_en   = (state == S_RUN);

    // Selecao dos operandos para alimentacao nos registradores de skew
    wire stream_valid = (state == S_RUN) && (cnt >= 1) && (cnt <= ARRAY_SIZE);
    wire [CNT_W-1:0] k_full = cnt - 1'b1;
    wire [IW-1:0]    step_k = k_full[IW-1:0];

    reg signed [7:0] a_stream [0:ARRAY_SIZE-1];
    reg signed [7:0] b_stream [0:ARRAY_SIZE-1];

    integer s;
    always @(*) begin
        for (s = 0; s < ARRAY_SIZE; s = s + 1) begin
            a_stream[s] = stream_valid ? buf_a[s][step_k] : 8'sd0;
            b_stream[s] = stream_valid ? buf_b[step_k][s] : 8'sd0;
        end
    end

    // Registradores de skew (linha i atrasada i ciclos, coluna j atrasada j ciclos)
    wire signed [7:0] a_pe_in [0:ARRAY_SIZE-1];
    wire signed [7:0] b_pe_in [0:ARRAY_SIZE-1];

    genvar gi, gj;
    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : gen_skew_a
            if (gi == 0) begin : gen_skew_a_direct
                assign a_pe_in[0] = a_stream[0];
            end else begin : gen_skew_a_regs
                reg signed [7:0] pipe [0:gi-1];
                integer p;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (p = 0; p < gi; p = p + 1)
                            pipe[p] <= 8'sd0;
                    end else if (busy) begin
                        pipe[0] <= a_stream[gi];
                        for (p = 1; p < gi; p = p + 1)
                            pipe[p] <= pipe[p-1];
                    end
                end
                assign a_pe_in[gi] = pipe[gi-1];
            end
        end

        for (gj = 0; gj < ARRAY_SIZE; gj = gj + 1) begin : gen_skew_b
            if (gj == 0) begin : gen_skew_b_direct
                assign b_pe_in[0] = b_stream[0];
            end else begin : gen_skew_b_regs
                reg signed [7:0] pipe [0:gj-1];
                integer p;
                always @(posedge clk or negedge rst_n) begin
                    if (!rst_n) begin
                        for (p = 0; p < gj; p = p + 1)
                            pipe[p] <= 8'sd0;
                    end else if (busy) begin
                        pipe[0] <= b_stream[gj];
                        for (p = 1; p < gj; p = p + 1)
                            pipe[p] <= pipe[p-1];
                    end
                end
                assign b_pe_in[gj] = pipe[gj-1];
            end
        end
    endgenerate

    // Malha sistolica 2D de PEs
    wire signed [7:0]  pe_a_wire [0:ARRAY_SIZE-1][0:ARRAY_SIZE];
    wire signed [7:0]  pe_b_wire [0:ARRAY_SIZE][0:ARRAY_SIZE-1];
    wire signed [31:0] pe_acc    [0:ARRAY_SIZE-1][0:ARRAY_SIZE-1];

    generate
        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : gen_row_conn
            assign pe_a_wire[gi][0] = a_pe_in[gi];
        end
        for (gj = 0; gj < ARRAY_SIZE; gj = gj + 1) begin : gen_col_conn
            assign pe_b_wire[0][gj] = b_pe_in[gj];
        end

        for (gi = 0; gi < ARRAY_SIZE; gi = gi + 1) begin : gen_pe_row
            for (gj = 0; gj < ARRAY_SIZE; gj = gj + 1) begin : gen_pe_col
                pe u_pe (
                    .clk     (clk),
                    .rst_n   (rst_n),
                    .en      (pe_en),
                    .clr_acc (clr_acc),
                    .a_in    (pe_a_wire[gi][gj]),
                    .b_in    (pe_b_wire[gi][gj]),
                    .a_out   (pe_a_wire[gi][gj+1]),
                    .b_out   (pe_b_wire[gi+1][gj]),
                    .acc_out (pe_acc[gi][gj])
                );
            end
        end
    endgenerate

    // Leitura dos resultados de C (um ciclo de latencia apos c_rd)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            c_rdata <= 32'd0;
        end else if (c_rd) begin
            c_rdata <= pe_acc[c_row][c_col];
        end
    end

endmodule

