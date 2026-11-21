//-----------------------------------------------------------------
//                AXI4 -> Async SRAM (16-bit) Interface
//                              V0.1
//                        Ultra-Embedded.com
//                          Copyright 2019
//
//                 Email: admin@ultra-embedded.com
//
//                       License: LGPL
//-----------------------------------------------------------------
//
// This source file may be used and distributed without
// restriction provided that this copyright statement is not
// removed from the file and that any derivative work contains
// the original copyright notice and the associated disclaimer.
//
// This source file is free software; you can redistribute it
// and/or modify it under the terms of the GNU Lesser General
// Public License as published by the Free Software Foundation;
// either version 2.1 of the License, or (at your option) any
// later version.
//
// This source is distributed in the hope that it will be
// useful, but WITHOUT ANY WARRANTY; without even the implied
// warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
// PURPOSE.  See the GNU Lesser General Public License for more
// details.
//
// You should have received a copy of the GNU Lesser General
// Public License along with this source; if not, write to the
// Free Software Foundation, Inc., 59 Temple Place, Suite 330,
// Boston, MA  02111-1307  USA
//-----------------------------------------------------------------

//-----------------------------------------------------------------
//                          Generated File
//-----------------------------------------------------------------

//-----------------------------------------------------------------
// OBRA DERIVADA (LGPL) - axi_transaction_manager
//
// Derivada de rtl/third_party/ultra_embedded_asram16_axi4/asram16_axi4_pmem.v
// (Ultra-Embedded, v0.1, 2019), que permanece no repositorio sem alteracao.
// O aviso de copyright e a licenca acima foram preservados integralmente.
// Projeto interface_amba (TCC) - MAS_axi4_sram.md §5.4, decisao D10.
//
// Toda linha nova ou alterada traz o marcador "// A<n>". O codigo herdado nao
// foi reformatado. Lista completa e fechada das alteracoes (MAS §5.4.5):
//   A0  modulo renomeado de asram16_axi4_pmem para axi_transaction_manager
//   A1  portas axi_awsize_i / axi_arsize_i
//   A2  calculate_addr_next recebe axsize e aplica Aligned_Address
//   A3  registrador req_axsize_q
//   A4  saida ram_size_o
//   A5  FIFO de requisicoes de 6 para 11 bits + saidas resp_addr_lo_o / resp_size_o
//   A6  FIFO renomeado para axi_transaction_fifo
//   A7  saida ram_wr_req_o: beat com wstrb=0000 passa a gerar requisicao (e a avancar o burst)
// Auditoria: make audit_fork
//-----------------------------------------------------------------

module axi_transaction_manager // A0
(
    // Inputs
     input           clk_i
    ,input           rst_i
    ,input           axi_awvalid_i
    ,input  [ 31:0]  axi_awaddr_i
    ,input  [  3:0]  axi_awid_i
    ,input  [  7:0]  axi_awlen_i
    ,input  [  1:0]  axi_awburst_i
    ,input  [  2:0]  axi_awsize_i // A1
    ,input           axi_wvalid_i
    ,input  [ 31:0]  axi_wdata_i
    ,input  [  3:0]  axi_wstrb_i
    ,input           axi_wlast_i
    ,input           axi_bready_i
    ,input           axi_arvalid_i
    ,input  [ 31:0]  axi_araddr_i
    ,input  [  3:0]  axi_arid_i
    ,input  [  7:0]  axi_arlen_i
    ,input  [  1:0]  axi_arburst_i
    ,input  [  2:0]  axi_arsize_i // A1
    ,input           axi_rready_i
    ,input           ram_accept_i
    ,input           ram_ack_i
    ,input           ram_error_i
    ,input  [ 31:0]  ram_read_data_i

    // Outputs
    ,output          axi_awready_o
    ,output          axi_wready_o
    ,output          axi_bvalid_o
    ,output [  1:0]  axi_bresp_o
    ,output [  3:0]  axi_bid_o
    ,output          axi_arready_o
    ,output          axi_rvalid_o
    ,output [ 31:0]  axi_rdata_o
    ,output [  1:0]  axi_rresp_o
    ,output [  3:0]  axi_rid_o
    ,output          axi_rlast_o
    ,output [  3:0]  ram_wr_o
    ,output          ram_rd_o
    ,output [  7:0]  ram_len_o
    ,output [ 31:0]  ram_addr_o
    ,output [ 31:0]  ram_write_data_o
    ,output [  2:0]  ram_size_o // A4
    ,output          ram_wr_req_o // A7
    ,output [  1:0]  resp_addr_lo_o // A5
    ,output [  2:0]  resp_size_o // A5
);



