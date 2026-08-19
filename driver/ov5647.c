// SPDX-License-Identifier: GPL-2.0
/*
 * ov5647.c - OV5647 sensor driver for NVIDIA Tegra (Jetson family)
 *
 * Brings the OmniVision OV5647 (Raspberry Pi Camera Module v1) into the
 * NVIDIA tegracam framework so the full camera stack works: VI/CSI capture,
 * hardware ISP via nvarguscamerasrc, V4L2 raw Bayer.
 *
 * Builds against L4T R32.x (kernel 4.9), R35.x (kernel 5.10) and
 * JetPack 7 (kernel 6.x, nvidia-public OOT headers). The tegracam
 * entry points this driver uses are the same across those releases;
 * what differs is stock kernel API drift and, on JetPack 7, a
 * conftest-gated field in struct camera_common_data (see compat/).
 *
 * Copyright (C) 2026 Artur Andrzejczak <andrzejczak.artur@gmail.com>
 *   - tegracam port, multi-board Jetson support (Nano, Xavier NX, Orin)
 * Copyright (c) 2015-2020, NVIDIA CORPORATION
 *   - tegracam driver structure, modeled on imx219.c (GPL-2.0)
 * Copyright (C) 2016, Synopsys, Inc.
 *   - OV5647 register sequences from the mainline ov5647.c (GPL-2.0),
 *     driver by Ramiro Oliveira
 */

#include <linux/bitfield.h>
#include <linux/debugfs.h>
#include <linux/mutex.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/gpio.h>
#include <linux/module.h>
#include <linux/seq_file.h>
#include <linux/of.h>
#include <linux/of_device.h>
#include <linux/of_gpio.h>
#include <linux/version.h>

#include <media/tegra_v4l2_camera.h>
#include <media/tegracam_core.h>

#include "ov5647_mode_tbls.h"

/* sensor parameter limits */
#define OV5647_MIN_GAIN			16	/* 1.0x, gain_factor 16 */
#define OV5647_MAX_GAIN			1023	/* ~64x analog */
#define OV5647_MAX_FRAME_LENGTH		0xffff
#define OV5647_MIN_COARSE_EXPOSURE	4
#define OV5647_COARSE_EXP_MARGIN	8	/* lines below frame length */

/* sensor registers */
#define OV5647_REG_CHIPID_H		0x300a
#define OV5647_REG_CHIPID_L		0x300b
#define OV5647_CHIPID_H			0x56
#define OV5647_CHIPID_L			0x47
#define OV5647_REG_EXP_HI		0x3500
#define OV5647_REG_EXP_MID		0x3501
#define OV5647_REG_EXP_LO		0x3502
#define OV5647_REG_GAIN_HI		0x350a
#define OV5647_REG_GAIN_LO		0x350b
#define OV5647_REG_VTS_HI		0x380e
#define OV5647_REG_VTS_LO		0x380f
#define OV5647_REG_GROUP_ACCESS		0x3208
#define OV5647_GROUP_CTRL		GENMASK(7, 4)
#define OV5647_GROUP_CTRL_ENTER		0x0
#define OV5647_GROUP_CTRL_EXIT		0x1
#define OV5647_GROUP_CTRL_LAUNCH	0xa
#define OV5647_GROUP_ID			GENMASK(3, 0)
/* One group is enough: the sensor buffers 16 registers per group and a
 * control update writes at most seven (exposure 3, gain 2, VTS 2).
 */
#define OV5647_CTRL_GROUP		0

/* Nominal VTS (frame length in lines) per sensor mode, from the mainline
 * mode definitions; the register sequences leave VTS at its reset default,
 * so set_mode programs these. They also serve as the frame-rate control's
 * lower bound, which keeps every mode at or below its nominal rate. Only
 * the 2x2-binned 1296x972 mode has real room below it; the others sit 24
 * lines above their active height.
 *
 * Indexed by the driver's own mode enum (s_data->mode), like mode_table[].
 * Device-tree properties are indexed separately by s_data->mode_prop_idx,
 * which walks the DT modeX nodes; the two agree only because frmfmt[] is
 * kept in the same order as those nodes (see ov5647_mode_tbls.h).
 */
