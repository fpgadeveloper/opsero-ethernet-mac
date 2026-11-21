/* SPDX-License-Identifier: MIT */
/*
 * omac_mdio.c - bare-metal driver for the omac_mdio MDIO master. See omac_mdio.h.
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#include "omac_mdio.h"

#define RD(m, off)      OMAC_MDIO_RD32((m)->base + (off))
#define WR(m, off, v)   OMAC_MDIO_WR32((m)->base + (off), (uint32_t)(v))

uint32_t omac_mdio_div(uint32_t clk_hz, uint32_t mdc_hz)
{
    /* MDC = clk / (2 (DIV + 1)) <= mdc_hz  ->  DIV = ceil(clk / (2 mdc)) - 1 */
    uint64_t den, n;

    if (mdc_hz == 0)
        return 255;
    den = 2ull * mdc_hz;
    n = ((uint64_t)clk_hz + den - 1) / den;
    if (n == 0)
        n = 1;
    if (n > 256)
        n = 256;
    return (uint32_t)(n - 1);
}

static void cfg_update(omac_mdio_t *m, uint32_t clear, uint32_t set)
{
    WR(m, OMAC_MDIO_CFG, (RD(m, OMAC_MDIO_CFG) & ~clear) | set);
}

int omac_mdio_init(omac_mdio_t *m, uintptr_t base, uint32_t clk_hz, uint32_t mdc_hz)
{
    uint32_t cfg;

    m->base = base;
    if (m->poll_max == 0)
        m->poll_max = 1000000u;
    m->last_status = 0;
    if (RD(m, OMAC_MDIO_ID) != OMAC_MDIO_ID_VALUE)
        return OMAC_MDIO_ERR_ID;
    /* a command left over from before (a debugger session, a warm restart) */
    if (RD(m, OMAC_MDIO_STATUS) & OMAC_MDIO_ST_BUSY)
        WR(m, OMAC_MDIO_CTRL, OMAC_MDIO_CTRL_ABORT);
    WR(m, OMAC_MDIO_BITBANG, 0);
    cfg = RD(m, OMAC_MDIO_CFG) & 0xFFu;
    if (clk_hz != 0)
        cfg = omac_mdio_div(clk_hz, mdc_hz);
    WR(m, OMAC_MDIO_CFG, OMAC_MDIO_CFG_DIV(cfg) | OMAC_MDIO_CFG_PRE(32));
    WR(m, OMAC_MDIO_STATUS, OMAC_MDIO_ST_DONE | OMAC_MDIO_ST_CMD_IGN);
    return OMAC_MDIO_OK;
}

void omac_mdio_set_preamble(omac_mdio_t *m, unsigned bits)
{
    cfg_update(m, OMAC_MDIO_CFG_PRE(0x3F), OMAC_MDIO_CFG_PRE(bits > 63 ? 63 : bits));
}

void omac_mdio_set_mdc_free(omac_mdio_t *m, int on)
{
    cfg_update(m, OMAC_MDIO_CFG_MDC_FREE, on ? OMAC_MDIO_CFG_MDC_FREE : 0);
}

void omac_mdio_set_hold(omac_mdio_t *m, int on)
{
    cfg_update(m, OMAC_MDIO_CFG_HOLD, on ? OMAC_MDIO_CFG_HOLD : 0);
}

