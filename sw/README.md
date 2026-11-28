# Firmware e caixa de correio

O mesmo firmware serve para todos os testes do top e do UVM. Ele não tem a tarefa gravada no código: lê cada job numa **caixa de correio** na DMEM, programa o DMA, espera o fim e devolve o resultado na própria caixa. O UVM (ou o testbench) só escreve A, B e a caixa por backdoor, então não é preciso recompilar o firmware entre um teste e outro.

| Arquivo | Conteúdo |
|---|---|
| [`firmware.s`](firmware.s) | O firmware, em Assembly RV32I (119 instruções) |
| [`mailbox.inc`](mailbox.inc) | Formato da caixa: **fonte única** dos offsets, flags e estados |
| [`mailbox.h`](mailbox.h) | Os mesmos valores em C, para o golden em C (DPI). Gerado, não edite |
| [`mailbox_pkg.sv`](mailbox_pkg.sv) | Os mesmos valores num pacote SystemVerilog, para o UVM. Gerado, não edite |
| [`rvasm.py`](rvasm.py) | Montador RV32I em Python 3, sem dependências |

## Como montar e testar

```bash
make fw                       # build/fw/firmware.hex (+ firmware.lst) e regenera mailbox.h / mailbox_pkg.sv
make tb_fw                    # TB-FW nas 6 configurações (T × PINGPONG), sem e com backpressure
make tb_fw SIM=xcelium MEM=model
```

O fluxo não depende de toolchain RISC-V, que não está instalada no WSL da CEPEDI, e o firmware cabe em Assembly. O `rvasm.py` monta as 37 instruções de usuário do RV32I, mais `fence`, `ecall`, `ebreak` e `wfi`, e as pseudo-instruções comuns (`li`, `la`, `mv`, `j`, `beqz`...). Ele foi conferido contra os 13 programas de `tb/unit_cpu/programs/` da branch `processor-rv32i`: os 13 `.hex` saem idênticos, bit a bit.

O firmware não tem `.data`, `.bss` nem pilha. Por isso não precisa de linker script, e na DMEM ele só toca na caixa. A, B e C ficam só com o DMA.

## Caixa de correio

Base `0x1000_0000` (início da DMEM, na região "dados do firmware" do README §3.1), 256 bytes. Todos os campos são palavras de 32 bits.

### Entrada: o UVM escreve, o firmware só lê

| Offset | Nome | Conteúdo |
|---|---|---|
| `0x00` | `MB_DOORBELL` | Número do job. O firmware começa quando ele fica diferente do último job atendido (`MB_END`). `0xFFFF_FFFF` (`MB_EXIT`) encerra |
| `0x04` | `MB_FLAGS` | Modo do job (tabela abaixo) |
| `0x08` | `MB_ADDR_A` | Copiado para `ADDR_A` |
| `0x0C` | `MB_ADDR_B` | Copiado para `ADDR_B` |
| `0x10` | `MB_ADDR_C` | Copiado para `ADDR_C` |
| `0x14` | `MB_DIM_M` | Copiado para `DIM_M` |
| `0x18` | `MB_DIM_N` | Copiado para `DIM_N` |
| `0x1C` | `MB_DIM_K` | Copiado para `DIM_K` |
| `0x20` | `MB_SR_DELAY` | Com `F_SOFT_RESET`: voltas de espera (cerca de 15 ciclos cada) entre o START e o aborto |

Os valores vão para os registradores sem nenhuma conferência. Para testar erro, basta pôr na caixa a dimensão zero, o endereço desalinhado ou o endereço sem slave.

### Saída: o firmware escreve

