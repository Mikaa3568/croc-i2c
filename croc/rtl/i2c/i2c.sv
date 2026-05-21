// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// I2C Master Controller  (top wrapper)
// =====================================
// Instantiates three sub-modules so the OpenROAD hierarchy area report
// shows distinct entries for each functional block:
//
//   i_i2c  (this wrapper)
//     i_clkgen  – SCL prescaler / clock-enable generator
//     i_ctrl    – I2C bit-level FSM  (START / STOP / WR / RD / ACK)
//     i_regif   – OBI register interface  (SW readable/writable registers)
//
// I2C Pin Summary (open-drain model)
// -----------------------------------
//   i2c_sda_i   [input]  – SDA sampled from pad  (after external pull-up)
//   i2c_sda_o   [output] – always 1'b0  (driven through sda_oe)
//   i2c_sda_oe  [output] – 1 = pull SDA low,  0 = release (high-Z)
//   i2c_scl_i   [input]  – SCL sampled from pad  (clock stretching detect)
//   i2c_scl_o   [output] – always 1'b0  (driven through scl_oe)
//   i2c_scl_oe  [output] – 1 = pull SCL low,  0 = release (high-Z)
//
// OBI Register Map (byte address, 32-bit words)
//   0x00  PRESCALER_LO  [7:0]  SCL divider low byte
//   0x04  PRESCALER_HI  [7:0]  SCL divider high byte
//   0x08  CTR           [7]=EN, [6]=IEN
//   0x0C  TXR           [7:0]  transmit register (address+RW or data)
//   0x10  RXR           [7:0]  receive register  (read-only)
//   0x14  CR            [7]=STA,[6]=STO,[5]=RD,[4]=WR,[3]=ACK,[0]=IACK
//   0x18  SR            [7]=RxACK,[6]=BUSY,[5]=AL,[1]=TIP,[0]=IF

`include "common_cells/registers.svh"



// ============================================================================
// Top-level I2C wrapper
// Instantiates i2c_clkgen, i2c_ctrl, i2c_regif
// ============================================================================
module i2c (
    /// Primary input clock
    input  logic clk_i,
    /// Asynchronous active-low reset
    input  logic rst_ni,

    // ------------------------------------------------------------------
    // I2C Open-Drain Pins (connected to sg13g2_IOPadInOut30mA pad)
    // ------------------------------------------------------------------
    /// SDA sampled from pad (after external pull-up resistor)
    input  logic i2c_sda_i,
    /// SDA drive-low output: always 1'b0, active when i2c_sda_oe=1
    output logic i2c_sda_o,
    /// SDA output enable: 1 = pull SDA low (drive), 0 = high-Z (release)
    output logic i2c_sda_oe,
    /// SCL sampled from pad (used for clock-stretching detection)
    input  logic i2c_scl_i,
    /// SCL drive-low output: always 1'b0, active when i2c_scl_oe=1
    output logic i2c_scl_o,
    /// SCL output enable: 1 = pull SCL low (drive), 0 = high-Z (release)
    output logic i2c_scl_oe,

    // ------------------------------------------------------------------
    // OBI Subordinate Interface (from user_domain demux)
    // ------------------------------------------------------------------
    /// OBI request from SoC interconnect
    input  croc_pkg::sbr_obi_req_t obi_req_i,
    /// OBI response back to SoC interconnect
    output croc_pkg::sbr_obi_rsp_t obi_rsp_o
);

    // Internal wires between sub-modules
    logic        clk_en;
    logic [15:0] prescaler;
    logic        en, ien;
    logic [7:0]  txr, rxr;
    logic        cmd_sta, cmd_sto, cmd_rd, cmd_wr, cmd_ack, cmd_iack;
    logic        sr_rxack, sr_busy, sr_al, sr_tip, sr_if;
    logic        scl_phase;
    logic        fsm_idle;

    // fsm_idle: used to self-clear command registers once FSM starts
    // (driven from i_ctrl, but we infer it from sr_tip)
    assign fsm_idle = !sr_tip;

    // ------------------------------------------------------------------
    // Sub-module 1: SCL Clock Generator
    //   Produces clk_en pulses at SCL half-period rate
    // ------------------------------------------------------------------
    i2c_clkgen i_clkgen (
        .clk_i       ( clk_i      ),
        .rst_ni      ( rst_ni     ),
        .en_i        ( en         ),
        .prescaler_i ( prescaler  ),
        .clk_en_o    ( clk_en     ),
        .scl_phase_o ( scl_phase  )
    );

    // ------------------------------------------------------------------
    // Sub-module 2: I2C Bit-level Controller (FSM)
    //   Drives SDA/SCL open-drain outputs
    //     i2c_sda_i → sampled SDA from pad
    //     i2c_sda_o → always 0 (line pulled low via OE)
    //     i2c_sda_oe → 1 = pull SDA low
    //     i2c_scl_i → sampled SCL from pad
    //     i2c_scl_o → always 0 (line pulled low via OE)
    //     i2c_scl_oe → 1 = pull SCL low
    // ------------------------------------------------------------------
    i2c_ctrl i_ctrl (
        .clk_i      ( clk_i      ),
        .rst_ni     ( rst_ni     ),
        .clk_en_i   ( clk_en     ),
        .sda_i      ( i2c_sda_i  ),
        .sda_o      ( i2c_sda_o  ),
        .sda_oe_o   ( i2c_sda_oe ),
        .scl_i      ( i2c_scl_i  ),
        .scl_o      ( i2c_scl_o  ),
        .scl_oe_o   ( i2c_scl_oe ),
        .en_i       ( en         ),
        .txr_i      ( txr        ),
        .cmd_sta_i  ( cmd_sta    ),
        .cmd_sto_i  ( cmd_sto    ),
        .cmd_rd_i   ( cmd_rd     ),
        .cmd_wr_i   ( cmd_wr     ),
        .cmd_ack_i  ( cmd_ack    ),
        .cmd_iack_i ( cmd_iack   ),
        .rxr_o      ( rxr        ),
        .sr_rxack_o ( sr_rxack   ),
        .sr_busy_o  ( sr_busy    ),
        .sr_al_o    ( sr_al      ),
        .sr_tip_o   ( sr_tip     ),
        .sr_if_o    ( sr_if      )
    );

    // ------------------------------------------------------------------
    // Sub-module 3: OBI Register Interface
    //   SW reads/writes registers via OBI bus
    // ------------------------------------------------------------------
    i2c_regif i_regif (
        .clk_i       ( clk_i    ),
        .rst_ni      ( rst_ni   ),
        .obi_req_i   ( obi_req_i ),
        .obi_rsp_o   ( obi_rsp_o ),
        .prescaler_o ( prescaler ),
        .en_o        ( en        ),
        .ien_o       ( ien       ),
        .txr_o       ( txr       ),
        .cmd_sta_o   ( cmd_sta   ),
        .cmd_sto_o   ( cmd_sto   ),
        .cmd_rd_o    ( cmd_rd    ),
        .cmd_wr_o    ( cmd_wr    ),
        .cmd_ack_o   ( cmd_ack   ),
        .cmd_iack_o  ( cmd_iack  ),
        .rxr_i       ( rxr       ),
        .sr_rxack_i  ( sr_rxack  ),
        .sr_busy_i   ( sr_busy   ),
        .sr_al_i     ( sr_al     ),
        .sr_tip_i    ( sr_tip    ),
        .sr_if_i     ( sr_if     ),
        .fsm_idle_i  ( fsm_idle  )
    );

endmodule