static const u32 ov5647_min_vts[] = {
	[OV5647_MODE_2592x1944_15FPS] = 1968,
	[OV5647_MODE_1920x1080_30FPS] = 1104,
	[OV5647_MODE_1296x972_30FPS] = 1435,
	[OV5647_MODE_640x480_62FPS] = 504,
};

static const struct of_device_id ov5647_of_match[] = {
	{ .compatible = "nvidia,ov5647", },
	{ },
};
MODULE_DEVICE_TABLE(of, ov5647_of_match);

static const u32 ctrl_cid_list[] = {
	TEGRA_CAMERA_CID_GAIN,
	TEGRA_CAMERA_CID_EXPOSURE,
	TEGRA_CAMERA_CID_FRAME_RATE,
	TEGRA_CAMERA_CID_SENSOR_MODE_ID,
};

struct ov5647 {
	struct i2c_client		*i2c_client;
	struct v4l2_subdev		*subdev;
	u32				frame_length;
	bool				pwdn_gpio_owned;
	struct camera_common_data	*s_data;
	struct tegracam_device		*tc_dev;
	struct dentry			*debugfs_dir;
	struct mutex			debugfs_lock;
	u16				debugfs_addr;
};

/* Register ranges worth dumping, named after what they drive. Reading the
 * whole 0x0000-0xffff space would be thousands of I2C transfers for pages
 * the sensor does not implement.
 */
static const struct ov5647_reg_bank {
	u16		first;
	u16		last;
	const char	*name;
} ov5647_reg_banks[] = {
	{ 0x3000, 0x3040, "system and clocks" },
	{ 0x3200, 0x320c, "group access" },
	{ 0x3500, 0x350c, "AEC and AGC" },
	{ 0x3800, 0x3821, "timing and windowing" },
	{ 0x4000, 0x4010, "black level" },
	{ 0x4800, 0x4837, "MIPI" },
	{ 0x5000, 0x5003, "ISP control" },
	{ 0x503d, 0x503e, "test pattern" },
};

/* Probe-time handoff: set by power_get (which the framework calls before
 * tegracam privdata exists) and copied into the ov5647 struct by probe.
 * Safe because the driver core serializes probes of this driver (no
 * PROBE_PREFER_ASYNCHRONOUS). */
static bool ov5647_last_gpio_owned;

static const struct regmap_config sensor_regmap_config = {
	.reg_bits = 16,
	.val_bits = 8,
	.cache_type = REGCACHE_RBTREE,
#if LINUX_VERSION_CODE < KERNEL_VERSION(4, 20, 0)
	.use_single_rw = true,
#else
	.use_single_read = true,
	.use_single_write = true,
#endif
};

static inline int ov5647_read_reg(struct camera_common_data *s_data,
	u16 addr, u8 *val)
{
	int err = 0;
	u32 reg_val = 0;

	err = regmap_read(s_data->regmap, addr, &reg_val);
	*val = reg_val & 0xff;

	return err;
}

static inline int ov5647_write_reg(struct camera_common_data *s_data,
	u16 addr, u8 val)
{
	int err = 0;

	err = regmap_write(s_data->regmap, addr, val);
	if (err)
		dev_err(s_data->dev, "%s: i2c write failed, 0x%x = 0x%x\n",
			__func__, addr, val);

	return err;
}

static int ov5647_write_table(struct ov5647 *priv, const ov5647_reg table[])
{
	return regmap_util_write_table_8(priv->s_data->regmap, table, NULL, 0,
		OV5647_TABLE_WAIT_MS, OV5647_TABLE_END);
}

static int ov5647_group_access(struct camera_common_data *s_data, u8 ctrl)
{
	return ov5647_write_reg(s_data, OV5647_REG_GROUP_ACCESS,
				FIELD_PREP(OV5647_GROUP_CTRL, ctrl) |
				FIELD_PREP(OV5647_GROUP_ID, OV5647_CTRL_GROUP));
}

/* Without this, a multi-register control update applies byte by byte and can
 * straddle a frame boundary, exposing one frame with a mixed value. Held
 * writes go to the group's SRAM instead and reach the sensor together when
 * the group is launched.
 */
