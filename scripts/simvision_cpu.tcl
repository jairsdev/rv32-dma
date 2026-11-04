# Abre as formas de onda da CPU no SimVision com os sinais agrupados.
#
#   WAVES=1 scripts/run_cpu_tests.sh tb_cpu_irq
#   SHM=build/cpu/tb_cpu_irq.shm TOP=tb_cpu_irq simvision -input scripts/simvision_cpu.tcl
#
# TOP e o modulo do testbench (tb_cpu ou tb_cpu_irq; padrao: tb_cpu_irq).
# Com CURSOR=<tempo em ns>, posiciona o cursor.

if {[info exists env(SHM)]} { set shm $env(SHM) } else { set shm build/cpu/tb_cpu_irq.shm }
if {[info exists env(TOP)]} { set tb  $env(TOP) } else { set tb  tb_cpu_irq }
database require waves -search [list $shm]

set top waves::$tb
set cpu $top.dut

window new WaveWindow -name "CPU RV32I"
waveform using "CPU RV32I"

proc grupo {nome sinais} {
  group new -name $nome -overlay 0
  group using $nome
  group clear 0 end
  foreach s $sinais { group insert $s }
  waveform add -groups [list $nome]
}

grupo "Clock e reset" [list $top.clk $top.rst_n]
grupo "FSM"           [list $cpu.u_controller.state $cpu.pc $cpu.ir $cpu.pc_we]
grupo "Porta I"       [list $cpu.i_valid $cpu.i_addr $cpu.i_ready $cpu.i_rdata]
grupo "Porta D"       [list $cpu.d_valid $cpu.d_addr $cpu.d_wstrb $cpu.d_wdata $cpu.d_ready $cpu.d_rdata]
grupo "Execucao"      [list $cpu.a $cpu.b $cpu.alu_result $cpu.alu_out $cpu.mdr $cpu.wb_data $cpu.reg_we]
grupo "Interrupcao"   [list $cpu.irq $cpu.halt]

# hexadecimal nos barramentos (os sinais de 1 bit nao aceitam radix)
foreach id [waveform find -name *] { catch {waveform format $id -radix %x} }

if {[info exists env(CURSOR)]} { cursor set -using TimeA -time $env(CURSOR)ns }
