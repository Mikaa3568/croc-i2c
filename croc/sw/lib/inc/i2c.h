// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <stdint.h>
#include "config.h"
#include "util.h"

// ---------------------------------------------------------------------------
// Register byte offsets  (waddr = addr[4:1], so word-step = 0x04)
// ---------------------------------------------------------------------------
#define I2C_PRESCALE_OFFSET   0x00   // [7:0]  SCL prescaler low byte  (R/W)
#define I2C_PRESCALE_HI_OFFSET 0x04  // [7:0]  SCL prescaler high byte (R/W)
#define I2C_CTRL_OFFSET       0x08   // [7]=EN [6]=IEN                  (R/W)
#define I2C_TX_DATA_OFFSET    0x0C   // [7:0]  transmit data            (W / readback R)
#define I2C_CMD_OFFSET        0x10   // [7:0]  command register         (W only)
#define I2C_RX_DATA_OFFSET    0x10   // [7:0]  received byte            (R only)
#define I2C_STATUS_OFFSET     0x14   // [7:0]  status register          (R only)

// ---------------------------------------------------------------------------
// CTR control register bits
// ---------------------------------------------------------------------------
#define I2C_CTRL_EN   (1u << 7)   // core enable
#define I2C_CTRL_IEN  (1u << 6)   // interrupt enable

// ---------------------------------------------------------------------------
// CR command register bits  (write to I2C_CMD_OFFSET)
// ---------------------------------------------------------------------------
#define I2C_CMD_START  (1u << 7)  // generate START condition
#define I2C_CMD_STOP   (1u << 6)  // generate STOP condition
#define I2C_CMD_READ   (1u << 5)  // read byte from slave
#define I2C_CMD_WRITE  (1u << 4)  // write byte to slave
#define I2C_CMD_ACK    (1u << 3)  // ACK control: 0=send ACK, 1=send NACK
#define I2C_CMD_IACK   (1u << 0)  // interrupt acknowledge (clears SR.IF)

// ---------------------------------------------------------------------------
// SR status register bits  (read from I2C_STATUS_OFFSET)
// ---------------------------------------------------------------------------
#define I2C_STATUS_RXACK  (1u << 7)  // 0=slave ACKed, 1=slave NACKed
#define I2C_STATUS_BUSY   (1u << 6)  // bus busy (between START and STOP)
#define I2C_STATUS_AL     (1u << 5)  // arbitration lost
#define I2C_STATUS_TIP    (1u << 1)  // transfer in progress
#define I2C_STATUS_IF     (1u << 0)  // interrupt flag (byte done)

// ---------------------------------------------------------------------------
// Address byte helpers
// ---------------------------------------------------------------------------
#define I2C_WRITE_BIT  0u   // bit0=0  → write transaction
#define I2C_READ_BIT   1u   // bit0=1  → read transaction

// ---------------------------------------------------------------------------
// API  (implemented in lib/src/i2c.c)
// ---------------------------------------------------------------------------

/**
 * Initialize I2C master.
 * @param prescaler  16-bit SCL divider.
 *   SCL = clk_freq / (2 * (prescaler + 1))
 *   e.g. 20 MHz, 100 kHz: prescaler = 99
 *        20 MHz, 400 kHz: prescaler = 24
 *   For simulation at TB_FREQUENCY=20 MHz targeting 100 kHz: use 39
 *   (5 * (39+1) = 200 → 20MHz/200 = 100kHz; slightly relaxed for sim)
 */
void i2c_init(uint16_t prescaler);

/** Disable I2C core (clear CTR). */
void i2c_disable(void);