/* Register access from userspace. The sensor only answers over I2C while it
 * is powered, which tegracam does around streaming, so every entry point
 * checks that first: poking a powered-down sensor wedges the I2C bus rather
 * than returning an error. Reads bypass the regmap cache, since the point of
 * looking is to see what the sensor actually holds.
 */
static int ov5647_dbg_read(struct ov5647 *priv, u16 addr, u8 *val)
{
	struct camera_common_data *s_data = priv->s_data;
	int err;

	if (s_data->power->state != SWITCH_ON)
		return -ENODEV;

	regcache_cache_bypass(s_data->regmap, true);
	err = ov5647_read_reg(s_data, addr, val);
	regcache_cache_bypass(s_data->regmap, false);

	return err;
}

static int ov5647_dbg_regs_show(struct seq_file *s, void *unused)
{
	struct ov5647 *priv = s->private;
	unsigned int i;
	u16 addr;
	u8 val;
	int err;

	mutex_lock(&priv->debugfs_lock);

	if (priv->s_data->power->state != SWITCH_ON) {
		seq_puts(s, "sensor is powered off, start a capture first\n");
		mutex_unlock(&priv->debugfs_lock);
		return 0;
	}

	for (i = 0; i < ARRAY_SIZE(ov5647_reg_banks); i++) {
		seq_printf(s, "# %s\n", ov5647_reg_banks[i].name);
		for (addr = ov5647_reg_banks[i].first;
		     addr <= ov5647_reg_banks[i].last; addr++) {
			err = ov5647_dbg_read(priv, addr, &val);
			if (err) {
				seq_printf(s, "0x%04x read failed (%d)\n",
					   addr, err);
				break;
			}
			seq_printf(s, "0x%04x 0x%02x\n", addr, val);
		}
	}

	mutex_unlock(&priv->debugfs_lock);

	return 0;
}

static int ov5647_dbg_regs_open(struct inode *inode, struct file *file)
{
	return single_open(file, ov5647_dbg_regs_show, inode->i_private);
}

static const struct file_operations ov5647_dbg_regs_fops = {
	.owner		= THIS_MODULE,
	.open		= ov5647_dbg_regs_open,
	.read		= seq_read,
	.llseek		= seq_lseek,
	.release	= single_release,
};

/* Reading gives the selected register, writing takes "<addr>" to select one
 * or "<addr> <value>" to set it, both hex.
 */
static int ov5647_dbg_reg_show(struct seq_file *s, void *unused)
{
	struct ov5647 *priv = s->private;
	u8 val;
	int err;

	mutex_lock(&priv->debugfs_lock);
	err = ov5647_dbg_read(priv, priv->debugfs_addr, &val);
	if (!err)
		seq_printf(s, "0x%04x 0x%02x\n", priv->debugfs_addr, val);
	else if (err == -ENODEV)
		seq_puts(s, "sensor is powered off, start a capture first\n");
	mutex_unlock(&priv->debugfs_lock);

	return err == -ENODEV ? 0 : err;
}

static int ov5647_dbg_reg_open(struct inode *inode, struct file *file)
{
	return single_open(file, ov5647_dbg_reg_show, inode->i_private);
}

static ssize_t ov5647_dbg_reg_write(struct file *file, const char __user *ubuf,
				    size_t count, loff_t *ppos)
{
	struct ov5647 *priv = ((struct seq_file *)file->private_data)->private;
	unsigned int addr, val;
	char buf[32];
	int fields, err;

	if (count == 0 || count >= sizeof(buf))
		return -EINVAL;
	if (copy_from_user(buf, ubuf, count))
		return -EFAULT;
	buf[count] = '\0';

	fields = sscanf(buf, "%x %x", &addr, &val);
	if (fields < 1 || addr > 0xffff)
		return -EINVAL;

	mutex_lock(&priv->debugfs_lock);
	priv->debugfs_addr = addr;

	if (fields == 1) {
		mutex_unlock(&priv->debugfs_lock);
		return count;
	}

	if (val > 0xff) {
		mutex_unlock(&priv->debugfs_lock);
		return -EINVAL;
	}
	if (priv->s_data->power->state != SWITCH_ON) {
		mutex_unlock(&priv->debugfs_lock);
		return -ENODEV;
	}

	err = ov5647_write_reg(priv->s_data, addr, val);
	mutex_unlock(&priv->debugfs_lock);

	return err ? err : count;
}

