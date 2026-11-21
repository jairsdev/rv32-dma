# Frontend AXI4 copiado do `interface_amba`

Estes arquivos formam o frontend AXI4 do nosso controlador da DMEM ([`rtl/top/axi_mem_ctrl.v`](../../top/axi_mem_ctrl.v), MAS §12.2). Eles foram copiados de outro projeto do programa, sem fork.

| Item | Valor |
|---|---|
| Repositório | https://github.com/guto7191/interface_amba |
| Branch | `Implementacion_uvm_axi_sram` |
| Commit | `8f95bf24a8a23fd72e006ecd93833b296890621a` (09/11/2026) |
| Documento de origem | `docs/MAS_axi4_sram.md` daquele repositório (§3.2 contrato `ram_*`, §5.3 decoder, §5.4 transaction manager, §5.6 alinhamento) |

## Arquivos

| Aqui | Origem | Alterado? |
|---|---|---|
| `axi_address_decoder.v` | `rtl/axi4_sram/axi_address_decoder.v` | Sim, ver abaixo |
| `axi_transaction_manager.v` | `rtl/axi4_sram/derived/axi_transaction_manager.v` | Não |
| `axi_narrow_read_align.v` | `rtl/axi4_sram/axi_narrow_read_align.v` | Não |

O que **não** veio:
- o `axi_defs.vh` de lá, que tem o mesmo guard `AXI_DEFS_VH` do nosso [`rtl/common/axi_defs.vh`](../../common/axi_defs.vh). O nosso já define `AXI_RESP_OKAY`, `AXI_RESP_SLVERR` e `AXI_RESP_DECERR`, que são as únicas macros que o decoder usa;
- a controladora da SRAM externa de 16 bits (`sram_controller*`, `sram_io_buffer`), a placa (`de2_115_top`, `reset_synchronizer`), a IP original e os testbenches (legado e UVM).

No lugar da SRAM externa, o backend é a nossa SRAM síncrona on-chip [`rtl/top/dmem_sram.v`](../../top/dmem_sram.v), que segue o mesmo contrato `ram_*`.

## Licença

O `axi_transaction_manager.v` é obra derivada da IP *AXI4 -> Async SRAM (16-bit)* da Ultra-Embedded (2019), licenciada em **LGPL 2.1 ou posterior**. O cabeçalho de copyright e a licença estão intactos no arquivo e não podem ser removidos. O mesmo arquivo também traz a lista das alterações que o projeto `interface_amba` fez na IP (marcadores `// A<n>`).

## Alterações locais

O commit de cópia deixou os três arquivos idênticos aos da origem. Toda alteração feita depois leva o marcador `// R<n>` na linha e está listada aqui.

_(nenhuma ainda)_
