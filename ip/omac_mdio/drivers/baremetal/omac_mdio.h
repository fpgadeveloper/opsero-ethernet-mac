/* SPDX-License-Identifier: MIT */
/*
 * omac_mdio.h - bare-metal driver for the omac_mdio MDIO master (IEEE 802.3 clause 22
 *               and clause 45 management frames, AXI4-Lite registers).
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 *
 * Polled, no interrupt, no dynamic memory, no dependency beyond a 32-bit register read and
 * write. The accessors default to Xil_In32() / Xil_Out32() from the AMD standalone BSP
 * (xil_io.h); define OMAC_MDIO_RD32(addr) and OMAC_MDIO_WR32(addr, val) before including
 * this header (or on the compiler command line) to use anything else, for example a host
 * register model in a unit test.
 *
 * Usage:
 *     omac_mdio_t mdio;
 *     uint16_t v;
 *     omac_mdio_init(&mdio, XPAR_..._BASEADDR, 100000000, 2500000);   // AXI clock, MDC
 *     omac_mdio_c45_read(&mdio, 1, 1, 0x0002, &v);                     // PHY 1, PMA/PMD, ID
 *     omac_mdio_c22_write(&mdio, 5, 0, 0x8000);                         // PHY 5, BMCR reset
 */
#ifndef OMAC_MDIO_H
#define OMAC_MDIO_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if !defined(OMAC_MDIO_RD32) || !defined(OMAC_MDIO_WR32)
#include "xil_io.h"
#define OMAC_MDIO_RD32(addr)      Xil_In32(addr)
#define OMAC_MDIO_WR32(addr, val) Xil_Out32((addr), (val))
#endif

/* registers (byte offsets) */
#define OMAC_MDIO_ID          0x000u  /* 0x4D44494F "MDIO" */
#define OMAC_MDIO_VERSION     0x004u
#define OMAC_MDIO_CFG         0x008u
#define OMAC_MDIO_CMD         0x00Cu
#define OMAC_MDIO_WDATA       0x010u
#define OMAC_MDIO_RDATA       0x014u
#define OMAC_MDIO_STATUS      0x018u
#define OMAC_MDIO_CTRL        0x01Cu
#define OMAC_MDIO_BITBANG     0x020u

#define OMAC_MDIO_ID_VALUE    0x4D44494Fu

/* CFG */
#define OMAC_MDIO_CFG_DIV(x)      ((uint32_t)(x) & 0xFFu)
#define OMAC_MDIO_CFG_PRE(x)      (((uint32_t)(x) & 0x3Fu) << 8)
#define OMAC_MDIO_CFG_MDC_FREE    (1u << 16)
#define OMAC_MDIO_CFG_IRQ_EN      (1u << 17)
#define OMAC_MDIO_CFG_HOLD        (1u << 18)

/* CMD */
#define OMAC_MDIO_OP_C22_WRITE    0x1u
#define OMAC_MDIO_OP_C22_READ     0x2u
#define OMAC_MDIO_OP_C45_ADDR     0x0u
#define OMAC_MDIO_OP_C45_WRITE    0x1u
#define OMAC_MDIO_OP_C45_RD_INC   0x2u
#define OMAC_MDIO_OP_C45_READ     0x3u
#define OMAC_MDIO_CMD_C45         (1u << 2)
#define OMAC_MDIO_CMD_ADDR_FIRST  (1u << 3)
#define OMAC_MDIO_CMD_PHY(x)      (((uint32_t)(x) & 0x1Fu) << 8)
#define OMAC_MDIO_CMD_REG(x)      (((uint32_t)(x) & 0x1Fu) << 16)

/* STATUS */
#define OMAC_MDIO_ST_BUSY         (1u << 0)
#define OMAC_MDIO_ST_DONE         (1u << 1)
#define OMAC_MDIO_ST_RD_VALID     (1u << 2)
#define OMAC_MDIO_ST_TA_ERR       (1u << 3)
#define OMAC_MDIO_ST_BUS_ERR      (1u << 4)
#define OMAC_MDIO_ST_ABORTED      (1u << 5)
#define OMAC_MDIO_ST_CMD_IGN      (1u << 6)
#define OMAC_MDIO_ST_HELD         (1u << 8)
#define OMAC_MDIO_ST_HOLD         (1u << 9)
#define OMAC_MDIO_ST_MDIO_IN      (1u << 10)

/* CTRL */
#define OMAC_MDIO_CTRL_ABORT      (1u << 0)

/* return codes */
#define OMAC_MDIO_OK              0
#define OMAC_MDIO_ERR_ID          (-1)  /* no omac_mdio at this address */
#define OMAC_MDIO_ERR_TIMEOUT     (-2)  /* command not finished in poll_max polls: aborted */
#define OMAC_MDIO_ERR_NORESP      (-3)  /* read: no PHY drove the turnaround bit (value 0xFFFF) */
#define OMAC_MDIO_ERR_ARG         (-4)  /* address or MMD out of range */

typedef struct {
    uintptr_t base;
    uint32_t  poll_max;   /* STATUS polls before a command is aborted (default 1,000,000) */
    uint32_t  last_status;
} omac_mdio_t;

/*
 * Checks the ID register, sets the MDC divider for an MDC of at most mdc_hz from a register
 * clock of clk_hz (clk_hz = 0: keep the divider), a 32-bit preamble, MDC held low between
 * frames, no hold, no interrupt. Returns OMAC_MDIO_OK or OMAC_MDIO_ERR_ID.
 */
int omac_mdio_init(omac_mdio_t *m, uintptr_t base, uint32_t clk_hz, uint32_t mdc_hz);

/* MDC divider for clk_hz -> at most mdc_hz (0-255; 255 if that is still too fast) */
uint32_t omac_mdio_div(uint32_t clk_hz, uint32_t mdc_hz);

/* configuration: preamble length (0 = suppressed, 32 = IEEE default), MDC free-running,
 * software hold-off (no command starts while set) */
void omac_mdio_set_preamble(omac_mdio_t *m, unsigned bits);
void omac_mdio_set_mdc_free(omac_mdio_t *m, int on);
void omac_mdio_set_hold(omac_mdio_t *m, int on);

/* clause 22: PHY address 0-31, register 0-31 */
int omac_mdio_c22_read(omac_mdio_t *m, unsigned phy, unsigned reg, uint16_t *val);
int omac_mdio_c22_write(omac_mdio_t *m, unsigned phy, unsigned reg, uint16_t val);

/* clause 45: port address 0-31, MMD 0-31, register 0-65535 (address frame + data frame,
 * run back to back by the core as one command) */
int omac_mdio_c45_read(omac_mdio_t *m, unsigned prtad, unsigned devad, uint16_t reg, uint16_t *val);
int omac_mdio_c45_write(omac_mdio_t *m, unsigned prtad, unsigned devad, uint16_t reg, uint16_t val);

/* clause 45: n consecutive registers from reg with one address frame and n
 * post-read-increment-address frames */
int omac_mdio_c45_read_inc(omac_mdio_t *m, unsigned prtad, unsigned devad, uint16_t reg,
                           uint16_t *buf, unsigned n);

/* one raw command (CMD value as in the register map, WDATA value); for tests and tools */
int omac_mdio_raw(omac_mdio_t *m, uint32_t cmd, uint32_t wdata, uint16_t *rdata);

#ifdef __cplusplus
}
#endif

#endif /* OMAC_MDIO_H */