| Offset | Nome | Conteúdo |
|---|---|---|
| `0x40` | `MB_STATE` | `0` ainda não rodou · `1` ocioso, esperando job · `2` rodando · `3` parado depois do `MB_EXIT` |
| `0x44` | `MB_STATUS` | `STATUS` no fim do job, antes do W1C: `DONE`, `ERROR`, `ERR_CODE` |
| `0x48` | `MB_CYCLES` | `CYCLES` no fim do job (para o `perf.csv`) |
| `0x4C` | `MB_CYC_COMPUTE` | `CYC_COMPUTE` no fim do job |
| `0x50` | `MB_INFO` | `INFO`: T, `PINGPONG` e versão, para o scoreboard saber a configuração |
| `0x54` | `MB_STATUS_W1C` | `STATUS` lido depois do W1C. Sobra só o `ERR_CODE`, que é RO e só zera no próximo START. `DONE` e `ERROR` em 0 mostram que o irq caiu |
| `0x58` | `MB_WAIT_COUNT` | Quanto o firmware esperou: `wfi` executados (`F_IRQ`), leituras de `STATUS` (polling) ou voltas (`F_CONTEND`, `F_SOFT_RESET`) |
| `0x5C` | `MB_BUSY_STATUS` | Com `F_BUSY_WR`: `STATUS` lido logo antes das escritas indevidas |
| `0x60` | `MB_RB_ADDR_A` | Com `F_BUSY_WR`: `ADDR_A` lido de volta depois da tentativa |
| `0x64` | `MB_RB_DIM_M` | Com `F_BUSY_WR`: `DIM_M` lido de volta depois da tentativa |
| `0x7C` | `MB_END` | Número do job concluído. É a **última escrita do job** (o "END") |
| `0x80`–`0xFC` | `MB_SCRATCH` | 32 palavras de rascunho do `F_CONTEND` |

No começo de cada job o firmware zera os campos de `0x44` a `0x64`, para nada do job anterior ser lido como resultado.

### `MB_FLAGS`

| Bit | Nome | Efeito |
|---|---|---|
| 0 | `F_IRQ` | `CTRL.IRQ_EN = 1` e espera no `wfi`. Sem ele: `IRQ_EN = 0` e polling em `STATUS` |
| 1 | `F_CONTEND` | Espera fazendo `lw`/`sw` no rascunho, na DMEM, enquanto o DMA usa a mesma memória. Cada volta soma 1 numa palavra do rascunho; a soma do que entrou é igual a `MB_WAIT_COUNT` |
| 2 | `F_SOFT_RESET` | Depois do START, espera `MB_SR_DELAY` voltas, escreve `SOFT_RESET` e espera `BUSY = 0` |
| 3 | `F_BUSY_WR` | Logo depois do START, com `BUSY = 1`, tenta reescrever `ADDR_A` e `DIM_M` e dar outro START. Depois lê `ADDR_A` e `DIM_M` de volta |

A prioridade da espera é `F_SOFT_RESET` > `F_CONTEND` > `F_IRQ` > polling. O `F_BUSY_WR` combina com qualquer um deles. `F_IRQ` continua decidindo o `IRQ_EN` mesmo com `F_CONTEND` ou `F_SOFT_RESET`.

### Protocolo de um job

1. O UVM escreve A e B na DMEM e os campos de entrada da caixa.
2. **Por último**, escreve `MB_DOORBELL` com um número novo: diferente de 0 e do job anterior. O mais simples é 1, 2, 3...
3. O firmware vê o `MB_DOORBELL` novo, marca `MB_STATE = 2`, zera a saída, copia a configuração para os registradores e dá START.
4. Espera o fim do jeito pedido em `MB_FLAGS`.
5. Guarda `STATUS`, `CYCLES`, `CYC_COMPUTE`, `INFO` e `MB_WAIT_COUNT`. Escreve 1 em `DONE` e `ERROR` (W1C, o irq cai) e guarda o `STATUS` de novo em `MB_STATUS_W1C`.
6. Escreve `MB_STATE = 1` e, por último, `MB_END = número do job`.

**O gatilho do scoreboard é a escrita em `MB_END`** (`0x1000_007C`) vista no monitor do M0. Quando ela aparece, C e todos os campos de saída já estão na memória. Se o UVM fizer polling por backdoor em vez de usar o monitor, deve esperar `MB_END == job`.

Para encerrar, o UVM escreve `MB_DOORBELL = MB_EXIT`. O firmware responde com `MB_STATE = 3` e `MB_END = MB_EXIT` e executa `ebreak`, e a CPU fica em HALT (sinal `halt`).

### O que conferir em cada job

