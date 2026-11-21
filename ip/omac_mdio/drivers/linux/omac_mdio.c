// SPDX-License-Identifier: GPL-2.0-only OR MIT
/*
 * omac_mdio - MDIO bus driver for the omac_mdio MDIO master of opsero-ethernet-mac
 *             (https://github.com/fpgadeveloper/opsero-ethernet-mac).
 *
 * Copyright (C) 2026, Opsero Electronic Design Inc.
 *
 * The core sends IEEE 802.3 clause 22 and clause 45 management frames on one MDC/MDIO bus;
 * software writes one command and polls until it is done. A clause 45 access is one command:
 * the core runs the address frame and the data frame back to back (CMD.ADDR_FIRST). The bus
 * is registered as an mii_bus with clause 22 and clause 45 accessors, so any MAC driver can
 * reach its PHY through "phy-handle", and the PHY nodes below the bus node are probed by the
 * MDIO core (of_mdiobus_register).
 *
 * Device tree (see opsero,omac-mdio.yaml): reg, optional clocks (the AXI4-Lite clock) and
 * clock-frequency (MDC, default 2.5 MHz), suppress-preamble, opsero,mdc-free-running,
 * opsero,timeout-us, and the generic MDIO bus properties (reset-gpios, reset-delay-us, ...).
 * Without a clock the divider stays at the core's reset value (DIV_INIT parameter).
 *
 * A read that no PHY answers (the second turnaround bit is not driven low) returns 0xffff,
 * as an empty bus reads, which is what the MDIO core expects when it scans for PHYs.
 */

#include <linux/bitfield.h>
#include <linux/clk.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/mod_devicetable.h>
#include <linux/module.h>
#include <linux/of.h>
#include <linux/of_mdio.h>
#include <linux/phy.h>
#include <linux/platform_device.h>

#define DRV_NAME		"omac_mdio"

/* registers */
#define OMAC_MDIO_ID		0x000
#define OMAC_MDIO_VERSION	0x004
#define OMAC_MDIO_CFG		0x008
#define OMAC_MDIO_CMD		0x00c
#define OMAC_MDIO_WDATA		0x010
#define OMAC_MDIO_RDATA		0x014
#define OMAC_MDIO_STATUS	0x018
#define OMAC_MDIO_CTRL		0x01c
#define OMAC_MDIO_BITBANG	0x020

#define OMAC_MDIO_ID_VALUE	0x4d44494f	/* "MDIO" */

#define CFG_DIV			GENMASK(7, 0)
#define CFG_PRE			GENMASK(13, 8)
#define CFG_MDC_FREE		BIT(16)
#define CFG_IRQ_EN		BIT(17)
#define CFG_HOLD		BIT(18)

#define CMD_OP			GENMASK(1, 0)
#define CMD_C45			BIT(2)
#define CMD_ADDR_FIRST		BIT(3)
#define CMD_PHY			GENMASK(12, 8)
#define CMD_REG			GENMASK(20, 16)

#define OP_C22_WRITE		1
#define OP_C22_READ		2
#define OP_C45_WRITE		1
#define OP_C45_READ		3

#define WDATA_DATA		GENMASK(15, 0)
#define WDATA_ADDR		GENMASK(31, 16)

#define ST_BUSY			BIT(0)
#define ST_DONE			BIT(1)
#define ST_TA_ERR		BIT(3)
#define ST_BUS_ERR		BIT(4)
#define ST_CMD_IGN		BIT(6)

#define CTRL_ABORT		BIT(0)

#define OMAC_MDIO_DEF_FREQ	2500000		/* IEEE 802.3 maximum MDC, Hz */
#define OMAC_MDIO_DEF_TIMEOUT	10000		/* us */

struct omac_mdio {
	void __iomem *base;
	struct device *dev;
	u32 timeout_us;
};

static u32 omac_mdio_cmd(u32 op, u32 flags, int addr, int reg)
{
	return FIELD_PREP(CMD_OP, op) | flags | FIELD_PREP(CMD_PHY, addr) |
	       FIELD_PREP(CMD_REG, reg);
}

static int omac_mdio_xfer(struct omac_mdio *priv, u32 cmd, u32 wdata,
			  u16 *val)
{
	u32 st;
	int ret;

	writel(wdata, priv->base + OMAC_MDIO_WDATA);
	writel(cmd, priv->base + OMAC_MDIO_CMD);
	ret = readl_poll_timeout(priv->base + OMAC_MDIO_STATUS, st,
				 !(st & ST_BUSY), 10, priv->timeout_us);
	if (ret) {
		writel(CTRL_ABORT, priv->base + OMAC_MDIO_CTRL);
		dev_err_ratelimited(priv->dev,
				    "command 0x%08x timed out (status 0x%08x)\n",
				    cmd, st);
		return -ETIMEDOUT;
	}
	writel(ST_DONE | ST_CMD_IGN, priv->base + OMAC_MDIO_STATUS);
	if (st & ST_CMD_IGN) {
		dev_err_ratelimited(priv->dev,
				    "command 0x%08x not accepted (status 0x%08x)\n",
				    cmd, st);
		return -EBUSY;
	}
	if (st & ST_BUS_ERR)
		dev_warn_ratelimited(priv->dev,
				     "MDIO did not read back as driven (command 0x%08x)\n",
				     cmd);
	if (val) {
		if (st & ST_TA_ERR)
			*val = 0xffff;	/* nobody answered */
		else
			*val = readl(priv->base + OMAC_MDIO_RDATA) & 0xffff;
	}
	return 0;
}

