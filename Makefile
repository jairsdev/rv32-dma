IVERILOG := iverilog -g2012 -Wall -DDMA_ASSERT -I rtl/common
VVP      := vvp -n
XRUN_ACC := xrun -q -sv
XRUN     := $(XRUN_ACC) -define DMA_ASSERT -incdir rtl/common
BUILD    := build
PYTHON   := python3

# simulador dos alvos tb_accel, tb_dma, wave e regress: icarus ou xcelium
SIM ?= icarus
T   ?= 4
PP  ?= 1

RTL      := $(shell cat rtl/dma/dma.f)
ACCEL    := rtl/accel/accel.v rtl/accel/pe.v
# controlador da DMEM: os nossos arquivos vem antes dos copiados, que nao tem
# `timescale e herdam o deles
MEM_CTRL := $(shell cat rtl/top/axi_mem_ctrl.f)
TB_COMMON := tb/common/axi_checker.v tb/common/axi_rand_stall.v \
             tb/common/axi_master_bfm.v tb/models/axi_mem_model.v

# Joga fora os avisos de timescale e falha se sobrar qualquer outra mensagem
CHECK_CLEAN = 2>&1 | grep -v timescale | tee /dev/stderr | (! grep -q .)

SMOKE      := $(BUILD)/vec/smoke
SMOKE_ARGS := +DMEM=$(SMOKE)/dmem.hex +CEXP=$(SMOKE)/c_expected.hex +M=6 +K=5 +N=7
TB_DMA_SRC := tb/unit_dma/tb_dma.v $(TB_COMMON) $(ACCEL) $(RTL)

.PHONY: all lint selftest tb_regs tb_rd tb_wr tb_accel tb_dma unit regress wave clean

all: lint unit tb_accel tb_dma

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
	@for id in 1 2; do \
	  echo "lint axi_mem_ctrl ID_W=$$id"; \
	  $(IVERILOG) -s axi_mem_ctrl -P axi_mem_ctrl.ID_W=$$id \
	    -o $(BUILD)/lint_mem.vvp $(MEM_CTRL) $(CHECK_CLEAN) || exit 1; \
	done
	@echo "lint axi_mem_ctrl Verilog-2005 sem assercoes"
	@iverilog -g2005 -Wall -I rtl/common -s axi_mem_ctrl -o $(BUILD)/lint_mem05.vvp $(MEM_CTRL) $(CHECK_CLEAN)
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

# TB-ACC nas 6 configuracoes (T = 2, 4, 8 x PINGPONG = 0, 1)
tb_accel: | $(BUILD)
ifeq ($(SIM),xcelium)
	@for t in 2 4 8; do for pp in 0 1; do \
	  $(XRUN_ACC) -top tb_accel -defparam tb_accel.ARRAY_SIZE=$$t -defparam tb_accel.PINGPONG=$$pp \
	    -xmlibdirname $(BUILD)/xcelium_accel -l $(BUILD)/tb_accel.log \
	    tb/unit_accel/tb_accel.v $(ACCEL) > /dev/null; \
	  grep -hE "TB_ACCEL T=.*(PASS|FAIL)|ERRO|\*[EFW]," $(BUILD)/tb_accel.log; \
	done; done
else
	@for t in 2 4 8; do for pp in 0 1; do \
	  $(IVERILOG) -P tb_accel.ARRAY_SIZE=$$t -P tb_accel.PINGPONG=$$pp \
	    -o $(BUILD)/tb_accel.vvp tb/unit_accel/tb_accel.v $(ACCEL) || exit 1; \
	  $(VVP) $(BUILD)/tb_accel.vvp | grep -E "TB_ACCEL T=.*(PASS|FAIL)|ERRO"; \
	done; done
endif

$(SMOKE)/c_expected.hex: model/golden.py | $(BUILD)
	$(PYTHON) model/golden.py --case 3 --seed 1 --out-dir $(SMOKE) > /dev/null

# TB-DMA com o caso 6x5x7 (mude a configuracao com T=... PP=...)
tb_dma: $(SMOKE)/c_expected.hex
ifeq ($(SIM),xcelium)
	$(XRUN) -top tb_dma -defparam tb_dma.ARRAY_SIZE=$(T) -defparam tb_dma.PINGPONG=$(PP) \
	  -xmlibdirname $(BUILD)/xcelium_dma -l $(BUILD)/tb_dma.log $(TB_DMA_SRC) $(SMOKE_ARGS) > /dev/null
	@grep -E "RESULT|PASS|FAIL|FALHA|\*[EFW]," $(BUILD)/tb_dma.log
else
	$(IVERILOG) -P tb_dma.ARRAY_SIZE=$(T) -P tb_dma.PINGPONG=$(PP) -o $(BUILD)/tb_dma.vvp $(TB_DMA_SRC)
	$(VVP) $(BUILD)/tb_dma.vvp $(SMOKE_ARGS) | grep -E "RESULT|PASS|FAIL|FALHA"
endif

unit: selftest tb_regs tb_rd tb_wr

regress: | $(BUILD)
	$(PYTHON) scripts/run_dma_regress.py --sim $(SIM)

# Forma de onda de uma operacao completa: SHM para o SimVision no Xcelium,
# VCD para o GTKWave no Icarus
wave: $(SMOKE)/c_expected.hex
ifeq ($(SIM),xcelium)
	@printf 'database -open $(BUILD)/wave_dma -shm -default\nprobe -create tb_dma -depth all -all\nrun\nexit\n' > $(BUILD)/wave.tcl
	$(XRUN) -access +r -top tb_dma -defparam tb_dma.ARRAY_SIZE=$(T) -defparam tb_dma.PINGPONG=$(PP) \
	  -xmlibdirname $(BUILD)/xcelium_wave -l $(BUILD)/wave.log -input $(BUILD)/wave.tcl \
	  $(TB_DMA_SRC) $(SMOKE_ARGS) > /dev/null
	@grep -E "PASS|FAIL" $(BUILD)/wave.log
	@echo "Forma de onda: $(BUILD)/wave_dma.shm (abrir com: simvision $(BUILD)/wave_dma.shm)"
else
	$(IVERILOG) -P tb_dma.ARRAY_SIZE=$(T) -P tb_dma.PINGPONG=$(PP) -o $(BUILD)/tb_dma.vvp $(TB_DMA_SRC)
	$(VVP) $(BUILD)/tb_dma.vvp $(SMOKE_ARGS) +VCD=$(BUILD)/wave_dma.vcd | grep -E "PASS|FAIL"
	@echo "Forma de onda: $(BUILD)/wave_dma.vcd (abrir com gtkwave)"
endif

clean:
	rm -rf $(BUILD)