static const struct file_operations ov5647_dbg_reg_fops = {
	.owner		= THIS_MODULE,
	.open		= ov5647_dbg_reg_open,
	.read		= seq_read,
	.write		= ov5647_dbg_reg_write,
	.llseek		= seq_lseek,
	.release	= single_release,
};

static void ov5647_debugfs_init(struct ov5647 *priv)
{
	char name[32];

	mutex_init(&priv->debugfs_lock);
	priv->debugfs_addr = OV5647_REG_CHIPID_H;

	snprintf(name, sizeof(name), "ov5647-%s",
		 dev_name(&priv->i2c_client->dev));
	priv->debugfs_dir = debugfs_create_dir(name, NULL);
	if (IS_ERR_OR_NULL(priv->debugfs_dir)) {
		priv->debugfs_dir = NULL;
		return;
	}

	debugfs_create_file("regs", 0400, priv->debugfs_dir, priv,
			    &ov5647_dbg_regs_fops);
	debugfs_create_file("reg", 0600, priv->debugfs_dir, priv,
			    &ov5647_dbg_reg_fops);
}

static void ov5647_debugfs_remove(struct ov5647 *priv)
{
	debugfs_remove_recursive(priv->debugfs_dir);
	priv->debugfs_dir = NULL;
}

static int ov5647_set_group_hold(struct tegracam_device *tc_dev, bool val)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	int err;

	if (val)
		return ov5647_group_access(s_data, OV5647_GROUP_CTRL_ENTER);

	err = ov5647_group_access(s_data, OV5647_GROUP_CTRL_EXIT);
	if (err)
		return err;

	return ov5647_group_access(s_data, OV5647_GROUP_CTRL_LAUNCH);
}

static int ov5647_set_gain(struct tegracam_device *tc_dev, s64 val)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct device *dev = s_data->dev;
	const struct sensor_mode_properties *mode =
		&s_data->sensor_props.sensor_modes[s_data->mode_prop_idx];
	int err = 0;
	s64 gain;

	if (!mode->control_properties.gain_factor) {
		dev_err(dev, "%s: device tree gain_factor is zero\n", __func__);
		return -EINVAL;
	}

	if (val < mode->control_properties.min_gain_val)
		val = mode->control_properties.min_gain_val;
	else if (val > mode->control_properties.max_gain_val)
		val = mode->control_properties.max_gain_val;

	/* gain_factor is 16 in DT, and 1.0x = 16 in the sensor register,
	 * so the normalized control value maps 1:1 to the register. */
	gain = val * 16 / mode->control_properties.gain_factor;

	if (gain < OV5647_MIN_GAIN)
		gain = OV5647_MIN_GAIN;
	else if (gain > OV5647_MAX_GAIN)
		gain = OV5647_MAX_GAIN;

	dev_dbg(dev, "%s: val: %lld (/%d) [times], reg: %lld\n",
		__func__, val, mode->control_properties.gain_factor, gain);

	err = ov5647_write_reg(s_data, OV5647_REG_GAIN_HI, (gain >> 8) & 0x03);
	if (!err)
		err = ov5647_write_reg(s_data, OV5647_REG_GAIN_LO, gain & 0xff);
	if (err)
		dev_dbg(dev, "%s: gain control error\n", __func__);

	return err;
}

static int ov5647_set_frame_rate(struct tegracam_device *tc_dev, s64 val)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct ov5647 *priv = (struct ov5647 *)tc_dev->priv;
	struct device *dev = tc_dev->dev;
	const struct sensor_mode_properties *mode =
		&s_data->sensor_props.sensor_modes[s_data->mode_prop_idx];
	int err = 0;
	u32 frame_length;
	u32 min_vts;

	if (!val || !mode->image_properties.line_length) {
		dev_err(dev, "%s: bad frame rate %lld or line length %u\n",
			__func__, val, mode->image_properties.line_length);
		return -EINVAL;
	}

	frame_length = (u32)(mode->signal_properties.pixel_clock.val *
		(u64)mode->control_properties.framerate_factor /
		mode->image_properties.line_length / val);

	min_vts = ov5647_min_vts[s_data->mode];
	if (frame_length < min_vts)
		frame_length = min_vts;
	else if (frame_length > OV5647_MAX_FRAME_LENGTH)
		frame_length = OV5647_MAX_FRAME_LENGTH;

	dev_dbg(dev, "%s: val: %llde-6 [fps], frame_length: %u [lines]\n",
		__func__, val, frame_length);

	err = ov5647_write_reg(s_data, OV5647_REG_VTS_HI,
		(frame_length >> 8) & 0xff);
	if (!err)
		err = ov5647_write_reg(s_data, OV5647_REG_VTS_LO,
			frame_length & 0xff);
	if (err) {
		dev_dbg(dev, "%s: frame_length control error\n", __func__);
		return err;
	}

	priv->frame_length = frame_length;

	return 0;
}

