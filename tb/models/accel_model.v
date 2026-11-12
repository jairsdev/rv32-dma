`timescale 1ns/1ps
`default_nettype none

// Modelo comportamental (so simulacao) do acelerador v2 (MAS secao 11).
// Mesma interface e mesma temporizacao do accel.v v2 especificado:
//   - PINGPONG = 1: 2 bancos de A/B + banco C; PINGPONG = 0: 1 banco e C lido
//     direto dos acumuladores;
//   - porta de escrita de 32 bits (4 int8 por palavra, lanes alem de T ignoradas);
//   - tile de 3T - 1 ciclos em A_RUN; o produto e calculado de uma vez no fim;
//   - fim de tile com last_k publica C (copia para o banco C ou c_valid com
//     PINGPONG = 0); com c_valid = 1 espera em A_WAIT_C mantendo busy (H3);
//   - c_release zera c_valid na borda que encerra o ciclo do pulso;
//   - c_rdata valido no ciclo seguinte a c_rd.
// Verificacoes extras do modelo (contadas em "errors"):
//   - escrita no banco em uso pela malha (H1 visto pelo acelerador);
//   - tile_start com busy = 1 (H2);
//   - copia para o banco C com c_valid = 1 (H3);
//   - PINGPONG = 0: tile_start com first_k e c_valid = 1 (zeraria C nao gravado).
module accel_model #(
    parameter ARRAY_SIZE = 4,
    parameter PINGPONG   = 1,
    parameter IW  = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1,
    parameter WPR = (ARRAY_SIZE + 3) / 4,
    parameter WW  = (WPR > 1) ? $clog2(WPR) : 1
)(
    input  wire          clk,
    input  wire          rst_n,

    input  wire          buf_a_we,
    input  wire          buf_b_we,
    input  wire          buf_bank,
    input  wire [IW-1:0] buf_row,
    input  wire [WW-1:0] buf_word,
    input  wire [31:0]   buf_wdata,

    input  wire          tile_start,
    input  wire          tile_bank,
    input  wire          first_k,
    input  wire          last_k,
    output wire          busy,
    output wire          acc_active,
    output reg           tile_done,
    output reg           c_valid,
    input  wire          c_release,

    input  wire          c_rd,
    input  wire [IW-1:0] c_row,
    input  wire [IW-1:0] c_col,
    output reg  [31:0]   c_rdata
);

    localparam T      = ARRAY_SIZE;
    localparam NBANK  = (PINGPONG != 0) ? 2 : 1;
    localparam CYCLES = 3 * T - 1;

    localparam [1:0] A_IDLE   = 2'd0,
                     A_RUN    = 2'd1,
                     A_WAIT_C = 2'd2;

    // Buffers e acumuladores, achatados: [banco][linha][coluna]
    reg signed [7:0]  buf_a  [0:2*T*T-1];
    reg signed [7:0]  buf_b  [0:2*T*T-1];
    reg signed [31:0] acc    [0:T*T-1];
    reg signed [31:0] c_bank [0:T*T-1];

    reg [1:0] state;
    integer   cnt;
    reg       bank_q, first_k_q, last_k_q;

    integer errors = 0;
    integer tiles  = 0;

    assign busy       = (state == A_RUN) | (state == A_WAIT_C);
    assign acc_active = (state == A_RUN);

    wire wr_bank = (PINGPONG != 0) ? buf_bank : 1'b0;

    integer i, j, k, l, col;
    reg signed [31:0] sum;

    task compute_tile;
        begin
            for (i = 0; i < T; i = i + 1)
                for (j = 0; j < T; j = j + 1) begin
                    sum = first_k_q ? 32'sd0 : acc[i*T + j];
                    for (k = 0; k < T; k = k + 1)
                        sum = sum + buf_a[bank_q*T*T + i*T + k] * buf_b[bank_q*T*T + k*T + j];
                    acc[i*T + j] = sum;
                end
        end
    endtask

    task copy_to_c;
        begin
            if (c_valid) begin
                errors = errors + 1;
                $display("[%0t] ACCEL_MODEL ERRO H3: copia para o banco C com c_valid = 1", $time);
            end
            for (i = 0; i < T*T; i = i + 1)
                c_bank[i] = acc[i];
        end
    endtask

    initial begin
        for (i = 0; i < 2*T*T; i = i + 1) begin
            buf_a[i] = 0;
            buf_b[i] = 0;
        end
        for (i = 0; i < T*T; i = i + 1) begin
            acc[i]    = 0;
            c_bank[i] = 0;
        end
    end

    // Escrita nos buffers: lanes com coluna < T
    always @(posedge clk) begin
        if (rst_n && (buf_a_we || buf_b_we)) begin
            if (busy && (wr_bank == bank_q)) begin
                errors = errors + 1;
                $display("[%0t] ACCEL_MODEL ERRO: escrita no banco %0d em uso pela malha", $time, wr_bank);
            end
            for (l = 0; l < 4; l = l + 1) begin
                col = 4 * buf_word + l;
                if (col < T) begin
                    if (buf_a_we) buf_a[wr_bank*T*T + buf_row*T + col] = buf_wdata[8*l +: 8];
                    if (buf_b_we) buf_b[wr_bank*T*T + buf_row*T + col] = buf_wdata[8*l +: 8];
                end
            end
        end
    end

    // FSM do tile
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= A_IDLE;
            cnt       = 0;
            bank_q    <= 1'b0;
            first_k_q <= 1'b0;
            last_k_q  <= 1'b0;
            tile_done <= 1'b0;
            c_valid   <= 1'b0;
        end else begin
            tile_done <= 1'b0;

            // c_release: c_valid cai na borda que encerra o ciclo do pulso
            if (c_release) begin
                if (!c_valid) begin
                    errors = errors + 1;
                    $display("[%0t] ACCEL_MODEL ERRO: c_release com c_valid = 0", $time);
                end
                c_valid <= 1'b0;
            end

            case (state)
                A_IDLE: begin
                    if (tile_start) begin
                        if (PINGPONG == 0 && first_k && c_valid) begin
                            errors = errors + 1;
                            $display("[%0t] ACCEL_MODEL ERRO: first_k com C nao gravado (PINGPONG = 0)", $time);
                        end
                        state     <= A_RUN;
                        cnt       = 0;
                        bank_q    <= (PINGPONG != 0) ? tile_bank : 1'b0;
                        first_k_q <= first_k;
                        last_k_q  <= last_k;
                    end
                end

                A_RUN: begin
                    if (cnt == CYCLES - 1) begin
                        compute_tile;
                        tiles = tiles + 1;
                        if (!last_k_q) begin
                            tile_done <= 1'b1;
                            state     <= A_IDLE;
                        end else if (PINGPONG == 0) begin
                            // C fica nos acumuladores ate o c_release
                            tile_done <= 1'b1;
                            c_valid   <= 1'b1;
                            state     <= A_IDLE;
                        end else if (!c_valid) begin
                            copy_to_c;
                            tile_done <= 1'b1;
                            c_valid   <= 1'b1;
                            state     <= A_IDLE;
                        end else begin
                            state <= A_WAIT_C;
                        end
                    end else begin
                        cnt = cnt + 1;
                    end
                end

                A_WAIT_C: begin
                    if (!c_valid) begin
                        copy_to_c;
                        tile_done <= 1'b1;
                        c_valid   <= 1'b1;
                        state     <= A_IDLE;
                    end
                end

                default: state <= A_IDLE;
            endcase

            if (tile_start && busy) begin
                errors = errors + 1;
                $display("[%0t] ACCEL_MODEL ERRO: tile_start com busy = 1", $time);
            end
        end
    end

    // Leitura de C (1 ciclo de latencia)
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            c_rdata <= 32'd0;
        else if (c_rd)
            c_rdata <= (PINGPONG != 0) ? c_bank[c_row*T + c_col] : acc[c_row*T + c_col];
    end

endmodule

`default_nettype wire
