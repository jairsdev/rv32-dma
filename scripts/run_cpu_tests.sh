#!/usr/bin/env bash
# Roda os testes da CPU no Cadence Xcelium (xrun).
#
#   scripts/run_cpu_tests.sh                   todos os testes da CPU
#   scripts/run_cpu_tests.sh tb_cpu tb_imem    so os testbenches indicados
#   WAVES=1 scripts/run_cpu_tests.sh ...       tambem grava as formas de onda (SHM)
#
# Cada programa de tb/unit_cpu/programs/ roda duas vezes no tb_cpu: com latencia
# minima nas portas e com latencia aleatoria (ILAT/DLAT).
# Logs e formas de onda: build/cpu/<teste>.log e build/cpu/<teste>.shm
# Abrir no SimVision:    SHM=build/cpu/<teste>.shm simvision -input scripts/simvision_cpu.tcl
set -u
RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$RAIZ/build/cpu"
mkdir -p "$BUILD"
cd "$RAIZ"

TBS="tb_alu tb_alu_controller tb_imm_gen tb_register_file tb_imem tb_cpu tb_cpu_irq"
[ $# -gt 0 ] && TBS="$*"
falhas=0

# roda <nome do teste> <modulo do testbench> [plusargs...]
roda() {
  local nome=$1 tb=$2
  shift 2
  local extra=()
  if [ "${WAVES:-0}" = 1 ]; then
    printf 'database -open waves -shm -into %s -default\nprobe -create %s -all -depth all -memories\nrun\nexit\n' \
      "$BUILD/$nome.shm" "$tb" > "$BUILD/$nome.tcl"
    extra=(-access +rwc -input "$BUILD/$nome.tcl")
  fi
  xrun -sv -nocopyright -xmlibdirname "$BUILD/xcelium.d" -l "$BUILD/$nome.log" \
       -top "$tb" rtl/cpu/*.v "tb/unit_cpu/$tb.v" "${extra[@]}" "$@" > /dev/null 2>&1

  local linha
  # tb_alu imprime "ALL TESTS PASSED" / "<n> erros"; os demais, PASSOU / FALHOU
  linha=$(grep -E "PASSOU|FALHOU|ALL TESTS PASSED|^[0-9]+ erros" "$BUILD/$nome.log" | grep -v '\$display' | tail -1)
  if echo "$linha" | grep -qE "PASSOU|ALL TESTS PASSED" && ! grep -qE '^(xrun|xmvlog|xmelab|xmsim): \*[EF],' "$BUILD/$nome.log"; then
    echo "  ok     $linha"
  else
    echo "  FALHA  ${linha:-$nome: sem resultado (veja build/cpu/$nome.log)}"
    falhas=$((falhas + 1))
  fi
}

for tb in $TBS; do
  if [ "$tb" = tb_cpu ]; then
    for regs in tb/unit_cpu/programs/*.regs; do
      prog=$(basename "$regs" .regs)
      roda "tb_cpu_$prog"     tb_cpu "+TEST=$prog" +ILAT=0 +DLAT=0
      roda "tb_cpu_${prog}_l" tb_cpu "+TEST=$prog" +ILAT=3 +DLAT=6 "+SEED=$((10#${prog%%_*}))"
    done
  else
    roda "$tb" "$tb"
  fi
done

echo "----"
if [ "$falhas" -eq 0 ]; then echo "Todos os testes PASSARAM"; else echo "$falhas teste(s) com FALHA"; fi
exit "$falhas"
