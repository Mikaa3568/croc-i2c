// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Your Name

package i2c_reg_pkg;

  // Register structs
  typedef struct packed {
    logic [7:0] data;
  } i2c_reg2hw_t;

  typedef struct packed {
    logic [7:0] data;
  } i2c_hw2reg_t;

endpackage