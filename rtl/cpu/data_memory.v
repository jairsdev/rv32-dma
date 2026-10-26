`timescale 1ns/1ps
module data_memory (
    input             clk,
    input             rst_n,
    input             we,
    input      [31:0] wdata,
    input      [5:0]  addr,
    output [31:0] rdata
);
    integer i;
    reg [31:0] mem [0:63];  // 64 words of 32 bits

    always @(posedge clk) begin
        if (!rst_n) begin
            // reset memory to zero
            for (i = 0; i < 64; i = i + 1) begin
                mem[i] <= 32'b0;
            end
        end
        else if (we) begin
            mem[addr] <= wdata;
        end
    end

    assign rdata = mem[addr];
endmodule
