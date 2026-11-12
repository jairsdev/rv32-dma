`timescale 1ns/1ps
`default_nettype none

// Modelo comportamental (so simulacao) de um slave AXI4 com a DMEM.
// Segue o axi_mem_ctrl do MAS 12.2 ate o RTL real existir:
//   - SRAM single-port 16 K x 32 (64 KiB): uma transacao por vez,
//     round-robin entre AR e AW quando os dois estao pendentes;
//   - leitura: 2 ciclos do handshake de AR ao primeiro RVALID, depois 1 beat
//     por ciclo; escrita: WREADY = 1 em M_WR, WSTRB por byte;
//   - fora do perfil (AxBURST != INCR ou AxSIZE != 4 B) ou fora dos 64 KiB:
//     completa todos os beats com SLVERR, sem acessar a memoria.
// Diferencas declaradas em relacao ao axi_mem_ctrl:
//   - addr[31:28] != 4'h1 responde DECERR (faz o papel do slave padrao do
//     xbar, para o teste 16.4-4 sem xbar);
//   - w_first = 1: aceita o burst W inteiro antes de dar AWREADY (exercita o
//     caminho W_ADDR -> W_RESP do dma_wr_engine).
// wr_count[i] conta quantas vezes a palavra i foi escrita (monitor H7).
module axi_mem_model #(
    parameter ID_W      = 1,
    parameter MEM_WORDS = 16384
)(
    input  wire            clk,
    input  wire            rst_n,
    input  wire            w_first,

    input  wire [ID_W-1:0] awid,
    input  wire [31:0]     awaddr,
    input  wire [7:0]      awlen,
    input  wire [2:0]      awsize,
    input  wire [1:0]      awburst,
    input  wire            awvalid,
    output wire            awready,
    input  wire [31:0]     wdata,
    input  wire [3:0]      wstrb,
    input  wire            wlast,
    input  wire            wvalid,
    output wire            wready,
    output reg  [ID_W-1:0] bid,
    output reg  [1:0]      bresp,
    output wire            bvalid,
    input  wire            bready,
    input  wire [ID_W-1:0] arid,
    input  wire [31:0]     araddr,
    input  wire [7:0]      arlen,
    input  wire [2:0]      arsize,
    input  wire [1:0]      arburst,
    input  wire            arvalid,
    output wire            arready,
    output reg  [ID_W-1:0] rid,
    output reg  [31:0]     rdata,
    output reg  [1:0]      rresp,
    output wire            rlast,
    output wire            rvalid,
    input  wire            rready
);

    reg [31:0] mem      [0:MEM_WORDS-1];
    integer    wr_count [0:MEM_WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < MEM_WORDS; i = i + 1) begin
            mem[i]      = 32'd0;
            wr_count[i] = 0;
        end
    end

    localparam [2:0] M_IDLE    = 3'd0,
                     M_RD_WAIT = 3'd1,
                     M_RD      = 3'd2,
                     M_WR      = 3'd3,
                     M_WR_RESP = 3'd4,
                     M_WBUF    = 3'd5,
                     M_WAW     = 3'd6;

    reg [2:0]  state;
    reg        last_was_wr;      // round-robin
    reg [31:0] a;                // endereco corrente
    reg [7:0]  len;
    reg [7:0]  cnt;
    reg [1:0]  err;              // resposta da transacao corrente

    // Buffer do modo w_first
    reg [31:0] wbuf_data [0:15];
    reg [3:0]  wbuf_strb [0:15];
    integer    wbuf_n;

    // Resposta para um pedido
    function [1:0] check_req;
        input [31:0] addr;
        input [2:0]  size;
        input [1:0]  burst;
        begin
            if (addr[31:28] != 4'h1)
                check_req = 2'b11;                          // DECERR
            else if (addr[27:16] != 12'd0 || size != 3'b010 || burst != 2'b01)
                check_req = 2'b10;                          // SLVERR
            else
                check_req = 2'b00;                          // OKAY
        end
    endfunction

    // Escolha em M_IDLE
    wire pick_rd = (state == M_IDLE) & arvalid & (~awvalid | last_was_wr);
    wire pick_wr = (state == M_IDLE) & awvalid & ~pick_rd;

    assign arready = pick_rd;
    assign awready = (pick_wr & ~w_first) | ((state == M_WAW) & awvalid);
    assign wready  = (state == M_WR) | (state == M_WBUF);
    assign rvalid  = (state == M_RD);
    assign bvalid  = (state == M_WR_RESP);
    assign rlast   = (state == M_RD) & (cnt == len);

    task write_word;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        integer b;
        reg [31:0] w;
        begin
            w = mem[addr[15:2]];
            for (b = 0; b < 4; b = b + 1)
                if (strb[b]) w[8*b +: 8] = data[8*b +: 8];
            mem[addr[15:2]]      = w;
            wr_count[addr[15:2]] = wr_count[addr[15:2]] + 1;
        end
    endtask

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= M_IDLE;
            last_was_wr <= 1'b0;
            a           <= 32'd0;
            len         <= 8'd0;
            cnt         <= 8'd0;
            err         <= 2'b00;
            rid         <= {ID_W{1'b0}};
            rdata       <= 32'd0;
            rresp       <= 2'b00;
            bid         <= {ID_W{1'b0}};
            bresp       <= 2'b00;
            wbuf_n      = 0;
        end else begin
            case (state)
                M_IDLE: begin
                    if (pick_rd) begin
                        a     <= {araddr[31:2], 2'b00};
                        len   <= arlen;
                        cnt   <= 8'd0;
                        err   <= check_req(araddr, arsize, arburst);
                        rid   <= arid;
                        state <= M_RD_WAIT;
                    end else if (pick_wr && !w_first) begin
                        a     <= {awaddr[31:2], 2'b00};
                        len   <= awlen;
                        err   <= check_req(awaddr, awsize, awburst);
                        bid   <= awid;
                        state <= M_WR;
                    end else if (pick_wr) begin
                        wbuf_n = 0;
                        state <= M_WBUF;
                    end
                end

                M_RD_WAIT: begin
                    rdata <= (err == 2'b00) ? mem[a[15:2]] : 32'd0;
                    rresp <= err;
                    state <= M_RD;
                end

                M_RD: begin
                    if (rready) begin
                        if (cnt == len) begin
                            last_was_wr <= 1'b0;
                            state       <= M_IDLE;
                        end else begin
                            cnt   <= cnt + 8'd1;
                            a     <= a + 32'd4;
                            rdata <= (err == 2'b00) ? mem[a[15:2] + 14'd1] : 32'd0;
                        end
                    end
                end

                M_WR: begin
                    if (wvalid) begin
                        if (err == 2'b00)
                            write_word(a, wdata, wstrb);
                        a <= a + 32'd4;
                        if (wlast) begin
                            bresp <= err;
                            state <= M_WR_RESP;
                        end
                    end
                end

                M_WBUF: begin
                    if (wvalid) begin
                        wbuf_data[wbuf_n] = wdata;
                        wbuf_strb[wbuf_n] = wstrb;
                        wbuf_n = wbuf_n + 1;
                        if (wlast)
                            state <= M_WAW;
                    end
                end

                M_WAW: begin
                    if (awvalid) begin
                        bid   <= awid;
                        bresp <= check_req(awaddr, awsize, awburst);
                        if (check_req(awaddr, awsize, awburst) == 2'b00)
                            for (k = 0; k < wbuf_n; k = k + 1)
                                write_word({awaddr[31:2], 2'b00} + 4 * k,
                                           wbuf_data[k], wbuf_strb[k]);
                        state <= M_WR_RESP;
                    end
                end

                M_WR_RESP: begin
                    if (bready) begin
                        last_was_wr <= 1'b1;
                        state       <= M_IDLE;
                    end
                end

                default: state <= M_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
