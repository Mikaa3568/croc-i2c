// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Authors:
// - Your Name

`include "common_cells/registers.svh"

module i2c (
    /// Primary input clock
    input  logic clk_i,
    /// Asynchronous active-low reset
    input  logic rst_ni,

    /// I2C SDA input
    input  logic i2c_sda_i,
    /// I2C SDA output
    output logic i2c_sda_o,
    /// I2C SDA output enable
    output logic i2c_sda_oe,
    /// I2C SCL input
    input  logic i2c_scl_i,
    /// I2C SCL output
    output logic i2c_scl_o,
    /// I2C SCL output enable
    output logic i2c_scl_oe,

    /// Control interface from interconnect (request).
    input  croc_pkg::sbr_obi_req_t obi_req_i,
    /// Control interface back into interconnect (response).
    output croc_pkg::sbr_obi_rsp_t obi_rsp_o
);

  // Simple register for now
  logic [7:0] data_reg;
  logic [31:0] rdata;
  logic rvalid;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rdata <= 0;
      rvalid <= 0;
      data_reg <= 0;
    end else begin
      rvalid <= obi_req_i.req;
      if (obi_req_i.req) begin
        if (obi_req_i.a.we) begin
          if (obi_req_i.a.addr[3:0] == 4'h0) begin
            data_reg <= obi_req_i.a.wdata[7:0];
          end
        end else begin
          if (obi_req_i.a.addr[3:0] == 4'h0) begin
            rdata <= {24'b0, data_reg};
          end else begin
            rdata <= 32'hDEADBEEF; // Status
          end
        end
      end
    end
  end

  assign obi_rsp_o.r.rdata = rdata;
  assign obi_rsp_o.gnt = obi_req_i.req;
  assign obi_rsp_o.rvalid = rvalid;

  // I2C pins not used yet
  assign i2c_sda_o = 1'b0;
  assign i2c_sda_oe = 1'b0;
  assign i2c_scl_o = 1'b0;
  assign i2c_scl_oe = 1'b0;

endmodule