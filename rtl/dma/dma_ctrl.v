`timescale 1ns/1ps
`default_nettype none

// FSM principal do DMA (MAS secoes 9.1, 8.2 e 13).
//
//   CT_IDLE  --start-->  CT_CHECK
//   CT_CHECK --soft_reset--> CT_IDLE
//            --dimensao 0 / desalinhado--> CT_ERROR
//            --valido--> CT_RUN
//   CT_RUN   --rd_err / wr_err--> CT_DRAIN (abort = 0)
//            --soft_reset--> CT_DRAIN (abort = 1)
//            --load_end & compute_end & store_end--> CT_DONE
//   CT_DRAIN --quiet & ~abort--> CT_ERROR
//            --quiet &  abort--> CT_IDLE (sem DONE)
//   CT_ERROR --> CT_DONE --> CT_IDLE   (1 ciclo cada)
//
// Em CT_CHECK sao calculados e registrados os strides e os limites last_*
// (sem multiplicador) e e dado o pulso de bank_clr (bancos -> EMPTY, ptrs = 0,
// limpa rd_err/wr_err dos motores).
module dma_ctrl #(
    parameter ARRAY_SIZE = 4
)(
    input  wire        clk,
    input  wire        rst_n,

    // Do dma_regs
    input  wire        start,
    input  wire        soft_reset,
    input  wire [31:0] addr_a,
    input  wire [31:0] addr_b,
    input  wire [31:0] addr_c,
    input  wire [15:0] dim_m,
    input  wire [15:0] dim_n,
    input  wire [15:0] dim_k,

    // Das FSMs e dos motores
    input  wire        load_end,
    input  wire        compute_end,
    input  wire        store_end,
    input  wire        rd_idle,
    input  wire        wr_idle,
    input  wire        rd_err,
    input  wire        wr_err,

    // Do acelerador
    input  wire        acc_busy,
    input  wire        c_valid,

    // Controle
    output wire        ctrl_busy,
    output wire        run,
    output wire        stop,
    output wire        bank_clr,
    output wire        done,       // pulso para o dma_regs
    output wire        error,      // pulso para o dma_regs
    output wire [3:0]  err_code,

    // Valores calculados no CHECK (MAS 8.2)
    output wire [17:0] stride_a,
    output wire [17:0] stride_b,
    output wire [17:0] stride_c,
    output wire [15:0] last_i0,
    output wire [15:0] last_j0,
    output wire [15:0] last_k0
);

    // -----------------------------------------------------------------
    // Estados
    // -----------------------------------------------------------------
    localparam [2:0] CT_IDLE  = 3'd0,
                     CT_CHECK = 3'd1,
                     CT_RUN   = 3'd2,
                     CT_DRAIN = 3'd3,
                     CT_ERROR = 3'd4,
                     CT_DONE  = 3'd5;

    localparam [3:0] ERR_NONE  = 4'd0,
                     ERR_DIM   = 4'd1,
                     ERR_ALIGN = 4'd2,
                     ERR_READ  = 4'd3,
                     ERR_WRITE = 4'd4;

    localparam [15:0] TILE_MASK = ~(ARRAY_SIZE - 1);   // T e potencia de 2

    reg [2:0] state_q, state_d;

    // Registradores de datapath (declarados antes do uso na logica de estado)
    reg [3:0]  err_code_q;
    reg        abort_q;
    reg [17:0] stride_a_q, stride_b_q, stride_c_q;
    reg [15:0] last_i0_q, last_j0_q, last_k0_q;

    // -----------------------------------------------------------------
    // Validacao e calculos do CHECK (combinacionais)
    // -----------------------------------------------------------------
    wire dim_zero   = (dim_m == 16'd0) | (dim_n == 16'd0) | (dim_k == 16'd0);
    wire misaligned = (|addr_a[1:0]) | (|addr_b[1:0]) | (|addr_c[1:0]);

    // STRIDE_A = ceil(K/4)*4, STRIDE_B = ceil(N/4)*4, STRIDE_C = 4N
    wire [16:0] k_plus3    = {1'b0, dim_k} + 17'd3;
    wire [16:0] n_plus3    = {1'b0, dim_n} + 17'd3;
    wire [17:0] stride_a_c = {1'b0, k_plus3[16:2], 2'b00};
    wire [17:0] stride_b_c = {1'b0, n_plus3[16:2], 2'b00};
    wire [17:0] stride_c_c = {dim_n, 2'b00};

    // Maior multiplo de T menor que a dimensao: (X - 1) & ~(T - 1)
    wire [15:0] last_i0_c = (dim_m - 16'd1) & TILE_MASK;
    wire [15:0] last_j0_c = (dim_n - 16'd1) & TILE_MASK;
    wire [15:0] last_k0_c = (dim_k - 16'd1) & TILE_MASK;

    // Condicao de saida do dreno (MAS 9.1)
    wire all_end = load_end & compute_end & store_end;
    wire quiet   = all_end & rd_idle & wr_idle & ~acc_busy & ~c_valid;

    // -----------------------------------------------------------------
    // Proximo estado e strobes. A ordem dos ifs e a prioridade do MAS.
    // -----------------------------------------------------------------
    reg       set_err;      // registra err_code_d em err_code_q
    reg [3:0] err_code_d;
    reg       set_abort;    // dreno causado por SOFT_RESET

    always @(*) begin
        state_d    = state_q;
        set_err    = 1'b0;
        err_code_d = ERR_NONE;
        set_abort  = 1'b0;

        case (state_q)
            CT_IDLE: begin
                if (start)
                    state_d = CT_CHECK;
            end

            CT_CHECK: begin
                if (soft_reset) begin
                    state_d = CT_IDLE;
                end else if (dim_zero) begin
                    state_d    = CT_ERROR;
                    set_err    = 1'b1;
                    err_code_d = ERR_DIM;
                end else if (misaligned) begin
                    state_d    = CT_ERROR;
                    set_err    = 1'b1;
                    err_code_d = ERR_ALIGN;
                end else begin
                    state_d = CT_RUN;
                end
            end

            CT_RUN: begin
                if (rd_err) begin                 // leitura vence escrita
                    state_d    = CT_DRAIN;
                    set_err    = 1'b1;
                    err_code_d = ERR_READ;
                end else if (wr_err) begin
                    state_d    = CT_DRAIN;
                    set_err    = 1'b1;
                    err_code_d = ERR_WRITE;
                end else if (soft_reset) begin
                    state_d   = CT_DRAIN;
                    set_abort = 1'b1;
                end else if (all_end) begin
                    state_d = CT_DONE;
                end
            end

            CT_DRAIN: begin
                // abort_q e err_code_q ficam congelados: o desfecho ja foi decidido
                if (quiet)
                    state_d = abort_q ? CT_IDLE : CT_ERROR;
            end

            CT_ERROR: state_d = CT_DONE;
            CT_DONE:  state_d = CT_IDLE;
            default:  state_d = CT_IDLE;
        endcase
    end

    // -----------------------------------------------------------------
    // Registrador de estado
    // -----------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= CT_IDLE;
        else        state_q <= state_d;
    end

    // -----------------------------------------------------------------
    // Datapath
    // -----------------------------------------------------------------

    // Desfecho da operacao
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            err_code_q <= ERR_NONE;
            abort_q    <= 1'b0;
        end else begin
            if (state_q == CT_CHECK) begin
                err_code_q <= ERR_NONE;
                abort_q    <= 1'b0;
            end
            if (set_err)
                err_code_q <= err_code_d;     // vence o clear acima
            if (set_abort)
                abort_q <= 1'b1;
        end
    end

    // Geometria da operacao: congelada fora do CHECK. O dma_regs bloqueia
    // ADDR_*/DIM_* enquanto ctrl_busy = 1, entao as entradas ficam estaveis.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            stride_a_q <= 18'd0;
            stride_b_q <= 18'd0;
            stride_c_q <= 18'd0;
            last_i0_q  <= 16'd0;
            last_j0_q  <= 16'd0;
            last_k0_q  <= 16'd0;
        end else if (state_q == CT_CHECK) begin
            stride_a_q <= stride_a_c;
            stride_b_q <= stride_b_c;
            stride_c_q <= stride_c_c;
            last_i0_q  <= last_i0_c;
            last_j0_q  <= last_j0_c;
            last_k0_q  <= last_k0_c;
        end
    end

    // -----------------------------------------------------------------
    // Saidas (Moore)
    // -----------------------------------------------------------------
    assign ctrl_busy = (state_q != CT_IDLE);
    assign run       = (state_q == CT_RUN) | (state_q == CT_DRAIN);
    assign stop      = (state_q == CT_DRAIN);
    assign bank_clr  = (state_q == CT_CHECK);
    assign error     = (state_q == CT_ERROR);
    assign done      = (state_q == CT_DONE);
    assign err_code  = err_code_q;

    assign stride_a  = stride_a_q;
    assign stride_b  = stride_b_q;
    assign stride_c  = stride_c_q;
    assign last_i0   = last_i0_q;
    assign last_j0   = last_j0_q;
    assign last_k0   = last_k0_q;

endmodule

`default_nettype wire