static int ov5647_set_exposure(struct tegracam_device *tc_dev, s64 val)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct ov5647 *priv = (struct ov5647 *)tc_dev->priv;
	struct device *dev = tc_dev->dev;
	const struct sensor_mode_properties *mode =
		&s_data->sensor_props.sensor_modes[s_data->mode_prop_idx];
	int err = 0;
	u32 coarse_time;
	s32 max_coarse_time;

	if (!mode->control_properties.exposure_factor ||
	    !mode->image_properties.line_length) {
		dev_err(dev, "%s: bad device tree exposure_factor %u or line length %u\n",
			__func__, mode->control_properties.exposure_factor,
			mode->image_properties.line_length);
		return -EINVAL;
	}

	if (!priv->frame_length)
		priv->frame_length = ov5647_min_vts[s_data->mode];

	max_coarse_time = priv->frame_length - OV5647_COARSE_EXP_MARGIN;

	/* val is in us (exposure_factor 1000000): lines = us * pixclk / f / llp */
	coarse_time = (u32)(val * mode->signal_properties.pixel_clock.val /
		mode->control_properties.exposure_factor /
		mode->image_properties.line_length);

	if (coarse_time < OV5647_MIN_COARSE_EXPOSURE)
		coarse_time = OV5647_MIN_COARSE_EXPOSURE;
	else if (coarse_time > max_coarse_time) {
		coarse_time = max_coarse_time;
		dev_dbg(dev,
			"%s: exposure limited by frame_length: %d [lines]\n",
			__func__, max_coarse_time);
	}

	dev_dbg(dev, "%s: val: %lld [us], coarse_time: %d [lines]\n",
		__func__, val, coarse_time);

	/* 20-bit register value, bottom 4 bits are line fractions (zero) */
	err = ov5647_write_reg(s_data, OV5647_REG_EXP_HI,
		(coarse_time >> 12) & 0x0f);
	if (!err)
		err = ov5647_write_reg(s_data, OV5647_REG_EXP_MID,
			(coarse_time >> 4) & 0xff);
	if (!err)
		err = ov5647_write_reg(s_data, OV5647_REG_EXP_LO,
			(coarse_time << 4) & 0xf0);
	if (err)
		dev_dbg(dev, "%s: coarse_time control error\n", __func__);

	return err;
}

static struct tegracam_ctrl_ops ov5647_ctrl_ops = {
	.numctrls = ARRAY_SIZE(ctrl_cid_list),
	.ctrl_cid_list = ctrl_cid_list,
	.set_gain = ov5647_set_gain,
	.set_exposure = ov5647_set_exposure,
	.set_frame_rate = ov5647_set_frame_rate,
	.set_group_hold = ov5647_set_group_hold,
};

static void ov5647_gpio_set(unsigned int gpio, int val)
{
#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 5, 0)
	/* legacy gpio_cansleep() is gone since v6.5; power on/off runs in
	 * process context, where the cansleep variant is always safe */
	gpio_set_value_cansleep(gpio, val);
#else
	if (gpio_cansleep(gpio))
		gpio_set_value_cansleep(gpio, val);
	else
		gpio_set_value(gpio, val);
#endif
}

