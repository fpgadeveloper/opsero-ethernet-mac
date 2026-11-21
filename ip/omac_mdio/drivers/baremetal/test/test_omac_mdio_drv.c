/* SPDX-License-Identifier: MIT */
/*
 * test_omac_mdio_drv.c - host unit test of the omac_mdio bare-metal driver against a
 * register-level model of the core (written from the register map in docs/omac_mdio.md):
 * CFG / CMD / WDATA / RDATA / STATUS (w1c) / CTRL.ABORT, BUSY for a few polls per
 * command, ADDR_FIRST, post-read-increment, TA_ERR for absent PHYs, and three PHYs
 * (1 and 5: clause 22 + 45, 9: clause 22 only).
 * The driver source is included (one translation unit) with the register accessors
 * redirected to the model. Build: cc -std=c99 -Wall -Wextra -Werror -I.. test_omac_mdio_drv.c
 *
 * Copyright (c) 2026 Opsero Electronic Design Inc.
 */
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static uint32_t model_rd(uintptr_t addr);
static void model_wr(uintptr_t addr, uint32_t val);
#define OMAC_MDIO_RD32(addr)      model_rd(addr)
#define OMAC_MDIO_WR32(addr, val) model_wr((addr), (val))
#include "omac_mdio.c"

/* ---------------------------------------------------------------- model */
#define BASE 0x80010000u

static struct {
    uint32_t id, cfg, cmd, wdata, rdata, status, bb;
    int busy_polls;          /* STATUS reads that still show BUSY */
    int stuck;               /* never finishes */
    int aborts, cmds;
    uint16_t r22[32][32];
    uint16_t m45[32][32][64]; /* registers 0-63 of every MMD are enough here */
    uint16_t areg[32][32];
} M;

static int answers(unsigned pa, int c45)
{
    if (pa == 1 || pa == 5)
        return 1;
    return pa == 9 && !c45;
}

static void model_reset(void)
{
    memset(&M, 0, sizeof(M));
    M.id = 0x4D44494Fu;
    M.cfg = 19u | (32u << 8);
    for (unsigned p = 0; p < 32; p++)
        for (unsigned r = 0; r < 32; r++)
            M.r22[p][r] = (uint16_t)(0x2200 ^ (p << 8) ^ (r * 0x0101));
}

static uint16_t *reg45(unsigned pa, unsigned dev, uint16_t a)
{
    static uint16_t dummy;
    if (a >= 64) {
        dummy = (uint16_t)(a ^ 0xA5A5);
        return &dummy;
    }
    return &M.m45[pa][dev][a];
}

static void model_frame(int c45, unsigned op, unsigned pa, unsigned ra, uint16_t data, int *ta_err,
                        uint16_t *rd)
{
    int rdop = c45 ? (op & 2) != 0 : op == 2;
    if (!answers(pa, c45)) {
        if (rdop) {
            *ta_err = 1;
            *rd = 0xFFFF;
        }
        return;
    }
    if (!c45) {
        if (op == 1)
            M.r22[pa][ra] = data;
        else if (op == 2)
            *rd = M.r22[pa][ra];
        return;
    }
    switch (op) {
    case 0: M.areg[pa][ra] = data; break;
    case 1: *reg45(pa, ra, M.areg[pa][ra]) = data; break;
    case 2: *rd = *reg45(pa, ra, M.areg[pa][ra]); M.areg[pa][ra]++; break;
    case 3: *rd = *reg45(pa, ra, M.areg[pa][ra]); break;
    }
}

static void model_cmd(uint32_t c)
{
    unsigned op = c & 3, pa = (c >> 8) & 31, ra = (c >> 16) & 31;
    int c45 = (c >> 2) & 1, a1st = (c >> 3) & 1, ta_err = 0;
    int rdop = c45 ? (op & 2) != 0 : op == 2;
    uint16_t rd = 0;

    if (M.status & 1) {
        M.status |= 1u << 6;
        return;
    }
    M.cmds++;
    M.cmd = c;
    if (c45 && a1st && op != 0)
        model_frame(1, 0, pa, ra, (uint16_t)(M.wdata >> 16), &ta_err, &rd);
    model_frame(c45, op, pa, ra, (uint16_t)M.wdata, &ta_err, &rd);
    M.status = 1;            /* BUSY; DONE, RD_VALID, TA_ERR, BUS_ERR, ABORTED cleared */
    if (rdop) {
        M.rdata = rd;
        M.status |= ta_err ? (1u << 3) : (1u << 2);
    }
    M.busy_polls = 3;
}

