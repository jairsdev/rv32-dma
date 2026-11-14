# Simulacao e verificacao do DMA (MAS secoes 16 e 17).
#
#   make lint      compila o DMA nas 6 configuracoes (T x PINGPONG), -Wall,
#                  com assercoes, e em Verilog-2005 puro sem assercoes
#   make selftest  autoteste do axi_checker
#   make tb_regs   TB-REGS
#   make tb_rd     TB-RD  (T = 2, 4, 8; MAX_BURST = 16, 1; com e sem stall)
#   make tb_wr     TB-WR  (T = 2, 4, 8; MAX_BURST = 16, 2; stall; W antes de AW)
#   make tb_dma    TB-DMA, caso 6x5x7 (T e PP: make tb_dma T=8 PP=0)
#   make unit      selftest + tb_regs + tb_rd + tb_wr
#   make regress   matriz 16.3 (168 execucoes) + testes 16.4 + criterio 16.5
#   make wave      forma de onda de uma operacao completa em build/wave_dma.vcd
#   make clean

IVERILOG := iverilog -g2012 -Wall -DDMA_ASSERT -I rtl/common
VVP      := vvp -n
BUILD    := build
PYTHON   := python3

T  ?= 4
PP ?= 1

RTL := $(shell cat rtl/dma/dma.f)
TB_COMMON := tb/common/axi_checker.v tb/common/axi_rand_stall.v \
             tb/common/axi_master_bfm.v tb/models/axi_mem_model.v

# Filtra os avisos de timescale dos arquivos sem `timescale (nenhum aqui) e
# falha se sobrar qualquer outra mensagem do compilador
CHECK_CLEAN = 2>&1 | grep -v timescale | tee /dev/stderr | (! grep -q .)

.PHONY: all lint selftest tb_regs tb_rd tb_wr tb_dma unit regress wave clean

all: lint unit tb_dma

$(BUILD):
	mkdir -p $(BUILD)

lint: | $(BUILD)
	@for t in 2 4 8; do for pp in 0 1; do \
	  echo "lint T=$$t PP=$$pp"; \
	  $(IVERILOG) -s dma -P dma.ARRAY_SIZE=$$t -P dma.PINGPONG=$$pp \
	    -o $(BUILD)/lint.vvp $(RTL) $(CHECK_CLEAN) || exit 1; \
	done; done
	@echo "lint Verilog-2005 sem assercoes"
	@iverilog -g2005 -Wall -I rtl/common -s dma -o $(BUILD)/lint05.vvp $(RTL) $(CHECK_CLEAN)
	@echo "LINT: PASS"

selftest: | $(BUILD)
	$(IVERILOG) -o $(BUILD)/selftest.vvp tb/unit_dma/tb_axi_checker_selftest.v tb/common/axi_checker.v
	$(VVP) $(BUILD)/selftest.vvp | grep -E "^ok|FALHA|PASS|FAIL"

tb_regs: | $(BUILD)
	@for t in 2 4 8; do for pp in 0 1; do \
	  $(IVERILOG) -P tb_dma_regs.ARRAY_SIZE=$$t -P tb_dma_regs.PINGPONG=$$pp \
	    -o $(BUILD)/tb_regs.vvp tb/unit_dma/tb_dma_regs.v $(TB_COMMON) $(RTL) || exit 1; \
	  $(VVP) $(BUILD)/tb_regs.vvp | grep -E "PASS|FAIL|FALHA|VIOLACAO"; \
	done; done

tb_rd: | $(BUILD)
	@for t in 2 4 8; do for mb in 16 1; do \
	  $(IVERILOG) -P tb_dma_rd_engine.ARRAY_SIZE=$$t -P tb_dma_rd_engine.MAX_BURST=$$mb \
	    -o $(BUILD)/tb_rd.vvp tb/unit_dma/tb_dma_rd_engine.v $(TB_COMMON) $(RTL) || exit 1; \
	  for st in "" "+STALL +SEED=7" "+STALL +SEED=21"; do \
	    $(VVP) $(BUILD)/tb_rd.vvp $$st | grep -E "PASS|FAIL|FALHA|VIOLACAO"; \
	  done; \
	done; done

tb_wr: | $(BUILD)
	@for t in 2 4 8; do for mb in 16 2; do \
	  $(IVERILOG) -P tb_dma_wr_engine.ARRAY_SIZE=$$t -P tb_dma_wr_engine.MAX_BURST=$$mb \
	    -o $(BUILD)/tb_wr.vvp tb/unit_dma/tb_dma_wr_engine.v $(TB_COMMON) $(RTL) || exit 1; \
	  for st in "" "+STALL +SEED=3" "+WFIRST" "+WFIRST +STALL +SEED=11"; do \
	    $(VVP) $(BUILD)/tb_wr.vvp $$st | grep -E "PASS|FAIL|FALHA|VIOLACAO"; \
	  done; \
	done; done

$(BUILD)/vec/smoke/c_expected.hex: model/golden.py | $(BUILD)
	$(PYTHON) model/golden.py --case 3 --seed 1 --out-dir $(BUILD)/vec/smoke > /dev/null

tb_dma: $(BUILD)/vec/smoke/c_expected.hex
	$(IVERILOG) -P tb_dma.ARRAY_SIZE=$(T) -P tb_dma.PINGPONG=$(PP) -o $(BUILD)/tb_dma.vvp \
	  tb/unit_dma/tb_dma.v $(TB_COMMON) tb/models/accel_model.v $(RTL)
	$(VVP) $(BUILD)/tb_dma.vvp +DMEM=$(BUILD)/vec/smoke/dmem.hex \
	  +CEXP=$(BUILD)/vec/smoke/c_expected.hex +M=6 +K=5 +N=7 | grep -E "RESULT|PASS|FAIL|FALHA"

unit: selftest tb_regs tb_rd tb_wr

regress: | $(BUILD)
	$(PYTHON) scripts/run_dma_regress.py

wave: $(BUILD)/vec/smoke/c_expected.hex
	$(IVERILOG) -P tb_dma.ARRAY_SIZE=$(T) -P tb_dma.PINGPONG=$(PP) -o $(BUILD)/tb_dma.vvp \
	  tb/unit_dma/tb_dma.v $(TB_COMMON) tb/models/accel_model.v $(RTL)
	$(VVP) $(BUILD)/tb_dma.vvp +DMEM=$(BUILD)/vec/smoke/dmem.hex \
	  +CEXP=$(BUILD)/vec/smoke/c_expected.hex +M=6 +K=5 +N=7 \
	  +VCD=$(BUILD)/wave_dma.vcd | grep -E "PASS|FAIL"
	@echo "Forma de onda: $(BUILD)/wave_dma.vcd (abrir com gtkwave)"

clean:
	rm -rf $(BUILD)