static int ov5647_power_on(struct camera_common_data *s_data)
{
	int err = 0;
	struct camera_common_power_rail *pw = s_data->power;
	struct camera_common_pdata *pdata = s_data->pdata;
	struct device *dev = s_data->dev;

	dev_dbg(dev, "%s: power on\n", __func__);
	if (pdata && pdata->power_on) {
		err = pdata->power_on(pw);
		if (err)
			dev_err(dev, "%s failed.\n", __func__);
		else
			pw->state = SWITCH_ON;
		return err;
	}

	/* The Pi Camera v1 module gates its onboard regulators with the
	 * connector's PWDN line (our "reset" gpio, active high). The
	 * sensor runs from the module's own 25 MHz oscillator. */
	if (pw->reset_gpio)
		ov5647_gpio_set(pw->reset_gpio, 1);

	/* module power-up + sensor boot time */
	usleep_range(25000, 26000);

	pw->state = SWITCH_ON;

	return 0;
}

static int ov5647_power_off(struct camera_common_data *s_data)
{
	int err = 0;
	struct camera_common_power_rail *pw = s_data->power;
	struct camera_common_pdata *pdata = s_data->pdata;
	struct device *dev = s_data->dev;

	dev_dbg(dev, "%s: power off\n", __func__);

	if (pdata && pdata->power_off) {
		err = pdata->power_off(pw);
		if (err) {
			dev_err(dev, "%s failed.\n", __func__);
			return err;
		}
	} else {
		if (pw->reset_gpio)
			ov5647_gpio_set(pw->reset_gpio, 0);
	}

	pw->state = SWITCH_OFF;

	return 0;
}

static int ov5647_power_put(struct tegracam_device *tc_dev)
{
	struct camera_common_data *s_data = tc_dev->s_data;
	struct camera_common_power_rail *pw = s_data->power;
	struct ov5647 *priv = (struct ov5647 *)tegracam_get_privdata(tc_dev);
	bool owned = priv ? priv->pwdn_gpio_owned : ov5647_last_gpio_owned;

	if (unlikely(!pw))
		return -EFAULT;

	/* Only free the gpio if our request owned it. Where a carrier DT
	 * hogs the pin, freeing would release the hog's request instead of
	 * ours. Before probe stores privdata, ownership is still in the
	 * probe-time handoff variable. */
	if (pw->reset_gpio && owned)
		gpio_free(pw->reset_gpio);

	return 0;
}

static int ov5647_power_get(struct tegracam_device *tc_dev)
{
	struct device *dev = tc_dev->dev;
	struct camera_common_data *s_data = tc_dev->s_data;
	struct camera_common_power_rail *pw = s_data->power;
	struct camera_common_pdata *pdata = s_data->pdata;
	int err = 0;

	if (!pdata) {
		dev_err(dev, "pdata missing\n");
		return -EFAULT;
	}

	/* PWDN / enable gpio. Some carrier DTs hog camera control pins,
	 * which makes this request fail with -EBUSY. The hog keeps the
	 * descriptor requested, which is enough for gpio_set_value, so
	 * proceed without ownership; NVIDIA's stock sensor drivers behave
	 * the same way. */
	pw->reset_gpio = pdata->reset_gpio;
	err = gpio_request(pw->reset_gpio, "cam_pwdn_gpio");
	ov5647_last_gpio_owned = (err == 0);
	if (err == -EBUSY) {
		dev_info(dev, "%s: pwdn gpio %u busy (DT hog?), continuing\n",
			__func__, pw->reset_gpio);
		err = 0;
	} else if (err < 0) {
		dev_err(dev, "%s: unable to request pwdn_gpio (%d)\n",
			__func__, err);
	}

	pw->state = SWITCH_OFF;

	return err;
}

static struct camera_common_pdata *ov5647_parse_dt(
	struct tegracam_device *tc_dev)
{
	struct device *dev = tc_dev->dev;
	struct device_node *np = dev->of_node;
	struct camera_common_pdata *board_priv_pdata;
	const struct of_device_id *match;
	struct camera_common_pdata *ret = NULL;
	int gpio;

	if (!np)
		return NULL;

	match = of_match_device(ov5647_of_match, dev);
	if (!match) {
		dev_err(dev, "Failed to find matching dt id\n");
		return NULL;
	}

	board_priv_pdata = devm_kzalloc(dev,
		sizeof(*board_priv_pdata), GFP_KERNEL);
	if (!board_priv_pdata)
		return NULL;