static uint32_t model_rd(uintptr_t addr)
{
    switch (addr - BASE) {
    case 0x000: return M.id;
    case 0x004: return 0x100;
    case 0x008: return M.cfg;
    case 0x00C: return M.cmd;
    case 0x010: return M.wdata;
    case 0x014: return M.rdata | ((M.status & 4) ? 1u << 16 : 0);
    case 0x018:
        if ((M.status & 1) && !M.stuck && --M.busy_polls <= 0)
            M.status = (M.status & ~1u) | 2u;
        return M.status | (1u << 10);
    case 0x020: return M.bb;
    }
    return 0;
}

static void model_wr(uintptr_t addr, uint32_t val)
{
    switch (addr - BASE) {
    case 0x008: M.cfg = val & 0x73FFFu; break;   /* [18:16], [13:8], [7:0] */
    case 0x00C: model_cmd(val); break;
    case 0x010: M.wdata = val; break;
    case 0x018: M.status &= ~(val & ((1u << 1) | (1u << 6))); break;
    case 0x01C:
        if ((val & 1) && (M.status & 1)) {
            M.status = (M.status & ~1u & ~(1u << 2)) | (1u << 1) | (1u << 5);
            M.aborts++;
        }
        break;
    case 0x020: M.bb = val; break;
    }
}

