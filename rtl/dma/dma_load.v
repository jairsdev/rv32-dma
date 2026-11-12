`timescale 1ns/1ps
`default_nettype none

// Produtor de blocos (MAS secoes 9.2, 10.1 e 10.4).
//
// Percorre os blocos na ordem i0 -> j0 -> k0 (k0 no laco interno), espera um
// banco livre e entrega ao dma_rd_engine as T linhas de A e as T linhas de B
// do bloco, uma por ciclo enquanto a fila do motor estiver livre. Conta os
// rd_done e, com as 2T linhas escritas, marca o banco como FULL.
//
// Enderecos sem multiplicador: ponteiros de linha somam o stride a cada
// linha, e T*stride = stride << log2(T).
//
//   L_IDLE --run--> L_WAIT_BANK --banco livre--> L_ROW --2T linhas--> L_WAIT_BLK
//   L_WAIT_BLK --rows_done = 2T--> L_BLOCK_DONE --last_blk--> L_END
//                                               --senao----> L_WAIT_BANK
//   stop: L_WAIT_BANK -> L_END;  L_ROW/L_WAIT_BLK -> L_FLUSH --rd_idle--> L_END
//   L_END --~run--> L_IDLE
module dma_load #(
    parameter ARRAY_SIZE = 4,
    parameter PINGPONG   = 1,
    // derivados, nao sobrescrever
    parameter IW = (ARRAY_SIZE > 1) ? $clog2(ARRAY_SIZE) : 1,
    parameter CW = $clog2(ARRAY_SIZE + 1)
)(
    input  wire          clk,
    input  wire          rst_n,

    // Do dma_ctrl
    input  wire          run,
    input  wire          stop,
    input  wire [31:0]   addr_a,
    input  wire [31:0]   addr_b,
    input  wire [15:0]   dim_m,
    input  wire [15:0]   dim_n,
    input  wire [15:0]   dim_k,
    input  wire [17:0]   stride_a,
    input  wire [17:0]   stride_b,
    input  wire [15:0]   last_i0,
    input  wire [15:0]   last_j0,
    input  wire [15:0]   last_k0,
    output wire          load_end,

    // Do/para o dma_bank_ctrl
    input  wire          ld_ptr,
    input  wire          ld_bank_empty,
    output wire          ld_claim,
    output wire          ld_full,
    output wire          ld_first_k,
    output wire          ld_last_k,
    output wire          ld_last_blk,

    // Condicao serial (PINGPONG = 0): tile anterior ainda nao gravado
    input  wire          c_valid,
    input  wire          store_active,

    // Para o dma_rd_engine
    output wire          rd_cmd_valid,
    input  wire          rd_cmd_ready,
    output wire [31:0]   rd_cmd_addr,
    output wire [CW-1:0] rd_cmd_nbytes,
    output wire          rd_cmd_sel,     // 0 = A, 1 = B
    output wire          rd_cmd_bank,
    output wire [IW-1:0] rd_cmd_row,
    input  wire          rd_done,
    input  wire          rd_idle
);

    // -----------------------------------------------------------------
    // Constantes
    // -----------------------------------------------------------------
    localparam [2:0] L_IDLE       = 3'd0,
                     L_WAIT_BANK  = 3'd1,
                     L_ROW        = 3'd2,
                     L_WAIT_BLK   = 3'd3,
                     L_FLUSH      = 3'd4,
                     L_BLOCK_DONE = 3'd5,
                     L_END        = 3'd6;

    localparam RDW = $clog2(2 * ARRAY_SIZE + 1);       // largura de rows_done

    localparam [IW-1:0]  LAST_ROW   = ARRAY_SIZE - 1;
    localparam [RDW-1:0] BLOCK_ROWS = 2 * ARRAY_SIZE;
    localparam [15:0]    T16        = ARRAY_SIZE;

    localparam SEL_A = 1'b0,
               SEL_B = 1'b1;

    // -----------------------------------------------------------------
    // Registradores
    // -----------------------------------------------------------------
    reg [2:0]     state_q, state_d;
    reg [15:0]    i0_q, j0_q, k0_q;       // canto do bloco atual
    reg [IW-1:0]  r_q;                    // linha dentro do bloco
    reg           sel_q;                  // matriz da linha atual
    reg [31:0]    row_a0_q;               // endereco da linha i0 de A
    reg [31:0]    row_b0_q;               // endereco da linha k0 de B
    reg [31:0]    ptr_a_q;                // endereco da linha atual de A
    reg [31:0]    ptr_b_q;                // endereco da linha atual de B
    reg [RDW-1:0] rows_done_q;            // linhas do bloco ja escritas

    // -----------------------------------------------------------------
    // Logica combinacional de apoio
    // -----------------------------------------------------------------

    // Extensao valida do bloco em cada dimensao
    wire [CW-1:0] a_rows;   // linhas validas de A: min(T, M - i0)
    wire [CW-1:0] k_span;   // colunas validas de A / linhas validas de B
    wire [CW-1:0] j_span;   // colunas validas de B

    dma_tile_span #(.ARRAY_SIZE(ARRAY_SIZE)) u_span_i (
        .dim    (dim_m),
        .origin (i0_q),
        .span   (a_rows)
    );

    dma_tile_span #(.ARRAY_SIZE(ARRAY_SIZE)) u_span_k (
        .dim    (dim_k),
        .origin (k0_q),
        .span   (k_span)
    );

    dma_tile_span #(.ARRAY_SIZE(ARRAY_SIZE)) u_span_j (
        .dim    (dim_n),
        .origin (j0_q),
        .span   (j_span)
    );

    // Linha de padding (i0 + r >= M para A, k0 + r >= K para B) -> nbytes = 0
    wire [CW-1:0] r_ext     = {{(CW-IW){1'b0}}, r_q};
    wire          row_valid = (sel_q == SEL_B) ? (r_ext < k_span) : (r_ext < a_rows);
    wire [CW-1:0] row_bytes = (sel_q == SEL_B) ? j_span : k_span;

    // Fim do percurso
    wire at_last_i = (i0_q == last_i0);
    wire at_last_j = (j0_q == last_j0);
    wire at_last_k = (k0_q == last_k0);
    wire last_blk  = at_last_i & at_last_j & at_last_k;

    // PINGPONG = 0: o primeiro bloco de um tile espera o store do anterior (H5)
    wire serial_ok = (PINGPONG != 0) ? 1'b1
                   : ~((k0_q == 16'd0) & (c_valid | store_active));

    // T * stride, sem multiplicador
    wire [31:0] tile_step_a = {14'd0, stride_a} << IW;
    wire [31:0] tile_step_b = {14'd0, stride_b} << IW;

    // -----------------------------------------------------------------
    // Proximo estado e strobes de acao
    // -----------------------------------------------------------------
    reg op_init;       // comeco da operacao
    reg claim;         // banco ld_ptr -> LOADING; comeco do bloco
    reg row_fire;      // linha aceita pelo motor
    reg sel_to_b;      // ultima linha de A aceita: passa para B
    reg blk_done;      // banco -> FULL; avanca (i0, j0, k0)

    always @(*) begin
        state_d  = state_q;
        op_init  = 1'b0;
        claim    = 1'b0;
        row_fire = 1'b0;
        sel_to_b = 1'b0;
        blk_done = 1'b0;

        case (state_q)
            L_IDLE: begin
                if (run) begin
                    state_d = L_WAIT_BANK;
                    op_init = 1'b1;
                end
            end

            L_WAIT_BANK: begin
                if (stop) begin
                    state_d = L_END;
                end else if (ld_bank_empty && serial_ok) begin
                    state_d = L_ROW;
                    claim   = 1'b1;
                end
            end

            L_ROW: begin
                if (stop) begin
                    state_d = L_FLUSH;
                end else if (rd_cmd_ready) begin
                    row_fire = 1'b1;
                    if (r_q != LAST_ROW) begin
                        state_d = L_ROW;
                    end else if (sel_q == SEL_A) begin
                        state_d  = L_ROW;
                        sel_to_b = 1'b1;
                    end else begin
                        state_d = L_WAIT_BLK;
                    end
                end
            end

            L_WAIT_BLK: begin
                if (stop)
                    state_d = L_FLUSH;
                else if (rows_done_q == BLOCK_ROWS)
                    state_d = L_BLOCK_DONE;
            end

            L_FLUSH: begin
                // Espera as linhas ja aceitas; o banco fica LOADING ate o
                // proximo bank_clr
                if (rd_idle)
                    state_d = L_END;
            end

            L_BLOCK_DONE: begin
                blk_done = 1'b1;
                state_d  = last_blk ? L_END : L_WAIT_BANK;
            end

            L_END: begin
                if (!run)
                    state_d = L_IDLE;
            end

            default: state_d = L_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= L_IDLE;
        else        state_q <= state_d;
    end

    // -----------------------------------------------------------------
    // Datapath: indices do bloco e ponteiros de linha (MAS 10.4)
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            i0_q     <= 16'd0;
            j0_q     <= 16'd0;
            k0_q     <= 16'd0;
            row_a0_q <= 32'd0;
            row_b0_q <= 32'd0;
        end else if (op_init) begin
            i0_q     <= 16'd0;
            j0_q     <= 16'd0;
            k0_q     <= 16'd0;
            row_a0_q <= addr_a;
            row_b0_q <= addr_b;
        end else if (blk_done) begin
            if (!at_last_k) begin
                // proximo bloco k0 do mesmo tile
                k0_q     <= k0_q + T16;
                row_b0_q <= row_b0_q + tile_step_b;
            end else begin
                // k0 volta a 0: proximo tile
                k0_q     <= 16'd0;
                row_b0_q <= addr_b;
                if (!at_last_j) begin
                    j0_q <= j0_q + T16;
                end else begin
                    j0_q     <= 16'd0;
                    i0_q     <= i0_q + T16;
                    row_a0_q <= row_a0_q + tile_step_a;
                end
            end
        end
    end

    // Linha atual dentro do bloco
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_q     <= {IW{1'b0}};
            sel_q   <= SEL_A;
            ptr_a_q <= 32'd0;
            ptr_b_q <= 32'd0;
        end else if (claim) begin
            r_q     <= {IW{1'b0}};
            sel_q   <= SEL_A;
            ptr_a_q <= row_a0_q + {16'd0, k0_q};
        end else if (sel_to_b) begin
            r_q     <= {IW{1'b0}};
            sel_q   <= SEL_B;
            ptr_b_q <= row_b0_q + {16'd0, j0_q};
        end else if (row_fire) begin
            r_q <= r_q + 1'b1;
            if (sel_q == SEL_A)
                ptr_a_q <= ptr_a_q + {14'd0, stride_a};
            else
                ptr_b_q <= ptr_b_q + {14'd0, stride_b};
        end
    end

    // Linhas concluidas pelo motor neste bloco
    wire count_rd_done = rd_done & ((state_q == L_ROW) | (state_q == L_WAIT_BLK));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rows_done_q <= {RDW{1'b0}};
        else if (claim)
            rows_done_q <= {RDW{1'b0}};
        else if (count_rd_done)
            rows_done_q <= rows_done_q + {{(RDW-1){1'b0}}, 1'b1};
    end

    // -----------------------------------------------------------------
    // Saidas
    // -----------------------------------------------------------------
    assign rd_cmd_valid  = (state_q == L_ROW) & ~stop;
    assign rd_cmd_addr   = (sel_q == SEL_B) ? ptr_b_q : ptr_a_q;
    assign rd_cmd_nbytes = row_valid ? row_bytes : {CW{1'b0}};
    assign rd_cmd_sel    = sel_q;
    assign rd_cmd_bank   = ld_ptr;
    assign rd_cmd_row    = r_q;

    assign ld_claim      = claim;
    assign ld_full       = blk_done;
    assign ld_first_k    = (k0_q == 16'd0);
    assign ld_last_k     = at_last_k;
    assign ld_last_blk   = last_blk;

    assign load_end      = (state_q == L_END);

endmodule

`default_nettype wire