| Situação | `MB_STATUS` | `MB_STATUS_W1C` | Outros |
|---|---|---|---|
| Job normal | `0x02` | `0x00` | C igual ao golden; `CYC_COMPUTE` = tiles × blocos × (3T − 1) |
| Dimensão zero | `0x16` | `0x10` | Nenhum acesso no M1 |
| Endereço desalinhado | `0x26` | `0x20` | Nenhum acesso no M1 |
| `RRESP` de erro (SLVERR, DECERR) | `0x36` | `0x30` | C parcial, não usar |
| `BRESP` de erro (SLVERR, DECERR) | `0x46` | `0x40` | C parcial, não usar |
| `F_SOFT_RESET` no meio da operação | `0x00` | `0x00` | `CYCLES` congelado. Se o job acabar antes do aborto, o `SOFT_RESET` não tem efeito e o resultado é o do job normal |
| `F_BUSY_WR` | — | — | `MB_BUSY_STATUS[0] = 1`; `MB_RB_ADDR_A` = `MB_ADDR_A`; `MB_RB_DIM_M` = `MB_DIM_M`. Use um job que dure mais que uns 100 ciclos, senão ele termina antes das escritas |

Em todo job também valem `MB_STATE = 1`, irq em 0 depois do END e `MB_INFO` igual ao `INFO` da configuração.

Na conferência "nada fora de C mudou", deixe de fora a caixa inteira (`0x1000_0000` a `0x1000_00FF`). Os campos de saída e o rascunho mudam em todo job.

### Ciclos

Com `F_IRQ`, a CPU fica parada no WAIT durante quase todo o job. O `CYCLES` é medido pelo DMA, do START ao DONE, e não depende do firmware. No TB-FW ele sai igual ao do TB-DMA: no caso 3 com T = 4 e `PINGPONG = 1`, 278 ciclos com `MEM=ctrl` e 294 com `MEM=model`.

## TB-FW (`tb/unit_fw/tb_fw.v`)

Roda o firmware na CPU multiciclo de verdade, com o DMA, o systolic array e a DMEM reais (`axi_mem_ctrl` ou `axi_mem_model`). O TB faz o papel do UVM: escreve os jobs na caixa por backdoor e confere a saída a cada END.

| Job | O que exercita |
|---|---|
| 1 | Caso 3 (6×5×7) com `wfi`: a CPU tem de passar ciclos no WAIT |
| 2 | Caso 3 com polling: a CPU nunca entra no WAIT |
| 3 | Caso 3 com `F_CONTEND`: a soma do rascunho bate com `MB_WAIT_COUNT` |
| 4 | `F_BUSY_WR`: `ADDR_A`, `DIM_M` e START ignorados com `BUSY = 1` |
| 5 a 9 | `ERR_CODE` 1, 2, 3 e 4 (SLVERR na escrita; DECERR na escrita só com `MEM=model`) |
| 10 e 11 | `SOFT_RESET` no meio da operação e um job normal logo depois (retomada) |
| 12 | Caso 6 (3×64×3, K longo), com A e B novos na DMEM |
| fim | `MB_EXIT`: a CPU para no `ebreak` |

Em todos os jobs o TB confere C contra o golden, a palavra logo depois de C intacta, `STATUS` antes e depois do W1C, o irq, `MB_STATE`, `INFO` e `CYC_COMPUTE`. O tempo todo, um monitor confere que a CPU só acessa a caixa e os registradores do DMA: é o requisito "a CPU não move os dados". O `axi_checker` fica ligado no S1 e no M1.

**Situação atual:** `make tb_fw` passa nas 6 configurações, sem e com backpressure, com `MEM=ctrl` e `MEM=model`, no Icarus 12 e no Xcelium 24.09: 48 de 48 execuções. Para conferir que o TB pega erro, montamos quatro firmwares quebrados de propósito: sem W1C, escrevendo em C, END antes do resultado e sem `IRQ_EN`. O TB reprovou os quatro.

**Provisório até o top.v:**

- A Porta D da CPU passa por uma ponte comportamental do TB no lugar do `cpu_axi_adapter` + `axi_xbar`. Endereços `0x4…` viram transações AXI de 1 beat no S1, pelo `axi_master_bfm`. Endereços `0x1…` acessam a DMEM por backdoor. Os demais leem 0 e descartam a escrita.
- A CPU multiciclo ainda está só na branch `processor-rv32i`. O alvo extrai o `rtl/cpu` dela para `build/cpu_branch/`. Depois do merge, use `make tb_fw CPU_DIR=rtl/cpu` ou mude o padrão no Makefile.

Quando o `top.v` existir, o firmware e a caixa continuam iguais. Muda só o TB, que passa a instanciar o top.
