`timescale 1ns/1ps
// rtl: alu.v
module tb_alu;
reg  [31:0] a, b;
reg  [3:0]  op;
wire [31:0] result;
wire        branch_taken;

integer i, errors;

ALU dut (.a(a), .b(b), .ALUControl(op), .result(result), .branch_taken(branch_taken));

task check(input [3:0] o, input [31:0] x, input [31:0] y, input [31:0] exp,
           input exp_br, input [8*32-1:0] msg);
	begin
		op = o; a = x; b = y; #1;
		if (result !== exp || branch_taken !== exp_br) begin
			$display("FAIL: %0s a=%h b=%h got=%h/%b exp=%h/%b",
			         msg, x, y, result, branch_taken, exp, exp_br);
			errors = errors + 1;
		end
	end
endtask

initial begin
	$dumpfile("tb_alu.vcd");
	$dumpvars(0, tb_alu);
	errors = 0;

	// 1. aritmeticas
	check(4'b0000, 32'd5, 32'd7, 32'd12, 0, "ADD");
	check(4'b0000, 32'hFFFFFFFF, 32'd1, 32'd0, 0, "ADD overflow");
	check(4'b1000, 32'd7, 32'd5, 32'd2, 0, "SUB");
	check(4'b1000, 32'd0, 32'd1, 32'hFFFFFFFF, 0, "SUB underflow");

	// 2. logicas
	check(4'b0111, 32'hF0F0F0F0, 32'hFF00FF00, 32'hF000F000, 0, "AND");
	check(4'b0110, 32'hF0F0F0F0, 32'hFF00FF00, 32'hFFF0FFF0, 0, "OR");
	check(4'b0100, 32'hF0F0F0F0, 32'hFF00FF00, 32'h0FF00FF0, 0, "XOR");

	// 3. deslocamentos (so b[4:0] conta)
	check(4'b0001, 32'h80000001, 32'd0,  32'h80000001, 0, "SLL 0");
	check(4'b0001, 32'h80000001, 32'd1,  32'h00000002, 0, "SLL 1");
	check(4'b0001, 32'h00000001, 32'd31, 32'h80000000, 0, "SLL 31");
	check(4'b0001, 32'h00000001, 32'hFFFFFFE1, 32'h00000002, 0, "SLL b[31:5]");
	check(4'b0101, 32'h80000000, 32'd1,  32'h40000000, 0, "SRL 1");
	check(4'b0101, 32'h80000000, 32'd31, 32'h00000001, 0, "SRL 31");
	check(4'b1101, 32'h80000000, 32'd1,  32'hC0000000, 0, "SRA 1");
	check(4'b1101, 32'h80000000, 32'd31, 32'hFFFFFFFF, 0, "SRA 31");
	check(4'b1101, 32'h40000000, 32'd1,  32'h20000000, 0, "SRA positivo");
	check(4'b1101, 32'h80000000, 32'h00000020, 32'h80000000, 0, "SRA b[31:5]");

	// 4. comparacoes
	check(4'b0010, 32'hFFFFFFFF, 32'd1, 32'd1, 0, "SLT -1<1");
	check(4'b0011, 32'hFFFFFFFF, 32'd1, 32'd0, 0, "SLTU -1<1");
	check(4'b0010, 32'd3, 32'd3, 32'd0, 0, "SLT igual");
	check(4'b0011, 32'd2, 32'd3, 32'd1, 0, "SLTU 2<3");

	// 5. branches (verdadeiro / falso)
	check(4'b1001, 32'd9, 32'd9, 32'd1, 1, "BEQ T");
	check(4'b1001, 32'd9, 32'd8, 32'd0, 0, "BEQ F");
	check(4'b1010, 32'd9, 32'd8, 32'd1, 1, "BNE T");
	check(4'b1010, 32'd9, 32'd9, 32'd0, 0, "BNE F");
	check(4'b1100, 32'hFFFFFFFF, 32'd1, 32'd1, 1, "BLT T");
	check(4'b1100, 32'd1, 32'hFFFFFFFF, 32'd0, 0, "BLT F");
	check(4'b1011, 32'd1, 32'hFFFFFFFF, 32'd1, 1, "BGE T");
	check(4'b1011, 32'd5, 32'd5, 32'd1, 1, "BGE igual");
	check(4'b1011, 32'hFFFFFFFF, 32'd1, 32'd0, 0, "BGE F");
	check(4'b1110, 32'd1, 32'hFFFFFFFF, 32'd1, 1, "BLTU T");
	check(4'b1110, 32'hFFFFFFFF, 32'd1, 32'd0, 0, "BLTU F");
	check(4'b1111, 32'hFFFFFFFF, 32'd1, 32'd1, 1, "BGEU T");
	check(4'b1111, 32'd5, 32'd5, 32'd1, 1, "BGEU igual");
	check(4'b1111, 32'd1, 32'hFFFFFFFF, 32'd0, 0, "BGEU F");

	// 6. branch_taken = 0 em ops que nao sao branch, mesmo com result[0]=1
	a = 32'hFFFFFFFF; b = 32'd1;
	for (i = 0; i < 16; i = i + 1) begin
		op = i; #1;
		if (i != 4'b1001 && i != 4'b1010 && i != 4'b1011 && i != 4'b1100 &&
		    i != 4'b1110 && i != 4'b1111 && branch_taken !== 1'b0) begin
			$display("FAIL: branch_taken=1 em op=%b", op);
			errors = errors + 1;
		end
	end

	if (errors == 0) $display("ALL TESTS PASSED");
	else             $display("%0d erros", errors);
	$finish;
end
endmodule
