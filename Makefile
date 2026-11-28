IVERILOG := iverilog -g2012 -Wall -DDMA_ASSERT -I rtl/common
VVP      := vvp -n
XRUN_ACC := xrun -q -sv
XRUN     := $(XRUN_ACC) -define DMA_ASSERT -incdir rtl/common
BUILD    := build
PYTHON   := python3

# simulador dos alvos tb_mem, tb_accel, tb_dma, wave e regress: icarus ou xcelium
SIM ?= icarus
# DMEM dos alvos tb_rd, tb_wr, tb_dma, wave e regress: ctrl (o axi_mem_ctrl de
# rtl/top) ou model (a memoria comportamental tb/models/axi_mem_model.v)
MEM ?= ctrl
T   ?= 4
PP  ?= 1

RTL      := $(shell cat rtl/dma/dma.f)
ACCEL    := rtl/accel/accel.v rtl/accel/pe.v
# controlador da DMEM: os nossos arquivos vem antes dos copiados, que nao tem
# `timescale e herdam o deles
MEM_CTRL := $(shell cat rtl/top/axi_mem_ctrl.f)
MEM_MODEL := tb/models/axi_mem_model.v
TB_AXI    := tb/common/axi_checker.v tb/common/axi_rand_stall.v tb/common/axi_master_bfm.v
TB_COMMON := $(TB_AXI) $(MEM_MODEL)

ifeq ($(MEM),model)
  MEM_SRC    := $(MEM_MODEL)
  MEM_DEF_IV :=
  MEM_DEF_XR :=
else ifeq ($(MEM),ctrl)
  MEM_SRC    := $(MEM_CTRL)
  MEM_DEF_IV := -DMEM_CTRL
  MEM_DEF_XR := -define MEM_CTRL
else
  $(error MEM tem de ser ctrl ou model)
endif

# Joga fora os avisos de timescale e falha se sobrar qualquer outra mensagem
CHECK_CLEAN = 2>&1 | grep -v timescale | tee /dev/stderr | (! grep -q .)
# O mesmo para a compilacao dos TBs, mas mostrando as mensagens na saida
# normal: o tee /dev/stderr trunca o log quando a saida do make vai para arquivo
COMPILE_CLEAN = 2>&1 | grep -v timescale | (! grep .)

SMOKE      := $(BUILD)/vec/smoke
SMOKE_ARGS := +DMEM=$(SMOKE)/dmem.hex +CEXP=$(SMOKE)/c_expected.hex +M=6 +K=5 +N=7
TB_DMA_SRC := tb/unit_dma/tb_dma.v $(TB_AXI) $(ACCEL) $(RTL) $(MEM_SRC)

.PHONY: all lint selftest tb_regs tb_rd tb_wr tb_mem tb_accel tb_dma unit regress wave fw tb_fw clean

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
	@echo "TB-RD com MEM=$(MEM)"
	@for t in 2 4 8; do for mb in 16 1; do \
	  $(IVERILOG) $(MEM_DEF_IV) -P tb_dma_rd_engine.ARRAY_SIZE=$$t -P tb_dma_rd_engine.MAX_BURST=$$mb \
	    -o $(BUILD)/tb_rd.vvp tb/unit_dma/tb_dma_rd_engine.v $(TB_AXI) $(RTL) $(MEM_SRC) $(COMPILE_CLEAN) || exit 1; \
	  for st in "" "+STALL +SEED=7" "+STALL +SEED=21"; do \
	    $(VVP) $(BUILD)/tb_rd.vvp $$st | grep -E "PASS|FAIL|FALHA|VIOLACAO"; \
	  done; \
	done; done

# Os modos +WFIRST (W inteiro antes do AW) dependem do w_first do axi_mem_model,
# entao rodam sempre com ele; os outros usam a DMEM escolhida em MEM
tb_wr: | $(BUILD)
	@echo "TB-WR com MEM=$(MEM) (WFIRST sempre com o axi_mem_model)"
	@for t in 2 4 8; do for mb in 16 2; do \
	  $(IVERILOG) $(MEM_DEF_IV) -P tb_dma_wr_engine.ARRAY_SIZE=$$t -P tb_dma_wr_engine.MAX_BURST=$$mb \
	    -o $(BUILD)/tb_wr.vvp tb/unit_dma/tb_dma_wr_engine.v $(TB_AXI) $(RTL) $(MEM_SRC) $(COMPILE_CLEAN) || exit 1; \
	  $(IVERILOG) -P tb_dma_wr_engine.ARRAY_SIZE=$$t -P tb_dma_wr_engine.MAX_BURST=$$mb \
	    -o $(BUILD)/tb_wr_model.vvp tb/unit_dma/tb_dma_wr_engine.v $(TB_AXI) $(RTL) $(MEM_MODEL) $(COMPILE_CLEAN) || exit 1; \
	  for st in "" "+STALL +SEED=3"; do \
	    $(VVP) $(BUILD)/tb_wr.vvp $$st | grep -E "PASS|FAIL|FALHA|VIOLACAO"; \
	  done; \
	  for st in "+WFIRST" "+WFIRST +STALL +SEED=11"; do \
	    $(VVP) $(BUILD)/tb_wr_model.vvp $$st | grep -E "PASS|FAIL|FALHA|VIOLACAO"; \
	  done; \
	done; done

