`timescale 1ns/1ps
module pc (
    input             clk,
    input             rst_n,  // rst_n ativo em nível baixo
    input      [31:0] a,    // próximo PC
    output reg [31:0] o     // PC atual
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            o <= 32'd0;
        else
            o <= a;
    end
endmodule
