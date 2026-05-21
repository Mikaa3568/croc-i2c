// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// ============================================================================
// Sub-module 1: SCL Clock Generator
// Divides clk_i to produce clk_en pulses at the target SCL rate.
// SCL period = 2 * (prescaler + 1) * T_clk
// ============================================================================
module i2c_clkgen (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        en_i,          // core enable (from CTR.EN)
    input  logic [15:0] prescaler_i,   // 16-bit divider value
    output logic        clk_en_o,      // one-cycle pulse per SCL half-period
    output logic        scl_phase_o    // toggles every half-period (for debug)
);
    logic [15:0] cnt;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            cnt        <= '0;
            clk_en_o   <= 1'b0;
            scl_phase_o <= 1'b0;
        end else if (!en_i) begin
            cnt        <= prescaler_i;
            clk_en_o   <= 1'b0;
            scl_phase_o <= 1'b0;
        end else begin
            if (cnt == '0) begin
                cnt         <= prescaler_i;
                clk_en_o    <= 1'b1;
                scl_phase_o <= ~scl_phase_o;
            end else begin
                cnt      <= cnt - 16'd1;
                clk_en_o <= 1'b0;
            end
        end
    end
endmodule