# TB-MEM: axi_mem_ctrl sozinho, sem backpressure (com as medicoes de L e W_OV)
# e com backpressure aleatoria em 3 sementes
TB_MEM_SRC := tb/unit_mem/tb_axi_mem_ctrl.v tb/common/axi_checker.v tb/common/axi_rand_stall.v $(MEM_CTRL)

tb_mem: | $(BUILD)
ifeq ($(SIM),xcelium)
	@for st in "" "+STALL +SEED=1" "+STALL +SEED=2" "+STALL +SEED=3"; do \
	  $(XRUN) -top tb_axi_mem_ctrl -xmlibdirname $(BUILD)/xcelium_mem -l $(BUILD)/tb_mem.log \
	    $(TB_MEM_SRC) $$st > /dev/null; \
	  grep -hE "MEDIDA|TB_MEM|FALHA|VIOLACAO|\*[EFW]," $(BUILD)/tb_mem.log; \
	done
else
	@$(IVERILOG) -o $(BUILD)/tb_mem.vvp $(TB_MEM_SRC) $(COMPILE_CLEAN)
	@for st in "" "+STALL +SEED=1" "+STALL +SEED=2" "+STALL +SEED=3"; do \
	  $(VVP) $(BUILD)/tb_mem.vvp $$st | grep -E "MEDIDA|TB_MEM|FALHA|VIOLACAO"; \
	done
endif

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

# TB-DMA com o caso 6x5x7 (mude a configuracao com T=... PP=... MEM=...)
tb_dma: $(SMOKE)/c_expected.hex
ifeq ($(SIM),xcelium)
	$(XRUN) $(MEM_DEF_XR) -top tb_dma -defparam tb_dma.ARRAY_SIZE=$(T) -defparam tb_dma.PINGPONG=$(PP) \
	  -xmlibdirname $(BUILD)/xcelium_dma -l $(BUILD)/tb_dma.log $(TB_DMA_SRC) $(SMOKE_ARGS) > /dev/null
	@grep -E "RESULT|PASS|FAIL|FALHA|\*[EFW]," $(BUILD)/tb_dma.log
else
	$(IVERILOG) $(MEM_DEF_IV) -P tb_dma.ARRAY_SIZE=$(T) -P tb_dma.PINGPONG=$(PP) -o $(BUILD)/tb_dma.vvp $(TB_DMA_SRC) $(COMPILE_CLEAN)
	$(VVP) $(BUILD)/tb_dma.vvp $(SMOKE_ARGS) | grep -E "RESULT|PASS|FAIL|FALHA"
endif

unit: selftest tb_regs tb_rd tb_wr tb_mem

regress: | $(BUILD)
	$(PYTHON) scripts/run_dma_regress.py --sim $(SIM) --mem $(MEM)

# Forma de onda de uma operacao completa: SHM para o SimVision no Xcelium,
# VCD para o GTKWave no Icarus
wave: $(SMOKE)/c_expected.hex
ifeq ($(SIM),xcelium)
	@printf 'database -open $(BUILD)/wave_dma -shm -default\nprobe -create tb_dma -depth all -all\nrun\nexit\n' > $(BUILD)/wave.tcl
	$(XRUN) $(MEM_DEF_XR) -access +r -top tb_dma -defparam tb_dma.ARRAY_SIZE=$(T) -defparam tb_dma.PINGPONG=$(PP) \
	  -xmlibdirname $(BUILD)/xcelium_wave -l $(BUILD)/wave.log -input $(BUILD)/wave.tcl \
	  $(TB_DMA_SRC) $(SMOKE_ARGS) > /dev/null
	@grep -E "PASS|FAIL" $(BUILD)/wave.log
	@echo "Forma de onda: $(BUILD)/wave_dma.shm (abrir com: simvision $(BUILD)/wave_dma.shm)"
