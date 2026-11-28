// Gerado por sw/rvasm.py --defs sv a partir de mailbox.inc. Nao edite:
// mude o mailbox.inc e rode de novo (make fw).
`timescale 1ns/1ps
package mailbox_pkg;
    localparam logic [31:0] MB_BASE              = 32'h10000000;
    localparam logic [31:0] MB_DOORBELL          = 32'h00000000;
    localparam logic [31:0] MB_FLAGS             = 32'h00000004;
    localparam logic [31:0] MB_ADDR_A            = 32'h00000008;
    localparam logic [31:0] MB_ADDR_B            = 32'h0000000C;
    localparam logic [31:0] MB_ADDR_C            = 32'h00000010;
    localparam logic [31:0] MB_DIM_M             = 32'h00000014;
    localparam logic [31:0] MB_DIM_N             = 32'h00000018;
    localparam logic [31:0] MB_DIM_K             = 32'h0000001C;
    localparam logic [31:0] MB_SR_DELAY          = 32'h00000020;
    localparam logic [31:0] MB_STATE             = 32'h00000040;
    localparam logic [31:0] MB_STATUS            = 32'h00000044;
    localparam logic [31:0] MB_CYCLES            = 32'h00000048;
    localparam logic [31:0] MB_CYC_COMPUTE       = 32'h0000004C;
    localparam logic [31:0] MB_INFO              = 32'h00000050;
    localparam logic [31:0] MB_STATUS_W1C        = 32'h00000054;
    localparam logic [31:0] MB_WAIT_COUNT        = 32'h00000058;
    localparam logic [31:0] MB_BUSY_STATUS       = 32'h0000005C;
    localparam logic [31:0] MB_RB_ADDR_A         = 32'h00000060;
    localparam logic [31:0] MB_RB_DIM_M          = 32'h00000064;
    localparam logic [31:0] MB_END               = 32'h0000007C;
    localparam logic [31:0] MB_SCRATCH           = 32'h00000080;
    localparam logic [31:0] MB_SCRATCH_WORDS     = 32'h00000020;
    localparam logic [31:0] MB_SIZE              = 32'h00000100;
    localparam logic [31:0] F_IRQ                = 32'h00000001;
    localparam logic [31:0] F_CONTEND            = 32'h00000002;
    localparam logic [31:0] F_SOFT_RESET         = 32'h00000004;
    localparam logic [31:0] F_BUSY_WR            = 32'h00000008;
    localparam logic [31:0] ST_RESET             = 32'h00000000;
    localparam logic [31:0] ST_IDLE              = 32'h00000001;
    localparam logic [31:0] ST_RUN               = 32'h00000002;
    localparam logic [31:0] ST_HALT              = 32'h00000003;
    localparam logic [31:0] MB_EXIT              = 32'hFFFFFFFF;
endpackage
