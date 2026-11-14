`timescale 1ns/1ps
`default_nettype none

// Gravacao de C (MAS secoes 9.4, 10.2 e 10.4).
//
// Espera c_valid (tile completo no banco C / acumuladores), entrega ao
// dma_wr_engine as linhas validas do tile, espera os B de todas elas e da
// c_release. Os tiles chegam na mesma ordem i0 -> j0 em que sao calculados.
//
//   S_IDLE --run--> S_WAIT_C --c_valid--> S_ROW --linhas entregues--> S_WAIT_TILE
//   S_WAIT_TILE --rows_done = issued--> S_RELEASE --ultimo tile--> S_END
//                                                 --senao-------> S_WAIT_C
//   Dreno: S_WAIT_C --c_valid & stop--> S_RELEASE (descarta sem gravar)
//          S_WAIT_C --stop & compute_end--> S_END
//          S_ROW --stop--> S_WAIT_TILE (termina so as linhas ja aceitas)
//   S_END --~run--> S_IDLE
//
// c_release e decodificado do estado (Moore), nunca registrado (H7): o
// acelerador zera c_valid na borda que encerra S_RELEASE, e no ciclo seguinte
// o store, ja em S_WAIT_C, ve o valor novo.
module dma_store #(
    parameter ARRAY_SIZE = 4,
    // derivados, nao sobrescrever
    parameter IW = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1,
    parameter CW = $clog2(ARRAY_SIZE + 1)
)(
    input  wire          clk,
    input  wire          rst_n,

    // Do dma_ctrl
    input  wire          run,
    input  wire          stop,
    input  wire [31:0]   addr_c,
    input  wire [15:0]   dim_m,
    input  wire [15:0]   dim_n,
    input  wire [17:0]   stride_c,
    input  wire [15:0]   last_i0,
    input  wire [15:0]   last_j0,
    output wire          store_end,
    output wire          store_active,   // para o serial_ok do dma_load

    // Do dma_compute
    input  wire          compute_end,

    // Acelerador
    input  wire          c_valid,
    output wire          c_release,

    // Para o dma_wr_engine
    output wire          wr_cmd_valid,
    input  wire          wr_cmd_ready,
    output wire [31:0]   wr_cmd_addr,
    output wire [CW-1:0] wr_cmd_nwords,
    output wire [IW-1:0] wr_cmd_row,
    input  wire          wr_done
);

    // -----------------------------------------------------------------
    // Constantes
    // -----------------------------------------------------------------
    localparam [2:0] S_IDLE      = 3'd0,
                     S_WAIT_C    = 3'd1,
                     S_ROW       = 3'd2,
                     S_WAIT_TILE = 3'd3,
                     S_RELEASE   = 3'd4,
                     S_END       = 3'd5;

    localparam [IW-1:0] LAST_ROW = ARRAY_SIZE - 1;
    localparam [15:0]   T16      = ARRAY_SIZE;

    // -----------------------------------------------------------------
    // Registradores
    // -----------------------------------------------------------------
    reg [2:0]    state_q, state_d;
    reg [15:0]   i0s_q, j0s_q;      // tile sendo gravado
    reg [IW-1:0] r_q;               // linha do tile
    reg [31:0]   row_c0_q;          // endereco de C[i0s][0]
    reg [31:0]   ptr_c_q;           // endereco de C[i0s + r][j0s]
    reg [CW-1:0] issued_q;          // linhas entregues ao motor neste tile
    reg [CW-1:0] rows_done_q;       // linhas com B recebido neste tile

    // -----------------------------------------------------------------
    // Logica combinacional de apoio
    // -----------------------------------------------------------------
    wire [CW-1:0] m_rows;     // linhas validas do tile: min(T, M - i0s)
    wire [CW-1:0] n_words;    // palavras validas por linha: min(T, N - j0s)

    dma_tile_span #(.ARRAY_SIZE(ARRAY_SIZE)) u_span_m (
        .dim    (dim_m),
        .origin (i0s_q),
        .span   (m_rows)
    );

    dma_tile_span #(.ARRAY_SIZE(ARRAY_SIZE)) u_span_n (
        .dim    (dim_n),
        .origin (j0s_q),
        .span   (n_words)
    );

    wire [CW-1:0] r_ext     = {{(CW-IW){1'b0}}, r_q};
    wire          row_in    = (r_ext < m_rows);     // i0s + r < M
    wire          at_last_j = (j0s_q == last_j0);
    wire          last_tile = (i0s_q == last_i0) & at_last_j;

    wire [31:0]   tile_step_c = {14'd0, stride_c} << IW;   // T * STRIDE_C

    // -----------------------------------------------------------------
    // Proximo estado e strobes de acao
    // -----------------------------------------------------------------
    reg op_init;        // comeco da operacao
    reg tile_init;      // comeco da gravacao de um tile
    reg row_fire;       // linha aceita pelo motor
    reg tile_advance;   // proximo tile (j0s, depois i0s)

    always @(*) begin
        state_d      = state_q;
        op_init      = 1'b0;
        tile_init    = 1'b0;
        row_fire     = 1'b0;
        tile_advance = 1'b0;

        case (state_q)
            S_IDLE: begin
                if (run) begin
                    state_d = S_WAIT_C;
                    op_init = 1'b1;
                end
            end

            S_WAIT_C: begin
                if (c_valid && stop) begin
                    state_d = S_RELEASE;            // descarta sem gravar
                end else if (c_valid) begin
                    state_d   = S_ROW;
                    tile_init = 1'b1;
                end else if (stop && compute_end) begin
                    state_d = S_END;
                end
            end

            S_ROW: begin
                if (stop || !row_in) begin
                    // dreno, ou linha fora da matriz (as seguintes tambem estao)
                    state_d = S_WAIT_TILE;
                end else if (wr_cmd_ready) begin
                    row_fire = 1'b1;
                    state_d  = (r_q != LAST_ROW) ? S_ROW : S_WAIT_TILE;
                end
            end

            S_WAIT_TILE: begin
                if (rows_done_q == issued_q)
                    state_d = S_RELEASE;
            end

            S_RELEASE: begin
                tile_advance = 1'b1;
                state_d      = last_tile ? S_END : S_WAIT_C;
            end

            S_END: begin
                if (!run)
                    state_d = S_IDLE;
            end

            default: state_d = S_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= S_IDLE;
        else        state_q <= state_d;
    end

    // -----------------------------------------------------------------
    // Datapath: tile corrente e base da linha de tiles
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i0s_q    <= 16'd0;
            j0s_q    <= 16'd0;
            row_c0_q <= 32'd0;
        end else if (op_init) begin
            i0s_q    <= 16'd0;
            j0s_q    <= 16'd0;
            row_c0_q <= addr_c;
        end else if (tile_advance) begin
            if (!at_last_j) begin
                j0s_q <= j0s_q + T16;
            end else begin
                j0s_q    <= 16'd0;
                i0s_q    <= i0s_q + T16;
                row_c0_q <= row_c0_q + tile_step_c;
            end
        end
    end

    // Linha atual e linhas entregues
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_q      <= {IW{1'b0}};
            ptr_c_q  <= 32'd0;
            issued_q <= {CW{1'b0}};
        end else if (tile_init) begin
            r_q      <= {IW{1'b0}};
            ptr_c_q  <= row_c0_q + {14'd0, j0s_q, 2'b00};
            issued_q <= {CW{1'b0}};
        end else if (row_fire) begin
            r_q      <= r_q + 1'b1;
            ptr_c_q  <= ptr_c_q + {14'd0, stride_c};
            issued_q <= issued_q + 1'b1;
        end
    end

    // Linhas concluidas (B recebido) neste tile
    wire count_wr_done = wr_done & ((state_q == S_ROW) | (state_q == S_WAIT_TILE));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rows_done_q <= {CW{1'b0}};
        else if (tile_init)
            rows_done_q <= {CW{1'b0}};
        else if (count_wr_done)
            rows_done_q <= rows_done_q + 1'b1;
    end

    // -----------------------------------------------------------------
    // Saidas
    // -----------------------------------------------------------------
    assign wr_cmd_valid  = (state_q == S_ROW) & ~stop & row_in;
    assign wr_cmd_addr   = ptr_c_q;
    assign wr_cmd_nwords = n_words;
    assign wr_cmd_row    = r_q;

    assign c_release     = (state_q == S_RELEASE);
    assign store_end     = (state_q == S_END);
    assign store_active  = (state_q == S_ROW) | (state_q == S_WAIT_TILE)
                         | (state_q == S_RELEASE);

endmodule

`default_nettype wire
