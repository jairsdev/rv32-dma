module ALU (a, b, ALUControl, result, branch_taken);
  input  wire [31:0] a, b;
  input  wire [3:0]  ALUControl;
  output reg  [31:0] result;
  output reg         branch_taken;

  // Codificacao alinhada ao RISC-V: tipo R usa {funct7[5], funct3}
  localparam ADD  = 4'b0000; // a + b
  localparam SLL  = 4'b0001; // a << b   deslocamento lógico à esquerda
  localparam SLT  = 4'b0010; // a <  b   (com sinal)
  localparam SLTU = 4'b0011; // a <  b   (sem sinal)
  localparam XOR  = 4'b0100; // a ^ b
  localparam SRL  = 4'b0101; // a >> b   deslocamento lógico à direita
  localparam OR   = 4'b0110; // a | b
  localparam AND  = 4'b0111; // a & b
  localparam SUB  = 4'b1000; // a - b
  localparam BEQ  = 4'b1001; // a == b
  localparam BNE  = 4'b1010; // a != b
  localparam BGE  = 4'b1011; // a >= b   (com sinal)
  localparam BLT  = 4'b1100; // a <  b   (com sinal)
  localparam SRA  = 4'b1101; // a >>> b  deslocamento aritmético à direita
  localparam BLTU = 4'b1110; // a <  b   (sem sinal)
  localparam BGEU = 4'b1111; // a >= b   (sem sinal)

  wire [4:0] shamt = b[4:0];

  always @(*) begin
    branch_taken = 1'b0;
    case (ALUControl)
      ADD:     result = a + b;
      SUB:     result = a - b;
      AND:     result = a & b;
      OR:      result = a | b;
      XOR:     result = a ^ b;
      SLL:     result = a << shamt;
      SRL:     result = a >> shamt;
      SRA:     result = $signed(a) >>> shamt;
      SLT:     result = {31'b0, ($signed(a) <  $signed(b))};
      SLTU:    result = {31'b0, (a <  b)};
      BEQ:     begin result = {31'b0, (a == b)};                  branch_taken = result[0]; end
      BNE:     begin result = {31'b0, (a != b)};                  branch_taken = result[0]; end
      BLT:     begin result = {31'b0, ($signed(a) <  $signed(b))}; branch_taken = result[0]; end
      BGE:     begin result = {31'b0, ($signed(a) >= $signed(b))}; branch_taken = result[0]; end
      BLTU:    begin result = {31'b0, (a <  b)};                  branch_taken = result[0]; end
      BGEU:    begin result = {31'b0, (a >= b)};                  branch_taken = result[0]; end
      default: result = 32'b0;
    endcase
  end

endmodule