else
	$(IVERILOG) $(MEM_DEF_IV) -P tb_dma.ARRAY_SIZE=$(T) -P tb_dma.PINGPONG=$(PP) -o $(BUILD)/tb_dma.vvp $(TB_DMA_SRC) $(COMPILE_CLEAN)
	$(VVP) $(BUILD)/tb_dma.vvp $(SMOKE_ARGS) +VCD=$(BUILD)/wave_dma.vcd | grep -E "PASS|FAIL"
	@echo "Forma de onda: $(BUILD)/wave_dma.vcd (abrir com gtkwave)"
endif

# --------------------------------------------------------------------------
# Firmware (sw/) e TB-FW: o firmware rodando na CPU, com o DMA e a DMEM reais
# --------------------------------------------------------------------------
FW_DIR := $(BUILD)/fw
FW_HEX := $(FW_DIR)/firmware.hex
CASE6  := $(BUILD)/vec/case6

# A CPU multiciclo ainda so existe na branch processor-rv32i. Ate o merge, o
# TB-FW usa o rtl/cpu dessa branch, extraido para build/cpu_branch; depois do
# merge, rode com CPU_DIR=rtl/cpu (ou mude o padrao aqui).
CPU_BRANCH ?= origin/processor-rv32i
CPU_DIR    ?= $(BUILD)/cpu_branch/rtl/cpu
CPU_SRC     = $(addprefix $(CPU_DIR)/,rv32i_cpu.v controller.v alu.v alu_controller.v \
                imm_gen.v reg_bank.v imem.v)

TB_FW_SRC = sw/mailbox_pkg.sv tb/unit_fw/tb_fw.v $(TB_AXI) $(ACCEL) $(RTL) $(MEM_SRC) $(CPU_SRC)

# Monta o firmware e gera o mailbox.h e o mailbox_pkg.sv a partir do mailbox.inc
fw: $(FW_HEX)

$(FW_HEX): sw/firmware.s sw/mailbox.inc sw/rvasm.py | $(BUILD)
	@mkdir -p $(FW_DIR)
	$(PYTHON) sw/rvasm.py sw/firmware.s -o $@ -l $(FW_DIR)/firmware.lst
	$(PYTHON) sw/rvasm.py --defs c  sw/mailbox.inc -o sw/mailbox.h
	$(PYTHON) sw/rvasm.py --defs sv sw/mailbox.inc -o sw/mailbox_pkg.sv
	@echo "firmware: $$(wc -l < $@) instrucoes em $@ (listagem em $(FW_DIR)/firmware.lst)"

$(BUILD)/cpu_branch/rtl/cpu/rv32i_cpu.v: | $(BUILD)
	@mkdir -p $(BUILD)/cpu_branch
	git archive $(CPU_BRANCH) rtl/cpu | tar -x -C $(BUILD)/cpu_branch

$(CASE6)/c_expected.hex: model/golden.py | $(BUILD)
	$(PYTHON) model/golden.py --case 6 --seed 1 --out-dir $(CASE6) > /dev/null

# TB-FW nas 6 configuracoes, sem e com backpressure no M1
tb_fw: $(FW_HEX) $(SMOKE)/c_expected.hex $(CASE6)/c_expected.hex $(CPU_DIR)/rv32i_cpu.v
	@echo "TB-FW com MEM=$(MEM) e a CPU de $(CPU_DIR)"
ifeq ($(SIM),xcelium)
	@for t in 2 4 8; do for pp in 0 1; do for st in "" "+STALL +SEED=5"; do \
	  $(XRUN) $(MEM_DEF_XR) -top tb_fw -defparam tb_fw.ARRAY_SIZE=$$t -defparam tb_fw.PINGPONG=$$pp \
	    -xmlibdirname $(BUILD)/xcelium_fw -l $(BUILD)/tb_fw.log $(TB_FW_SRC) $$st > /dev/null; \
	  grep -hE "TB_FW|FALHA|SKIP|\*[EF]," $(BUILD)/tb_fw.log; \
	done; done; done
else
	@for t in 2 4 8; do for pp in 0 1; do \
	  $(IVERILOG) $(MEM_DEF_IV) -P tb_fw.ARRAY_SIZE=$$t -P tb_fw.PINGPONG=$$pp \
	    -o $(BUILD)/tb_fw.vvp $(TB_FW_SRC) $(COMPILE_CLEAN) || exit 1; \
	  for st in "" "+STALL +SEED=5"; do \
	    $(VVP) $(BUILD)/tb_fw.vvp $$st | grep -E "TB_FW|FALHA|SKIP"; \
	  done; \
	done; done
endif

clean:
	rm -rf $(BUILD)