//-------------------------------------------------------------
// calculate_addr_next
//-------------------------------------------------------------
function [31:0] calculate_addr_next;
    input [31:0] addr;
    input [1:0]  axtype;
    input [7:0]  axlen;
    input [2:0]  axsize; // A2

    reg [31:0]   mask;
    reg [31:0]   num_bytes; // A2
    reg [31:0]   aligned; // A2
begin
    mask = 0;
    num_bytes = 32'd1 << axsize; // A2
    aligned   = addr & ~(num_bytes - 32'd1); // A2

    case (axtype)
`ifdef SUPPORT_FIXED_BURST
    2'd0: // AXI4_BURST_FIXED
        calculate_addr_next = addr;
`endif
`ifdef SUPPORT_WRAP_BURST
    2'd2: // AXI4_BURST_WRAP
    begin
        mask = (num_bytes * (axlen + 32'd1)) - 32'd1; // A2 (Wrap_Boundary da norma)

        calculate_addr_next = (addr & ~mask) | ((aligned + num_bytes) & mask); // A2
    end
`endif
    default: // AXI4_BURST_INCR
        calculate_addr_next = aligned + num_bytes; // A2
    endcase
end
endfunction

//-----------------------------------------------------------------
// Registers / Wires
//-----------------------------------------------------------------
reg [7:0]   req_len_q;
reg [31:0]  req_addr_q;
reg         req_rd_q;
reg         req_wr_q;
reg [3:0]   req_id_q;
reg [1:0]   req_axburst_q;
reg [7:0]   req_axlen_q;
reg [2:0]   req_axsize_q; // A3
reg         req_prio_q;
reg         req_hold_rd_q;
reg         req_hold_wr_q;

wire        req_fifo_accept_w;

//-----------------------------------------------------------------
// Sequential
//-----------------------------------------------------------------
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    req_len_q     <= 8'b0;
    req_addr_q    <= 32'b0;
    req_wr_q      <= 1'b0;
    req_rd_q      <= 1'b0;
    req_id_q      <= 4'b0;
    req_axburst_q <= 2'b0;
    req_axlen_q   <= 8'b0;
    req_axsize_q  <= 3'b0; // A3
    req_prio_q    <= 1'b0;
end
else
begin
    // Burst continuation
    if ((ram_wr_req_o || ram_rd_o) && ram_accept_i) // A7
    begin
        if (req_len_q == 8'd0)
        begin
            req_rd_q   <= 1'b0;
            req_wr_q   <= 1'b0;
        end
        else
        begin
            req_addr_q <= calculate_addr_next(req_addr_q, req_axburst_q, req_axlen_q, req_axsize_q); // A2
            req_len_q  <= req_len_q - 8'd1;
        end
    end

    // Write command accepted
    if (axi_awvalid_i && axi_awready_o)
    begin
        // Data ready?
        if (axi_wvalid_i && axi_wready_o)
        begin
            req_wr_q      <= !axi_wlast_i;
            req_len_q     <= axi_awlen_i - 8'd1;
            req_id_q      <= axi_awid_i;
            req_axburst_q <= axi_awburst_i;
            req_axlen_q   <= axi_awlen_i;
            req_axsize_q  <= axi_awsize_i; // A3
            req_addr_q    <= calculate_addr_next(axi_awaddr_i, axi_awburst_i, axi_awlen_i, axi_awsize_i); // A2
        end
        // Data not ready
        else
        begin
            req_wr_q      <= 1'b1;
            req_len_q     <= axi_awlen_i;
            req_id_q      <= axi_awid_i;
            req_axburst_q <= axi_awburst_i;
            req_axlen_q   <= axi_awlen_i;
            req_axsize_q  <= axi_awsize_i; // A3
            req_addr_q    <= axi_awaddr_i;
        end
        req_prio_q    <= !req_prio_q;
    end
    // Read command accepted
    else if (axi_arvalid_i && axi_arready_o)
    begin
        req_rd_q      <= (axi_arlen_i != 0);
        req_len_q     <= axi_arlen_i - 8'd1;
        req_addr_q    <= calculate_addr_next(axi_araddr_i, axi_arburst_i, axi_arlen_i, axi_arsize_i); // A2
        req_id_q      <= axi_arid_i;
        req_axburst_q <= axi_arburst_i;
        req_axlen_q   <= axi_arlen_i;
        req_axsize_q  <= axi_arsize_i; // A3
        req_prio_q    <= !req_prio_q;
    end
end

always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    req_hold_rd_q   <= 1'b0;
    req_hold_wr_q   <= 1'b0;
end
else
begin
    if (ram_rd_o && !ram_accept_i)
        req_hold_rd_q   <= 1'b1;
    else if (ram_accept_i)
        req_hold_rd_q   <= 1'b0;

    if (ram_wr_req_o && !ram_accept_i) // A7
        req_hold_wr_q   <= 1'b1;
    else if (ram_accept_i)
        req_hold_wr_q   <= 1'b0;
end

//-----------------------------------------------------------------
// Request tracking
//-----------------------------------------------------------------
wire       req_push_w = (ram_rd_o || ram_wr_req_o) && ram_accept_i; // A7
reg [10:0] req_in_r; // A5

wire       req_out_valid_w;
wire [10:0] req_out_w; // A5
wire       resp_accept_w;


always @ *
begin
    req_in_r = 11'b0; // A5

    // First cycle of read burst
    if (axi_arvalid_i && axi_arready_o)
        req_in_r = {1'b1, (axi_arlen_i == 8'd0), axi_arid_i, axi_araddr_i[1:0], axi_arsize_i}; // A5
    // First cycle of write burst
    else if (axi_awvalid_i && axi_awready_o)
        req_in_r = {1'b0, (axi_awlen_i == 8'd0), axi_awid_i, axi_awaddr_i[1:0], axi_awsize_i}; // A5
    // In burst
    else
        req_in_r = {ram_rd_o, (req_len_q == 8'd0), req_id_q, req_addr_q[1:0], req_axsize_q}; // A5
end

axi_transaction_fifo // A6
#( .WIDTH(1 + 1 + 4 + 2 + 3) ) // A5
u_requests
(
    .clk_i(clk_i),
    .rst_i(rst_i),

    // Input
    .data_in_i(req_in_r),
    .push_i(req_push_w),
    .accept_o(req_fifo_accept_w),

    // Output
    .pop_i(resp_accept_w),
    .data_out_o(req_out_w),
    .valid_o(req_out_valid_w)
);

wire resp_is_write_w = req_out_valid_w ? ~req_out_w[10] : 1'b0; // A5
wire resp_is_read_w  = req_out_valid_w ? req_out_w[10]  : 1'b0; // A5
wire resp_is_last_w  = req_out_w[9]; // A5
wire [3:0] resp_id_w = req_out_w[8:5]; // A5
assign resp_addr_lo_o = req_out_w[4:3]; // A5
assign resp_size_o    = req_out_w[2:0]; // A5

//-----------------------------------------------------------------
// Response buffering
//-----------------------------------------------------------------
wire resp_valid_w;

axi_transaction_fifo // A6
#( .WIDTH(32) )
u_response
(
    .clk_i(clk_i),
    .rst_i(rst_i),

    // Input
    .data_in_i(ram_read_data_i),
    .push_i(ram_ack_i),
    .accept_o(),

    // Output
    .pop_i(resp_accept_w),
    .data_out_o(axi_rdata_o),
    .valid_o(resp_valid_w)
);

//-----------------------------------------------------------------
// RAM Request
//-----------------------------------------------------------------

// Round robin priority between read and write
wire write_prio_w   = ((req_prio_q  & !req_hold_rd_q) | req_hold_wr_q);
wire read_prio_w    = ((!req_prio_q & !req_hold_wr_q) | req_hold_rd_q);

wire write_active_w  = (axi_awvalid_i || req_wr_q) && !req_rd_q && req_fifo_accept_w && (write_prio_w || req_wr_q || !axi_arvalid_i);
wire read_active_w   = (axi_arvalid_i || req_rd_q) && !req_wr_q && req_fifo_accept_w && (read_prio_w || req_rd_q || !axi_awvalid_i);

assign axi_awready_o = write_active_w && !req_wr_q && ram_accept_i && req_fifo_accept_w;
assign axi_wready_o  = write_active_w &&              ram_accept_i && req_fifo_accept_w;
assign axi_arready_o = read_active_w  && !req_rd_q && ram_accept_i && req_fifo_accept_w;

wire [31:0] addr_w   = ((req_wr_q || req_rd_q) ? req_addr_q:
                        write_active_w ? axi_awaddr_i : axi_araddr_i);

wire wr_w    = write_active_w && axi_wvalid_i;
wire rd_w    = read_active_w;

// RAM if
assign ram_addr_o       = addr_w;
assign ram_write_data_o = axi_wdata_i;
assign ram_wr_req_o     = wr_w; // A7
assign ram_rd_o         = rd_w;
assign ram_wr_o         = wr_w ? axi_wstrb_i : 4'b0;
assign ram_len_o        = axi_awvalid_i ? axi_awlen_i:
                          axi_arvalid_i ? axi_arlen_i : 8'b0;

// A4: tamanho do beat apresentado a RAM, na mesma selecao de addr_w
reg [2:0] ram_size_r; // A4
always @ * // A4
begin // A4
    if (req_wr_q || req_rd_q) // A4
        ram_size_r = req_axsize_q; // A4
    else if (write_active_w) // A4
        ram_size_r = axi_awsize_i; // A4
    else // A4
        ram_size_r = axi_arsize_i; // A4
end // A4
assign ram_size_o = ram_size_r; // A4

//-----------------------------------------------------------------
// Response
//-----------------------------------------------------------------
assign axi_bvalid_o  = resp_valid_w & resp_is_write_w & resp_is_last_w;
assign axi_bresp_o   = 2'b0;
assign axi_bid_o     = resp_id_w;

assign axi_rvalid_o  = resp_valid_w & resp_is_read_w;
assign axi_rresp_o   = 2'b0;
assign axi_rid_o     = resp_id_w;
assign axi_rlast_o   = resp_is_last_w;

assign resp_accept_w    = (axi_rvalid_o & axi_rready_i) | 
                          (axi_bvalid_o & axi_bready_i) |
                          (resp_valid_w & resp_is_write_w & !resp_is_last_w); // Ignore write resps mid burst

endmodule

//-----------------------------------------------------------------
// FIFO
//-----------------------------------------------------------------
module axi_transaction_fifo // A6

//-----------------------------------------------------------------
// Params
//-----------------------------------------------------------------
#(
    parameter WIDTH   = 8,
    parameter DEPTH   = 4,
    parameter ADDR_W  = 2
)
//-----------------------------------------------------------------
// Ports
//-----------------------------------------------------------------
(
    // Inputs
     input               clk_i
    ,input               rst_i
    ,input  [WIDTH-1:0]  data_in_i
    ,input               push_i
    ,input               pop_i

    // Outputs
    ,output [WIDTH-1:0]  data_out_o
    ,output              accept_o
    ,output              valid_o
);

//-----------------------------------------------------------------
// Local Params
//-----------------------------------------------------------------
localparam COUNT_W = ADDR_W + 1;

//-----------------------------------------------------------------
// Registers
//-----------------------------------------------------------------
reg [WIDTH-1:0]         ram [DEPTH-1:0];
reg [ADDR_W-1:0]        rd_ptr;
reg [ADDR_W-1:0]        wr_ptr;
reg [COUNT_W-1:0]       count;

//-----------------------------------------------------------------
// Sequential
//-----------------------------------------------------------------
always @ (posedge clk_i or posedge rst_i)
if (rst_i)
begin
    count   <= {(COUNT_W) {1'b0}};
    rd_ptr  <= {(ADDR_W) {1'b0}};
    wr_ptr  <= {(ADDR_W) {1'b0}};
end
else
begin
    // Push
    if (push_i & accept_o)
    begin
        ram[wr_ptr] <= data_in_i;
        wr_ptr      <= wr_ptr + 1;
    end

    // Pop
    if (pop_i & valid_o)
        rd_ptr      <= rd_ptr + 1;

    // Count up
    if ((push_i & accept_o) & ~(pop_i & valid_o))
        count <= count + 1;
    // Count down
    else if (~(push_i & accept_o) & (pop_i & valid_o))
        count <= count - 1;
end

//-------------------------------------------------------------------
// Combinatorial
//-------------------------------------------------------------------
/* verilator lint_off WIDTH */
assign accept_o   = (count != DEPTH);
assign valid_o    = (count != 0);
/* verilator lint_on WIDTH */

assign data_out_o = ram[rd_ptr];



endmodule