	gpio = of_get_named_gpio(np, "reset-gpios", 0);
	if (gpio < 0) {
		if (gpio == -EPROBE_DEFER)
			ret = ERR_PTR(-EPROBE_DEFER);
		else
			dev_err(dev, "reset-gpios not found\n");
		goto error;
	}
	board_priv_pdata->reset_gpio = (unsigned int)gpio;

	/* no mclk: the camera module has its own 25 MHz oscillator */
	/* no regulators: module powered from the always-on 3V3 rail */

	return board_priv_pdata;

error:
	devm_kfree(dev, board_priv_pdata);

	return ret;
}

static int ov5647_set_mode(struct tegracam_device *tc_dev)
{
	struct ov5647 *priv = (struct ov5647 *)tegracam_get_privdata(tc_dev);
	struct camera_common_data *s_data = tc_dev->s_data;
	u32 vts;
	int err = 0;

	err = ov5647_write_table(priv, mode_table[s_data->mode]);
	if (err)
		return err;

	/* The register tables (from mainline) leave VTS at the sensor reset
	 * default; program the mode's nominal frame length explicitly. */
	vts = ov5647_min_vts[s_data->mode];
	err = ov5647_write_reg(s_data, OV5647_REG_VTS_HI, (vts >> 8) & 0xff);
	if (!err)
		err = ov5647_write_reg(s_data, OV5647_REG_VTS_LO, vts & 0xff);
	if (err)
		return err;

	priv->frame_length = vts;

	return 0;
}

static int ov5647_start_streaming(struct tegracam_device *tc_dev)
{
	struct ov5647 *priv = (struct ov5647 *)tegracam_get_privdata(tc_dev);

	return ov5647_write_table(priv, ov5647_start_stream);
}

static int ov5647_stop_streaming(struct tegracam_device *tc_dev)
{
	int err;
	struct ov5647 *priv = (struct ov5647 *)tegracam_get_privdata(tc_dev);

	err = ov5647_write_table(priv, ov5647_stop_stream);

	usleep_range(50000, 51000);

	return err;
}

static struct camera_common_sensor_ops ov5647_common_ops = {
	.numfrmfmts = ARRAY_SIZE(ov5647_frmfmt),
	.frmfmt_table = ov5647_frmfmt,
	.power_on = ov5647_power_on,
	.power_off = ov5647_power_off,
	.write_reg = ov5647_write_reg,
	.read_reg = ov5647_read_reg,
	.parse_dt = ov5647_parse_dt,
	.power_get = ov5647_power_get,
	.power_put = ov5647_power_put,
	.set_mode = ov5647_set_mode,
	.start_streaming = ov5647_start_streaming,
	.stop_streaming = ov5647_stop_streaming,
};

static int ov5647_board_setup(struct ov5647 *priv)
{
	struct camera_common_data *s_data = priv->s_data;
	struct device *dev = s_data->dev;
	u8 reg_val[2];
	int err = 0;

	err = ov5647_power_on(s_data);
	if (err) {
		dev_err(dev, "error during power on sensor (%d)\n", err);
		return err;
	}

	/* probe sensor chip id registers */
	err = ov5647_read_reg(s_data, OV5647_REG_CHIPID_H, &reg_val[0]);
	if (err) {
		dev_err(dev, "%s: error during i2c read probe (%d)\n",
			__func__, err);
		goto err_reg_probe;
	}
	err = ov5647_read_reg(s_data, OV5647_REG_CHIPID_L, &reg_val[1]);
	if (err) {
		dev_err(dev, "%s: error during i2c read probe (%d)\n",
			__func__, err);
		goto err_reg_probe;
	}
	if (!(reg_val[0] == OV5647_CHIPID_H && reg_val[1] == OV5647_CHIPID_L)) {
		dev_err(dev, "%s: invalid sensor chip id: 0x%02x%02x\n",
			__func__, reg_val[0], reg_val[1]);
		err = -ENODEV;
	} else {
		dev_info(dev, "OV5647 detected (chip id 0x%02x%02x)\n",
			reg_val[0], reg_val[1]);
	}

err_reg_probe:
	ov5647_power_off(s_data);

	return err;
}

static int ov5647_open(struct v4l2_subdev *sd, struct v4l2_subdev_fh *fh)
{
	struct i2c_client *client = v4l2_get_subdevdata(sd);

	dev_dbg(&client->dev, "%s:\n", __func__);

	return 0;
}