/* ---------------------------------------------------------------- tests */
static int fails, checks;
#define CHECK(c) do { checks++; if (!(c)) { fails++; printf("FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main(void)
{
    omac_mdio_t m;
    uint16_t v, buf[6];
    int rc;

    /* divider */
    CHECK(omac_mdio_div(100000000, 2500000) == 19);
    CHECK(omac_mdio_div(99999000, 2500000) == 19);
    CHECK(omac_mdio_div(250000000, 2500000) == 49);
    CHECK(omac_mdio_div(300000000, 2500000) == 59);
    CHECK(omac_mdio_div(100000000, 12500000) == 3);
    CHECK(omac_mdio_div(100000000, 12000000) == 4);
    CHECK(omac_mdio_div(1000000000, 1000) == 255);
    CHECK(omac_mdio_div(10000000, 100000000) == 0);
    CHECK(omac_mdio_div(100000000, 0) == 255);

    /* init */
    model_reset();
    M.id = 0x12345678;
    memset(&m, 0, sizeof(m));
    CHECK(omac_mdio_init(&m, BASE, 100000000, 2500000) == OMAC_MDIO_ERR_ID);
    model_reset();
    M.cfg = 0x7;   /* other divider, preamble 0 */
    memset(&m, 0, sizeof(m));
    CHECK(omac_mdio_init(&m, BASE, 250000000, 2500000) == OMAC_MDIO_OK);
    CHECK(M.cfg == (49u | (32u << 8)));
    CHECK(m.poll_max == 1000000u);
    M.cfg = 0x7;
    CHECK(omac_mdio_init(&m, BASE, 0, 0) == OMAC_MDIO_OK);
    CHECK(M.cfg == (7u | (32u << 8)));        /* clk_hz 0: divider kept */
    CHECK(omac_mdio_init(&m, BASE, 100000000, 2500000) == OMAC_MDIO_OK);

    /* configuration bits */
    omac_mdio_set_preamble(&m, 0);
    CHECK(M.cfg == 19u);
    omac_mdio_set_preamble(&m, 99);
    CHECK(M.cfg == (19u | (63u << 8)));
    omac_mdio_set_preamble(&m, 32);
    omac_mdio_set_mdc_free(&m, 1);
    omac_mdio_set_hold(&m, 1);
    CHECK(M.cfg == (19u | (32u << 8) | (1u << 16) | (1u << 18)));
    omac_mdio_set_mdc_free(&m, 0);
    omac_mdio_set_hold(&m, 0);
    CHECK(M.cfg == (19u | (32u << 8)));

    /* clause 22 */
    CHECK(omac_mdio_c22_read(&m, 1, 2, &v) == OMAC_MDIO_OK && v == (0x2200 ^ 0x0100 ^ 0x0202));
    CHECK(M.cmd == (0x2u | (1u << 8) | (2u << 16)));
    CHECK(omac_mdio_c22_write(&m, 5, 4, 0xBEEF) == OMAC_MDIO_OK && M.r22[5][4] == 0xBEEF);
    CHECK(M.cmd == (0x1u | (5u << 8) | (4u << 16)) && (M.wdata & 0xFFFF) == 0xBEEF);
    CHECK(omac_mdio_c22_read(&m, 5, 4, &v) == OMAC_MDIO_OK && v == 0xBEEF);
    CHECK(omac_mdio_c22_read(&m, 9, 31, &v) == OMAC_MDIO_OK && v == (uint16_t)(0x2200 ^ 0x0900 ^ (31 * 0x0101)));
    CHECK((M.status & 2) == 0);               /* DONE cleared by the driver */
    v = 0;
    CHECK(omac_mdio_c22_read(&m, 7, 1, &v) == OMAC_MDIO_ERR_NORESP && v == 0xFFFF);
    CHECK(omac_mdio_c22_write(&m, 7, 1, 1) == OMAC_MDIO_OK);   /* writes have no answer */
    CHECK(omac_mdio_c22_read(&m, 32, 1, &v) == OMAC_MDIO_ERR_ARG);
    CHECK(omac_mdio_c22_write(&m, 1, 32, 0) == OMAC_MDIO_ERR_ARG);

    /* clause 45 */
    CHECK(omac_mdio_c45_write(&m, 1, 3, 0x0010, 0x1234) == OMAC_MDIO_OK && M.m45[1][3][0x10] == 0x1234);
    CHECK(M.cmd == (0x1u | (1u << 2) | (1u << 3) | (1u << 8) | (3u << 16)) && M.wdata == 0x00101234u);
    CHECK(omac_mdio_c45_write(&m, 5, 31, 0x0011, 0x5678) == OMAC_MDIO_OK && M.m45[5][31][0x11] == 0x5678);
    CHECK(omac_mdio_c45_read(&m, 1, 3, 0x0010, &v) == OMAC_MDIO_OK && v == 0x1234);
    CHECK(M.cmd == (0x3u | (1u << 2) | (1u << 3) | (1u << 8) | (3u << 16)) && (M.wdata >> 16) == 0x0010);
    CHECK(omac_mdio_c45_read(&m, 5, 31, 0x0011, &v) == OMAC_MDIO_OK && v == 0x5678);
    CHECK(omac_mdio_c45_read(&m, 9, 1, 0x0000, &v) == OMAC_MDIO_ERR_NORESP);  /* clause 22 only */
    CHECK(omac_mdio_c45_read(&m, 1, 32, 0, &v) == OMAC_MDIO_ERR_ARG);
    for (unsigned i = 0; i < 6; i++)
        M.m45[5][7][20 + i] = (uint16_t)(0x700 + i);
    memset(buf, 0, sizeof(buf));
    CHECK(omac_mdio_c45_read_inc(&m, 5, 7, 20, buf, 6) == OMAC_MDIO_OK);
    CHECK(buf[0] == 0x700 && buf[5] == 0x705 && M.areg[5][7] == 26);
    CHECK(omac_mdio_c45_read_inc(&m, 5, 7, 20, buf, 0) == OMAC_MDIO_OK);

    /* timeout: the command never ends -> aborted */
    M.stuck = 1;
    m.poll_max = 50;
    rc = omac_mdio_c22_read(&m, 1, 1, &v);
    CHECK(rc == OMAC_MDIO_ERR_TIMEOUT && M.aborts == 1 && (m.last_status & OMAC_MDIO_ST_ABORTED));
    M.stuck = 0;
    m.poll_max = 1000000;
    CHECK(omac_mdio_c22_read(&m, 1, 1, &v) == OMAC_MDIO_OK);

    /* raw */
    CHECK(omac_mdio_raw(&m, 0x2u | (9u << 8) | (3u << 16), 0, &v) == OMAC_MDIO_OK &&
          v == (uint16_t)(0x2200 ^ 0x0900 ^ 0x0303));

    printf("%d checks, %d failed, %d commands to the model\n", checks, fails, M.cmds);
    printf("OMAC_MDIO_DRV TEST %s\n", fails ? "FAIL" : "PASS");
    return fails ? 1 : 0;
}
