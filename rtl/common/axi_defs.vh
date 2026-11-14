// Constantes do perfil AXI4 do projeto (MAS secao 4.2 e 15.1).
// Incluir com: `include "axi_defs.vh"  (compilar com -I rtl/common)
`ifndef AXI_DEFS_VH
`define AXI_DEFS_VH

`define AXI_BURST_INCR   2'b01    // unico tipo de burst permitido
`define AXI_SIZE_4B      3'b010   // 4 bytes por beat (fixo)

`define AXI_RESP_OKAY    2'b00
`define AXI_RESP_SLVERR  2'b10
`define AXI_RESP_DECERR  2'b11

`endif
