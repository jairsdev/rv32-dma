`timescale 1ns/1ps
`default_nettype none

// Disparo dos tiles na malha (MAS secao 9.3).
//
//   C_IDLE --run--> C_WAIT_FULL --banco FULL & ~acc_busy--> C_START (1 ciclo)
//   C_START --> C_WAIT_DONE --tile_done--> C_FREE
//   C_FREE  --last_blk--> C_END  |  --senao--> C_WAIT_FULL
//   C_WAIT_FULL --stop--> C_END   (no dreno nenhum tile novo e disparado)
//   C_END   --~run--> C_IDLE
//
// Em C_WAIT_DONE o stop nao interrompe: o tile em andamento termina normalmente.
// Os metadados (first_k, last_k, last_blk) vem do dma_bank_ctrl para o banco
// cp_ptr, que so muda em C_FREE; por isso ficam estaveis com tile_start.
module dma_compute (
    input  wire clk,
    input  wire rst_n,

    // Do dma_ctrl
    input  wire run,
    input  wire stop,
    output wire compute_end,

    // Do/para o dma_bank_ctrl
    input  wire cp_ptr,
    input  wire cp_bank_full,
    input  wire cp_first_k,
    input  wire cp_last_k,
    input  wire cp_last_blk,
    output wire cp_start,
    output wire cp_free,

    // Acelerador
    input  wire acc_busy,
    input  wire tile_done,
    output wire tile_start,
    output wire tile_bank,
    output wire first_k,
    output wire last_k
);

    localparam [2:0] C_IDLE      = 3'd0,
                     C_WAIT_FULL = 3'd1,
                     C_START     = 3'd2,
                     C_WAIT_DONE = 3'd3,
                     C_FREE      = 3'd4,
                     C_END       = 3'd5;

    reg [2:0] state_q, state_d;

    // -----------------------------------------------------------------
    // Proximo estado (ordem dos ifs = prioridade do MAS)
    // -----------------------------------------------------------------
    always @(*) begin
        state_d = state_q;
        case (state_q)
            C_IDLE: begin
                if (run)
                    state_d = C_WAIT_FULL;
            end

            C_WAIT_FULL: begin
                if (stop)
                    state_d = C_END;
                else if (cp_bank_full && !acc_busy)
                    state_d = C_START;
            end

            C_START: state_d = C_WAIT_DONE;

            C_WAIT_DONE: begin
                if (tile_done)
                    state_d = C_FREE;
            end

            C_FREE: begin
                // Banco ainda em COMPUTING aqui: last_blk e o do tile que acabou
                state_d = cp_last_blk ? C_END : C_WAIT_FULL;
            end

            C_END: begin
                if (!run)
                    state_d = C_IDLE;
            end

            default: state_d = C_IDLE;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) state_q <= C_IDLE;
        else        state_q <= state_d;
    end

    // -----------------------------------------------------------------
    // Saidas (Moore)
    // -----------------------------------------------------------------
    assign tile_start  = (state_q == C_START);
    assign tile_bank   = cp_ptr;
    assign first_k     = cp_first_k;
    assign last_k      = cp_last_k;

    assign cp_start    = (state_q == C_START);
    assign cp_free     = (state_q == C_FREE);

    assign compute_end = (state_q == C_END);

endmodule

`default_nettype wire