static const struct v4l2_subdev_internal_ops ov5647_subdev_internal_ops = {
	.open = ov5647_open,
};

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 3, 0)
static int ov5647_probe(struct i2c_client *client)
#else
static int ov5647_probe(struct i2c_client *client,
	const struct i2c_device_id *id)
#endif
{
	struct device *dev = &client->dev;
	struct tegracam_device *tc_dev;
	struct ov5647 *priv;
	int err;

	dev_dbg(dev, "probing v4l2 sensor at addr 0x%02x\n", client->addr);

	if (!IS_ENABLED(CONFIG_OF) || !client->dev.of_node)
		return -EINVAL;

	priv = devm_kzalloc(dev, sizeof(struct ov5647), GFP_KERNEL);
	if (!priv)
		return -ENOMEM;

	tc_dev = devm_kzalloc(dev, sizeof(struct tegracam_device), GFP_KERNEL);
	if (!tc_dev)
		return -ENOMEM;

	priv->i2c_client = tc_dev->client = client;
	tc_dev->dev = dev;
	strncpy(tc_dev->name, "ov5647", sizeof(tc_dev->name));
	tc_dev->dev_regmap_config = &sensor_regmap_config;
	tc_dev->sensor_ops = &ov5647_common_ops;
	tc_dev->v4l2sd_internal_ops = &ov5647_subdev_internal_ops;
	tc_dev->tcctrl_ops = &ov5647_ctrl_ops;

	err = tegracam_device_register(tc_dev);
	if (err) {
		dev_err(dev, "tegra camera driver registration failed\n");
		return err;
	}
	priv->tc_dev = tc_dev;
	priv->s_data = tc_dev->s_data;
	priv->subdev = &tc_dev->s_data->subdev;
	priv->pwdn_gpio_owned = ov5647_last_gpio_owned;
	tegracam_set_privdata(tc_dev, (void *)priv);

	/* Our mode tables issue a software reset, wiping any control values
	 * applied before streamon; have tegracam re-apply current controls
	 * after set_mode (tegracam_ctrl_set_overrides). */
	tc_dev->s_data->override_enable = true;

	err = ov5647_board_setup(priv);
	if (err) {
		tegracam_device_unregister(tc_dev);
		dev_err(dev, "board setup failed\n");
		return err;
	}

	err = tegracam_v4l2subdev_register(tc_dev, true);
	if (err) {
		dev_err(dev, "tegra camera subdev registration failed\n");
		tegracam_device_unregister(tc_dev);
		return err;
	}

	ov5647_debugfs_init(priv);

	dev_info(dev, "detected ov5647 sensor\n");

	return 0;
}

#if LINUX_VERSION_CODE >= KERNEL_VERSION(6, 1, 0)
static void ov5647_remove(struct i2c_client *client)
#else
static int ov5647_remove(struct i2c_client *client)
#endif
{
	struct camera_common_data *s_data = to_camera_common_data(&client->dev);
	struct ov5647 *priv = (struct ov5647 *)s_data->priv;

	ov5647_debugfs_remove(priv);
	tegracam_v4l2subdev_unregister(priv->tc_dev);
	tegracam_device_unregister(priv->tc_dev);

#if LINUX_VERSION_CODE < KERNEL_VERSION(6, 1, 0)
	return 0;
#endif
}

static const struct i2c_device_id ov5647_id[] = {
	{ "ov5647", 0 },
	{ }
};
MODULE_DEVICE_TABLE(i2c, ov5647_id);

static struct i2c_driver ov5647_i2c_driver = {
	.driver = {
		.name = "ov5647",
		.owner = THIS_MODULE,
		.of_match_table = of_match_ptr(ov5647_of_match),
	},
	.probe = ov5647_probe,
	.remove = ov5647_remove,
	.id_table = ov5647_id,
};
module_i2c_driver(ov5647_i2c_driver);

MODULE_DESCRIPTION("Media Controller driver for OmniVision OV5647 on Tegra");
MODULE_AUTHOR("Artur Andrzejczak <andrzejczak.artur@gmail.com>");
MODULE_LICENSE("GPL v2");
