`timescale 1ns/1ps
module instruction_memory #(
    parameter MEM_SIZE = 256
)(
    input  wire [31:0] addr,
    output reg  [31:0] data
);
    reg [31:0] mem [0:MEM_SIZE-1];

    initial begin
        $readmemh("instructions/instruction_control.hex", mem);
    end

    always @(*) begin
        data = mem[addr[9:2]];  // Assuming word-aligned addresses
    end
endmodule
