/* Gerado por sw/rvasm.py --defs c a partir de mailbox.inc. Nao edite: */
/* mude o mailbox.inc e rode de novo (make fw).                      */
#ifndef MAILBOX_H
#define MAILBOX_H

#define MB_BASE              0x10000000u
#define MB_DOORBELL          0x00000000u
#define MB_FLAGS             0x00000004u
#define MB_ADDR_A            0x00000008u
#define MB_ADDR_B            0x0000000Cu
#define MB_ADDR_C            0x00000010u
#define MB_DIM_M             0x00000014u
#define MB_DIM_N             0x00000018u
#define MB_DIM_K             0x0000001Cu
#define MB_SR_DELAY          0x00000020u
#define MB_STATE             0x00000040u
#define MB_STATUS            0x00000044u
#define MB_CYCLES            0x00000048u
#define MB_CYC_COMPUTE       0x0000004Cu
#define MB_INFO              0x00000050u
#define MB_STATUS_W1C        0x00000054u
#define MB_WAIT_COUNT        0x00000058u
#define MB_BUSY_STATUS       0x0000005Cu
#define MB_RB_ADDR_A         0x00000060u
#define MB_RB_DIM_M          0x00000064u
#define MB_END               0x0000007Cu
#define MB_SCRATCH           0x00000080u
#define MB_SCRATCH_WORDS     0x00000020u
#define MB_SIZE              0x00000100u
#define F_IRQ                0x00000001u
#define F_CONTEND            0x00000002u
#define F_SOFT_RESET         0x00000004u
#define F_BUSY_WR            0x00000008u
#define ST_RESET             0x00000000u
#define ST_IDLE              0x00000001u
#define ST_RUN               0x00000002u
#define ST_HALT              0x00000003u
#define MB_EXIT              0xFFFFFFFFu

#endif /* MAILBOX_H */
