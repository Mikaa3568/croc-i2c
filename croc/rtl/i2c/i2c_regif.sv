// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// ============================================================================
// Sub-module 3: OBI Register Interface
// Maps OBI bus reads/writes to control/status registers.
// ============================================================================
`include "common_cells/registers.svh"

module i2c_regif (
    input  logic        clk_i,
    input  logic        rst_ni,

    // OBI subordinate port
    input  croc_pkg::sbr_obi_req_t obi_req_i,
    output croc_pkg::sbr_obi_rsp_t obi_rsp_o,

    // Register outputs to clkgen + ctrl
    output logic [15:0] prescaler_o,
    output logic        en_o,
    output logic        ien_o,
    output logic [7:0]  txr_o,
    output logic        cmd_sta_o,
    output logic        cmd_sto_o,
    output logic        cmd_rd_o,
    output logic        cmd_wr_o,
    output logic        cmd_ack_o,
    output logic        cmd_iack_o,

    // Status inputs from ctrl
    input  logic [7:0]  rxr_i,
    input  logic        sr_rxack_i,
    input  logic        sr_busy_i,
    input  logic        sr_al_i,
    input  logic        sr_tip_i,
    input  logic        sr_if_i,

    // FSM state (for cmd self-clear)
    input  logic        fsm_idle_i
);
    logic        obi_rvalid;
    logic [31:0] obi_rdata;
    logic [3:0]  waddr;

    assign waddr = obi_req_i.a.addr[4:1];

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            prescaler_o  <= 16'h00F9;  // ~100 kHz at 50 MHz
            en_o         <= 1'b0;
            ien_o        <= 1'b0;
            txr_o        <= 8'h00;
            cmd_sta_o    <= 1'b0;
            cmd_sto_o    <= 1'b0;
            cmd_rd_o     <= 1'b0;
            cmd_wr_o     <= 1'b0;
            cmd_ack_o    <= 1'b0;
            cmd_iack_o   <= 1'b0;
            obi_rvalid   <= 1'b0;
            obi_rdata    <= 32'h0;
        end else begin
            obi_rvalid <= obi_req_i.req;

            // Self-clear one-shot commands once FSM leaves IDLE
            if (!fsm_idle_i) begin
                cmd_sta_o  <= 1'b0;
                cmd_sto_o  <= 1'b0;
                cmd_rd_o   <= 1'b0;
                cmd_wr_o   <= 1'b0;
                cmd_iack_o <= 1'b0;
            end

            if (obi_req_i.req) begin
                if (obi_req_i.a.we) begin
                    // ---- WRITE ----
                    case (waddr)
                        4'h0: prescaler_o[7:0]  <= obi_req_i.a.wdata[7:0]; // PRESCALER_LO
                        4'h2: prescaler_o[15:8] <= obi_req_i.a.wdata[7:0]; // PRESCALER_HI
                        4'h4: begin                                          // CTR
                            en_o  <= obi_req_i.a.wdata[7];
                            ien_o <= obi_req_i.a.wdata[6];
                        end
                        4'h6: txr_o <= obi_req_i.a.wdata[7:0];             // TXR
                        4'h8: begin                                          // CR (command)
                            cmd_sta_o  <= obi_req_i.a.wdata[7];
                            cmd_sto_o  <= obi_req_i.a.wdata[6];
                            cmd_rd_o   <= obi_req_i.a.wdata[5];
                            cmd_wr_o   <= obi_req_i.a.wdata[4];
                            cmd_ack_o  <= obi_req_i.a.wdata[3];
                            cmd_iack_o <= obi_req_i.a.wdata[0];
                        end
                        default: ;
                    endcase
                    obi_rdata <= 32'h0;
                end else begin
                    // ---- READ ----
                    case (waddr)
                        4'h0: obi_rdata <= {24'h0, prescaler_o[7:0]};
                        4'h2: obi_rdata <= {24'h0, prescaler_o[15:8]};
                        4'h4: obi_rdata <= {24'h0, en_o, ien_o, 6'b0};
                        4'h6: obi_rdata <= {24'h0, txr_o};
                        4'h8: obi_rdata <= {24'h0, rxr_i};           // RXR (read-only)
                        4'ha: obi_rdata <= {24'h0,                   // SR (status)
                                             sr_rxack_i,
                                             sr_busy_i,
                                             sr_al_i,
                                             3'b0,
                                             sr_tip_i,
                                             sr_if_i};
                        default: obi_rdata <= 32'hDEADBEEF;
                    endcase
                end
            end
        end
    end

    assign obi_rsp_o.r.rdata      = obi_rdata;
    assign obi_rsp_o.r.rid        = '0;
    assign obi_rsp_o.r.err        = 1'b0;
    assign obi_rsp_o.r.r_optional = 1'b0;
    assign obi_rsp_o.gnt          = obi_req_i.req;
    assign obi_rsp_o.rvalid       = obi_rvalid;
endmodule
