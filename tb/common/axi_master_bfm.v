`timescale 1ns/1ps
`default_nettype none

// BFM de master AXI4 (MAS 16.1): faz o papel da CPU nas Entregas 3 e 4.
// Tarefas (chamar por hierarquia, ex.: u_bfm.axi_write(...)):
//   axi_write(addr, data, resp)                  1 beat, WSTRB = 1111
//   axi_write_strb(addr, data, strb, resp)       1 beat, WSTRB escolhido
//   axi_write_burst(addr, len, size, resp)       len+1 beats (teste de SLVERR)
//   axi_read(addr, data, resp)                   1 beat
//   axi_read_burst(addr, len, size, resp)        len+1 beats; resp = OR dos RRESP
// AW e W sao emitidos juntos e cada um baixa no seu handshake.
module axi_master_bfm #(
    parameter ID_W = 2
)(
    input  wire            clk,
    input  wire            rst_n,

    output reg  [ID_W-1:0] awid,
    output reg  [31:0]     awaddr,
    output reg  [7:0]      awlen,
    output reg  [2:0]      awsize,
    output reg  [1:0]      awburst,
    output reg             awvalid,
    input  wire            awready,
    output reg  [31:0]     wdata,
    output reg  [3:0]      wstrb,
    output reg             wlast,
    output reg             wvalid,
    input  wire            wready,
    input  wire [ID_W-1:0] bid,
    input  wire [1:0]      bresp,
    input  wire            bvalid,
    output reg             bready,
    output reg  [ID_W-1:0] arid,
    output reg  [31:0]     araddr,
    output reg  [7:0]      arlen,
    output reg  [2:0]      arsize,
    output reg  [1:0]      arburst,
    output reg             arvalid,
    input  wire            arready,
    input  wire [ID_W-1:0] rid,
    input  wire [31:0]     rdata,
    input  wire [1:0]      rresp,
    input  wire            rlast,
    input  wire            rvalid,
    output reg             rready
);

    initial begin
        awid = 0; awaddr = 0; awlen = 0; awsize = 3'b010; awburst = 2'b01; awvalid = 0;
        wdata = 0; wstrb = 4'hF; wlast = 0; wvalid = 0; bready = 0;
        arid = 0; araddr = 0; arlen = 0; arsize = 3'b010; arburst = 2'b01; arvalid = 0;
        rready = 0;
    end

    // Convencao de tempo: o BFM dirige na borda de subida (<=) e amostra os
    // handshakes na borda de descida, quando os sinais do ciclo estao estaveis.

    // Escrita generica: len+1 beats, dado = base + indice do beat
    task axi_write_gen;
        input  [31:0] addr;
        input  [31:0] data;
        input  [3:0]  strb;
        input  [7:0]  len;
        input  [2:0]  size;
        output [1:0]  resp;
        integer beat;
        reg     aw_done, w_done, aw_hs, w_hs, b_hs;
        begin
            @(posedge clk);
            awaddr  <= addr;
            awlen   <= len;
            awsize  <= size;
            awburst <= 2'b01;
            awvalid <= 1'b1;
            wdata   <= data;
            wstrb   <= strb;
            wlast   <= (len == 8'd0);
            wvalid  <= 1'b1;
            aw_done = 1'b0;
            w_done  = 1'b0;
            beat    = 0;
            // AW e W em paralelo, cada um baixa no seu handshake
            while (!aw_done || !w_done) begin
                @(negedge clk);
                aw_hs = awvalid & awready;
                w_hs  = wvalid & wready;
                @(posedge clk);
                if (aw_hs) begin
                    awvalid <= 1'b0;
                    aw_done = 1'b1;
                end
                if (w_hs) begin
                    if (beat == len) begin
                        wvalid <= 1'b0;
                        wlast  <= 1'b0;
                        w_done = 1'b1;
                    end else begin
                        beat = beat + 1;
                        wdata <= data + beat;
                        wlast <= (beat == len);
                    end
                end
            end
            bready <= 1'b1;
            b_hs = 1'b0;
            while (!b_hs) begin
                @(negedge clk);
                b_hs = bvalid;
                if (b_hs) resp = bresp;
                @(posedge clk);
            end
            bready <= 1'b0;
        end
    endtask

    task axi_write;
        input  [31:0] addr;
        input  [31:0] data;
        output [1:0]  resp;
        begin
            axi_write_gen(addr, data, 4'hF, 8'd0, 3'b010, resp);
        end
    endtask

    task axi_write_strb;
        input  [31:0] addr;
        input  [31:0] data;
        input  [3:0]  strb;
        output [1:0]  resp;
        begin
            axi_write_gen(addr, data, strb, 8'd0, 3'b010, resp);
        end
    endtask

    task axi_write_burst;
        input  [31:0] addr;
        input  [7:0]  len;
        input  [2:0]  size;
        output [1:0]  resp;
        begin
            axi_write_gen(addr, 32'hA5A5_0000, 4'hF, len, size, resp);
        end
    endtask

    // Leitura generica: devolve o ultimo dado e o OR dos RRESP
    task axi_read_gen;
        input  [31:0] addr;
        input  [7:0]  len;
        input  [2:0]  size;
        output [31:0] data;
        output [1:0]  resp;
        output integer nbeats;
        reg done, ar_hs;
        begin
            @(posedge clk);
            araddr  <= addr;
            arlen   <= len;
            arsize  <= size;
            arburst <= 2'b01;
            arvalid <= 1'b1;
            ar_hs = 1'b0;
            while (!ar_hs) begin
                @(negedge clk);
                ar_hs = arready;
                @(posedge clk);
            end
            arvalid <= 1'b0;
            rready  <= 1'b1;
            resp    = 2'b00;
            nbeats  = 0;
            done    = 1'b0;
            while (!done) begin
                @(negedge clk);
                if (rvalid) begin
                    data   = rdata;
                    resp   = resp | rresp;
                    nbeats = nbeats + 1;
                    if (rlast) done = 1'b1;
                end
                @(posedge clk);
            end
            rready <= 1'b0;
        end
    endtask

    task axi_read;
        input  [31:0] addr;
        output [31:0] data;
        output [1:0]  resp;
        integer n;
        begin
            axi_read_gen(addr, 8'd0, 3'b010, data, resp, n);
        end
    endtask

    task axi_read_burst;
        input  [31:0] addr;
        input  [7:0]  len;
        input  [2:0]  size;
        output [1:0]  resp;
        output integer nbeats;
        reg [31:0] d;
        begin
            axi_read_gen(addr, len, size, d, resp, nbeats);
        end
    endtask

endmodule

`default_nettype wire