int omac_mdio_raw(omac_mdio_t *m, uint32_t cmd, uint32_t wdata, uint16_t *rdata)
{
    uint32_t st, n;

    /* wait for a previous command (only possible if someone else started one) */
    for (n = 0; RD(m, OMAC_MDIO_STATUS) & OMAC_MDIO_ST_BUSY; n++) {
        if (n >= m->poll_max) {
            WR(m, OMAC_MDIO_CTRL, OMAC_MDIO_CTRL_ABORT);
            break;
        }
    }
    WR(m, OMAC_MDIO_WDATA, wdata);
    WR(m, OMAC_MDIO_CMD, cmd);
    for (n = 0;; n++) {
        st = RD(m, OMAC_MDIO_STATUS);
        if (!(st & OMAC_MDIO_ST_BUSY))
            break;
        if (n >= m->poll_max) {
            WR(m, OMAC_MDIO_CTRL, OMAC_MDIO_CTRL_ABORT);
            m->last_status = RD(m, OMAC_MDIO_STATUS);
            return OMAC_MDIO_ERR_TIMEOUT;
        }
    }
    m->last_status = st;
    WR(m, OMAC_MDIO_STATUS, OMAC_MDIO_ST_DONE);
    if (rdata)
        *rdata = (uint16_t)(RD(m, OMAC_MDIO_RDATA) & 0xFFFFu);
    if (st & OMAC_MDIO_ST_TA_ERR)
        return OMAC_MDIO_ERR_NORESP;
    return OMAC_MDIO_OK;
}

int omac_mdio_c22_read(omac_mdio_t *m, unsigned phy, unsigned reg, uint16_t *val)
{
    if (phy > 31 || reg > 31)
        return OMAC_MDIO_ERR_ARG;
    return omac_mdio_raw(m, OMAC_MDIO_OP_C22_READ | OMAC_MDIO_CMD_PHY(phy) | OMAC_MDIO_CMD_REG(reg), 0, val);
}

int omac_mdio_c22_write(omac_mdio_t *m, unsigned phy, unsigned reg, uint16_t val)
{
    if (phy > 31 || reg > 31)
        return OMAC_MDIO_ERR_ARG;
    return omac_mdio_raw(m, OMAC_MDIO_OP_C22_WRITE | OMAC_MDIO_CMD_PHY(phy) | OMAC_MDIO_CMD_REG(reg),
                         val, (uint16_t *)0);
}

int omac_mdio_c45_read(omac_mdio_t *m, unsigned prtad, unsigned devad, uint16_t reg, uint16_t *val)
{
    if (prtad > 31 || devad > 31)
        return OMAC_MDIO_ERR_ARG;
    return omac_mdio_raw(m, OMAC_MDIO_OP_C45_READ | OMAC_MDIO_CMD_C45 | OMAC_MDIO_CMD_ADDR_FIRST |
                         OMAC_MDIO_CMD_PHY(prtad) | OMAC_MDIO_CMD_REG(devad), (uint32_t)reg << 16, val);
}

int omac_mdio_c45_write(omac_mdio_t *m, unsigned prtad, unsigned devad, uint16_t reg, uint16_t val)
{
    if (prtad > 31 || devad > 31)
        return OMAC_MDIO_ERR_ARG;
    return omac_mdio_raw(m, OMAC_MDIO_OP_C45_WRITE | OMAC_MDIO_CMD_C45 | OMAC_MDIO_CMD_ADDR_FIRST |
                         OMAC_MDIO_CMD_PHY(prtad) | OMAC_MDIO_CMD_REG(devad),
                         ((uint32_t)reg << 16) | val, (uint16_t *)0);
}

int omac_mdio_c45_read_inc(omac_mdio_t *m, unsigned prtad, unsigned devad, uint16_t reg,
                           uint16_t *buf, unsigned n)
{
    uint32_t base_cmd = OMAC_MDIO_CMD_C45 | OMAC_MDIO_CMD_PHY(prtad) | OMAC_MDIO_CMD_REG(devad);
    unsigned i;
    int rc;

    if (prtad > 31 || devad > 31)
        return OMAC_MDIO_ERR_ARG;
    if (n == 0)
        return OMAC_MDIO_OK;
    rc = omac_mdio_raw(m, base_cmd | OMAC_MDIO_OP_C45_ADDR, reg, (uint16_t *)0);
    for (i = 0; rc == OMAC_MDIO_OK && i < n; i++)
        rc = omac_mdio_raw(m, base_cmd | OMAC_MDIO_OP_C45_RD_INC, 0, &buf[i]);
    return rc;
}