static int omac_mdio_read(struct mii_bus *bus, int addr, int regnum)
{
	u16 val;
	int ret;

	ret = omac_mdio_xfer(bus->priv,
			     omac_mdio_cmd(OP_C22_READ, 0, addr, regnum), 0, &val);
	return ret ? ret : val;
}

static int omac_mdio_write(struct mii_bus *bus, int addr, int regnum, u16 val)
{
	return omac_mdio_xfer(bus->priv,
			      omac_mdio_cmd(OP_C22_WRITE, 0, addr, regnum), val,
			      NULL);
}

static int omac_mdio_read_c45(struct mii_bus *bus, int addr, int devnum,
			      int regnum)
{
	u16 val;
	int ret;

	ret = omac_mdio_xfer(bus->priv,
			     omac_mdio_cmd(OP_C45_READ, CMD_C45 | CMD_ADDR_FIRST,
					   addr, devnum),
			     FIELD_PREP(WDATA_ADDR, regnum), &val);
	return ret ? ret : val;
}

static int omac_mdio_write_c45(struct mii_bus *bus, int addr, int devnum,
			       int regnum, u16 val)
{
	return omac_mdio_xfer(bus->priv,
			      omac_mdio_cmd(OP_C45_WRITE, CMD_C45 | CMD_ADDR_FIRST,
					    addr, devnum),
			      FIELD_PREP(WDATA_ADDR, regnum) |
			      FIELD_PREP(WDATA_DATA, val), NULL);
}

static int omac_mdio_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct device_node *np = dev->of_node;
	struct omac_mdio *priv;
	struct mii_bus *bus;
	unsigned long rate = 0;
	u32 freq = OMAC_MDIO_DEF_FREQ;
	u32 id, cfg, div, pre;
	struct clk *clk;
	int ret;

	bus = devm_mdiobus_alloc_size(dev, sizeof(*priv));
	if (!bus)
		return -ENOMEM;
	priv = bus->priv;
	priv->dev = dev;

	priv->base = devm_platform_ioremap_resource(pdev, 0);
	if (IS_ERR(priv->base))
		return PTR_ERR(priv->base);

	id = readl(priv->base + OMAC_MDIO_ID);
	if (id != OMAC_MDIO_ID_VALUE)
		return dev_err_probe(dev, -ENODEV, "no omac_mdio core here (ID 0x%08x)\n", id);

	clk = devm_clk_get_optional_enabled(dev, NULL);
	if (IS_ERR(clk))
		return dev_err_probe(dev, PTR_ERR(clk), "cannot get the clock\n");
	if (clk)
		rate = clk_get_rate(clk);

	of_property_read_u32(np, "clock-frequency", &freq);
	priv->timeout_us = OMAC_MDIO_DEF_TIMEOUT;
	of_property_read_u32(np, "opsero,timeout-us", &priv->timeout_us);

	/* a command left over from a previous driver instance or a boot loader */
	if (readl(priv->base + OMAC_MDIO_STATUS) & ST_BUSY)
		writel(CTRL_ABORT, priv->base + OMAC_MDIO_CTRL);
	writel(0, priv->base + OMAC_MDIO_BITBANG);

	cfg = readl(priv->base + OMAC_MDIO_CFG);
	div = FIELD_GET(CFG_DIV, cfg);
	if (rate && freq) {
		div = DIV_ROUND_UP(rate, 2UL * freq);
		div = clamp(div, 1U, 256U) - 1;
	} else if (!rate) {
		dev_dbg(dev, "no clock: MDC divider kept at %u\n", div);
	}
	pre = of_property_read_bool(np, "suppress-preamble") ? 0 : 32;
	cfg = FIELD_PREP(CFG_DIV, div) | FIELD_PREP(CFG_PRE, pre);
	if (of_property_read_bool(np, "opsero,mdc-free-running"))
		cfg |= CFG_MDC_FREE;
	writel(cfg, priv->base + OMAC_MDIO_CFG);
	writel(ST_DONE | ST_CMD_IGN, priv->base + OMAC_MDIO_STATUS);

	bus->name = DRV_NAME;
	snprintf(bus->id, MII_BUS_ID_SIZE, "%s", dev_name(dev));
	bus->parent = dev;
	bus->read = omac_mdio_read;
	bus->write = omac_mdio_write;
	bus->read_c45 = omac_mdio_read_c45;
	bus->write_c45 = omac_mdio_write_c45;
	platform_set_drvdata(pdev, bus);

	ret = devm_of_mdiobus_register(dev, bus, np);
	if (ret)
		return dev_err_probe(dev, ret, "cannot register the MDIO bus\n");

	if (rate)
		dev_info(dev, "MDC %lu Hz (DIV %u), preamble %u bits\n",
			 rate / (2UL * (div + 1)), div, pre);
	else
		dev_info(dev, "MDC = AXI clock / %u, preamble %u bits\n", 2 * (div + 1), pre);
	return 0;
}

static const struct of_device_id omac_mdio_of_match[] = {
	{ .compatible = "opsero,omac-mdio" },
	{ }
};
MODULE_DEVICE_TABLE(of, omac_mdio_of_match);

static struct platform_driver omac_mdio_driver = {
	.probe = omac_mdio_probe,
	.driver = {
		.name = DRV_NAME,
		.of_match_table = omac_mdio_of_match,
	},
};
module_platform_driver(omac_mdio_driver);

MODULE_AUTHOR("Opsero Electronic Design Inc.");
MODULE_DESCRIPTION("MDIO bus driver for the omac_mdio MDIO master (clause 22 and clause 45)");
MODULE_LICENSE("Dual MIT/GPL");
