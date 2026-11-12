`timescale 1ns/1ps
`default_nettype none

// Estado dos bancos de A/B do acelerador (MAS secao 7.8).
//
//   BK_EMPTY --ld_claim--> BK_LOADING --ld_full--> BK_FULL
//   BK_FULL  --cp_start--> BK_COMPUTING --cp_free--> BK_EMPTY
//
// ld_ptr: banco do proximo bloco carregado (dma_load).
// cp_ptr: banco do proximo tile disparado (dma_compute).
// Os dois comecam em 0 e alternam (^= PINGPONG) a cada bloco, entao load e
// compute percorrem os bancos na mesma ordem.
// bank_clr (pulso do CHECK) volta tudo para EMPTY e os ponteiros para 0.
//
// Os eventos de load e de compute nunca atingem o mesmo banco no mesmo ciclo:
// o load so mexe em EMPTY/LOADING e o compute so em FULL/COMPUTING.
module dma_bank_ctrl #(
    parameter PINGPONG = 1
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire       bank_clr,

    // Do dma_load
    input  wire       ld_claim,       // banco ld_ptr: EMPTY -> LOADING
    input  wire       ld_full,        // banco ld_ptr: LOADING -> FULL (+ metadados)
    input  wire       ld_first_k,
    input  wire       ld_last_k,
    input  wire       ld_last_blk,

    // Do dma_compute
    input  wire       cp_start,       // banco cp_ptr: FULL -> COMPUTING
    input  wire       cp_free,        // banco cp_ptr: COMPUTING -> EMPTY

    // Para o dma_load
    output wire       ld_ptr,
    output wire       ld_bank_empty,

    // Para o dma_compute
    output wire       cp_ptr,
    output wire       cp_bank_full,
    output wire       cp_first_k,
    output wire       cp_last_k,
    output wire       cp_last_blk,

    // Para as assercoes: {estado do banco 1, estado do banco 0}
    output wire [3:0] bank_state_flat
);

    localparam PTR_TOGGLE = (PINGPONG != 0) ? 1'b1 : 1'b0;

    localparam [1:0] BK_EMPTY     = 2'd0,
                     BK_LOADING   = 2'd1,
                     BK_FULL      = 2'd2,
                     BK_COMPUTING = 2'd3;

    reg [1:0] state_q    [0:1];
    reg       first_k_q  [0:1];
    reg       last_k_q   [0:1];
    reg       last_blk_q [0:1];
    reg       ld_ptr_q;
    reg       cp_ptr_q;

    integer b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (b = 0; b < 2; b = b + 1) begin
                state_q[b]    <= BK_EMPTY;
                first_k_q[b]  <= 1'b0;
                last_k_q[b]   <= 1'b0;
                last_blk_q[b] <= 1'b0;
            end
            ld_ptr_q <= 1'b0;
            cp_ptr_q <= 1'b0;
        end else if (bank_clr) begin
            for (b = 0; b < 2; b = b + 1) begin
                state_q[b]    <= BK_EMPTY;
                first_k_q[b]  <= 1'b0;
                last_k_q[b]   <= 1'b0;
                last_blk_q[b] <= 1'b0;
            end
            ld_ptr_q <= 1'b0;
            cp_ptr_q <= 1'b0;
        end else begin
            // Lado do load
            if (ld_claim)
                state_q[ld_ptr_q] <= BK_LOADING;
            if (ld_full) begin
                state_q[ld_ptr_q]    <= BK_FULL;
                first_k_q[ld_ptr_q]  <= ld_first_k;
                last_k_q[ld_ptr_q]   <= ld_last_k;
                last_blk_q[ld_ptr_q] <= ld_last_blk;
                ld_ptr_q             <= ld_ptr_q ^ PTR_TOGGLE;
            end

            // Lado do compute
            if (cp_start)
                state_q[cp_ptr_q] <= BK_COMPUTING;
            if (cp_free) begin
                state_q[cp_ptr_q] <= BK_EMPTY;
                cp_ptr_q          <= cp_ptr_q ^ PTR_TOGGLE;
            end
        end
    end

    assign ld_ptr        = ld_ptr_q;
    assign ld_bank_empty = (state_q[ld_ptr_q] == BK_EMPTY);

    assign cp_ptr        = cp_ptr_q;
    assign cp_bank_full  = (state_q[cp_ptr_q] == BK_FULL);
    assign cp_first_k    = first_k_q[cp_ptr_q];
    assign cp_last_k     = last_k_q[cp_ptr_q];
    assign cp_last_blk   = last_blk_q[cp_ptr_q];

    // Com PINGPONG = 0 o banco 1 nunca sai de EMPTY (ponteiros fixos em 0).
    // Os arrays tem sempre 2 posicoes para manter os indices de 1 bit sem
    // generate; com PINGPONG = 0 a sintese remove os flops do banco 1.
    assign bank_state_flat = {state_q[1], state_q[0]};

endmodule

`default_nettype wire
