`timescale 1ns/1ps
`default_nettype none

// Assercoes de conflito de banco e de quiescencia (MAS secao 7.8, H1-H6).
// So e instanciado com `define DMA_ASSERT (compilar com iverilog -g2012).
// H3 fica no modelo do acelerador e H7 em um monitor do TB-DMA.
module dma_assert #(
    parameter PINGPONG = 1
)(
    input  wire       clk,
    input  wire       rst_n,

    input  wire [3:0] bank_state_flat,
    input  wire       ld_ptr,
    input  wire       ld_claim,
    input  wire       ld_first_k,
    input  wire       cp_ptr,

    input  wire       buf_a_we,
    input  wire       buf_b_we,
    input  wire       buf_bank,

    input  wire       tile_start,
    input  wire       acc_busy,

    input  wire       c_valid,
    input  wire       c_rd,
    input  wire       c_release,
    input  wire       store_active,

    input  wire       ctrl_busy,
    input  wire       rd_cmd_hs,
    input  wire       wr_cmd_hs,
    input  wire       m_arvalid,
    input  wire       m_awvalid,
    input  wire       m_wvalid
);

    localparam [1:0] BK_EMPTY     = 2'd0,
                     BK_LOADING   = 2'd1,
                     BK_FULL      = 2'd2;

    function [1:0] bank_state;
        input [3:0] flat;
        input       idx;
        begin
            bank_state = idx ? flat[3:2] : flat[1:0];
        end
    endfunction

    // Numero de assercoes que falharam (lido pelos testbenches)
    integer n_fail = 0;

`ifdef DMA_ASSERT
    always @(posedge clk) begin
        if (rst_n) begin
            // H1: o load so escreve num banco EMPTY/LOADING
            if (ld_claim && (bank_state(bank_state_flat, ld_ptr) != BK_EMPTY))
                begin n_fail = n_fail + 1; $error("H1: ld_claim com banco %0d nao EMPTY", ld_ptr); end
            if ((buf_a_we || buf_b_we) &&
                (bank_state(bank_state_flat, buf_bank) != BK_LOADING))
                begin n_fail = n_fail + 1; $error("H1: escrita no banco %0d fora de LOADING", buf_bank); end

            // H2: o compute so dispara com o banco FULL e a malha livre
            if (tile_start && (bank_state(bank_state_flat, cp_ptr) != BK_FULL))
                begin n_fail = n_fail + 1; $error("H2: tile_start com banco %0d nao FULL", cp_ptr); end
            if (tile_start && acc_busy)
                begin n_fail = n_fail + 1; $error("H2: tile_start com acc_busy = 1"); end

            // H4: o store so le C e libera com c_valid = 1
            if (c_rd && !c_valid)
                begin n_fail = n_fail + 1; $error("H4: c_rd com c_valid = 0"); end
            if (c_release && !c_valid)
                begin n_fail = n_fail + 1; $error("H4: c_release com c_valid = 0"); end

            // H5: PINGPONG = 0, primeiro bloco de um tile so depois do store
            if ((PINGPONG == 0) && ld_claim && ld_first_k && (c_valid || store_active))
                begin n_fail = n_fail + 1; $error("H5: carga do primeiro bloco com tile anterior pendente"); end

            // H6: nada novo com ctrl_busy = 0
            if (!ctrl_busy && (rd_cmd_hs || wr_cmd_hs))
                begin n_fail = n_fail + 1; $error("H6: comando aos motores com ctrl_busy = 0"); end
            if (!ctrl_busy && (m_arvalid || m_awvalid || m_wvalid))
                begin n_fail = n_fail + 1; $error("H6: transacao AXI com ctrl_busy = 0"); end
        end
    end
`endif

endmodule

`default_nettype wire
