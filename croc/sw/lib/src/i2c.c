// Copyright 2024 ETH Zurich and University of Bologna.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

#include "i2c.h"

void i2c_init(uint16_t prescaler) {
    // Disable core before changing prescaler
    *reg32(I2C_BASE_ADDR, I2C_CTRL_OFFSET) = 0;

    // Write 16-bit prescaler (low byte first, then high byte)
    *reg32(I2C_BASE_ADDR, I2C_PRESCALE_OFFSET)    = prescaler & 0xFFu;
    *reg32(I2C_BASE_ADDR, I2C_PRESCALE_HI_OFFSET) = (prescaler >> 8) & 0xFFu;

    // Enable core + interrupt enable
    *reg32(I2C_BASE_ADDR, I2C_CTRL_OFFSET) = I2C_CTRL_EN | I2C_CTRL_IEN;
}

void i2c_disable(void) {
    *reg32(I2C_BASE_ADDR, I2C_CTRL_OFFSET) = 0;
}
