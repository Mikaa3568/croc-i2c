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


// ============================================================================
// Sub-module 2: I2C Bit-level FSM (Controller)
// Generates START/STOP conditions and shifts bits over SDA/SCL.
//
// SDA/SCL open-drain:
//   *_oe = 1  → actively pull the line LOW  (wire drives 0)
//   *_oe = 0  → release line (external pull-up brings it HIGH)
// ============================================================================
module i2c_ctrl (
    input  logic        clk_i,
    input  logic        rst_ni,

    // Clock enable from prescaler (one pulse per SCL half-period)
    input  logic        clk_en_i,

    // I2C physical pins (open-drain model)
    input  logic        sda_i,         // SDA read from pad
    output logic        sda_o,         // always 0; driven when sda_oe_o=1
    output logic        sda_oe_o,      // pull SDA low
    input  logic        scl_i,         // SCL read from pad (clock-stretch)
    output logic        scl_o,         // always 0; driven when scl_oe_o=1
    output logic        scl_oe_o,      // pull SCL low

    // Control from register interface
    input  logic        en_i,          // core enable
    input  logic [7:0]  txr_i,         // transmit data
    input  logic        cmd_sta_i,     // issue START
    input  logic        cmd_sto_i,     // issue STOP
    input  logic        cmd_rd_i,      // read byte
    input  logic        cmd_wr_i,      // write byte
    input  logic        cmd_ack_i,     // ACK control (0=ACK,1=NACK)
    input  logic        cmd_iack_i,    // interrupt acknowledge (clears IF)

    // Status to register interface
    output logic [7:0]  rxr_o,         // received byte
    output logic        sr_rxack_o,    // last ACK from slave (0=ACK)
    output logic        sr_busy_o,     // bus busy
    output logic        sr_al_o,       // arbitration lost
    output logic        sr_tip_o,      // transfer in progress
    output logic        sr_if_o        // interrupt flag (byte done)
);
    typedef enum logic [3:0] {
        IDLE      = 4'd0,
        STA_PRE   = 4'd13,  // Pre-START: release SCL/SDA for Repeated START
        STA_A     = 4'd1,   // SDA low while SCL high
        STA_B     = 4'd2,   // SCL low
        STO_A     = 4'd3,   // SCL high, SDA still low
        STO_B     = 4'd4,   // SDA high (stop)
        WR_BIT    = 4'd5,   // SCL low, put bit on SDA
        WR_CLK_H  = 4'd6,   // SCL high (slave samples)
        WR_CLK_L  = 4'd7,   // SCL low again
        RD_CLK_H  = 4'd8,   // SCL high (we sample SDA)
        RD_CLK_L  = 4'd9,   // SCL low
        ACK_CLK_H = 4'd10,  // ACK bit SCL high
        ACK_CLK_L = 4'd11,  // ACK bit SCL low
        DONE      = 4'd12   // transfer complete, raise IF
    } state_e;

    state_e   state_q;
    logic [2:0] bit_cnt;
    logic [7:0] shift_q, shift_rx;
    logic       sda_oe_q, scl_oe_q;
    logic       rxack_q;

    // Command latches: captured in IDLE, cleared in DONE.
    // Necessary because i2c_regif self-clears cmd_* as soon as sr_tip=1,
    // which happens before WR_BIT/ACK_CLK_H/STA_B finish reading them.
    logic latch_wr_q;
    logic latch_rd_q;
    logic latch_sto_q;

    // Combinational next-state
    state_e state_d;
    always_comb begin
        state_d = state_q;
        case (state_q)
            IDLE:      if (en_i && clk_en_i) begin
                           if (cmd_sta_i)      state_d = STA_PRE;
                           else if (cmd_wr_i || cmd_rd_i) state_d = WR_BIT;
                       end
            STA_PRE:   if (clk_en_i) state_d = STA_A;
            STA_A:     if (clk_en_i) state_d = STA_B;
            // After START: if WR or RD was also commanded, go directly to data phase
            // instead of returning to IDLE (fixes STA+WR infinite loop)
            STA_B:     if (clk_en_i) begin
                           // Use LATCHED values: cmd_wr/rd already self-cleared
                           if (latch_wr_q || latch_rd_q) state_d = WR_BIT;
                           else                          state_d = IDLE;
                       end
            STO_A:     if (clk_en_i) state_d = STO_B;
            STO_B:     if (clk_en_i) state_d = IDLE;
            WR_BIT:    if (clk_en_i) state_d = WR_CLK_H;
            WR_CLK_H:  if (clk_en_i) state_d = WR_CLK_L;
            WR_CLK_L:  if (clk_en_i) state_d = (bit_cnt==3'd0) ? ACK_CLK_H : WR_BIT;
            RD_CLK_H:  if (clk_en_i) state_d = RD_CLK_L;
            RD_CLK_L:  if (clk_en_i) state_d = (bit_cnt==3'd0) ? ACK_CLK_H : RD_CLK_H;
            ACK_CLK_H: if (clk_en_i) state_d = ACK_CLK_L;
            ACK_CLK_L: if (clk_en_i) state_d = latch_sto_q ? STO_A : DONE;
            DONE:      state_d = IDLE;
            default:   state_d = IDLE;
        endcase
    end

    // Sequential
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q    <= IDLE;
            bit_cnt    <= 3'd7;
            shift_q    <= '0;
            shift_rx   <= '0;
            sda_oe_q   <= 1'b0;
            scl_oe_q   <= 1'b0;
            rxack_q    <= 1'b1;
            latch_wr_q <= 1'b0;
            latch_rd_q <= 1'b0;
            latch_sto_q<= 1'b0;
            sr_rxack_o <= 1'b1;
            sr_busy_o  <= 1'b0;
            sr_al_o    <= 1'b0;
            sr_tip_o   <= 1'b0;
            sr_if_o    <= 1'b0;
            rxr_o      <= 8'h00;
        end else begin
            state_q <= state_d;

            // Interrupt ack
            if (cmd_iack_i) sr_if_o <= 1'b0;

            // Arbitration lost
            if (scl_oe_q && !scl_i) sr_al_o <= 1'b1;
            else if (state_q == IDLE) sr_al_o <= 1'b0;

            case (state_q)
                IDLE: begin
                    sr_tip_o <= 1'b0;
                    if (!sr_busy_o) scl_oe_q <= 1'b0;
                    if (clk_en_i) begin
                        if (cmd_sta_i) begin
                            sda_oe_q    <= 1'b0;
                            sr_busy_o   <= 1'b1;
                            latch_wr_q  <= cmd_wr_i;
                            latch_rd_q  <= cmd_rd_i;
                            latch_sto_q <= cmd_sto_i;
                            if (cmd_wr_i || cmd_rd_i) begin
                                shift_q  <= txr_i;
                                bit_cnt  <= 3'd7;
                                sr_tip_o <= 1'b1;
                            end
                        end else if (cmd_wr_i || cmd_rd_i) begin
                            latch_wr_q  <= cmd_wr_i;
                            latch_rd_q  <= cmd_rd_i;
                            latch_sto_q <= cmd_sto_i;
                            shift_q     <= txr_i;
                            bit_cnt     <= 3'd7;
                            sr_tip_o    <= 1'b1;
                        end
                    end
                end
                STA_PRE: begin // Release SDA and SCL before pulling SDA low
                    sda_oe_q <= 1'b0;
                    scl_oe_q <= 1'b0;
                end
                STA_A: begin  // SDA→0 while SCL high → START
                    sda_oe_q <= 1'b1;
                    scl_oe_q <= 1'b0;
                end
                STA_B: begin  // SCL→low
                    scl_oe_q <= 1'b1;
                end
                STO_A: begin  // SCL high, SDA still low
                    sda_oe_q <= 1'b1;
                    scl_oe_q <= 1'b0;
                end
                STO_B: begin  // SDA→high while SCL high → STOP
                    sda_oe_q  <= 1'b0;
                    sr_busy_o <= 1'b0;
                end
                WR_BIT: begin  // SCL low, put data bit on SDA
                    scl_oe_q <= 1'b1;
                    // Use LATCH: cmd_wr_i may already be 0 (self-cleared)
                    sda_oe_q <= latch_wr_q ? ~shift_q[7] : 1'b0;
                end
                WR_CLK_H: begin  // SCL high
                    scl_oe_q <= 1'b0;
                    // Use LATCH: sample SDA only for read transfers
                    if (latch_rd_q) shift_rx <= {shift_rx[6:0], sda_i};
                end
                WR_CLK_L: begin  // SCL low – shift
                    scl_oe_q <= 1'b1;
                    if (clk_en_i) begin
                        shift_q <= {shift_q[6:0], 1'b0};
                        if (bit_cnt != 3'd0) bit_cnt <= bit_cnt - 3'd1;
                    end
                end
                RD_CLK_H: begin
                    scl_oe_q <= 1'b0;
                    shift_rx <= {shift_rx[6:0], sda_i};
                end
                RD_CLK_L: begin
                    scl_oe_q <= 1'b1;
                    if (clk_en_i && bit_cnt != 3'd0) bit_cnt <= bit_cnt - 3'd1;
                end
                ACK_CLK_H: begin  // ACK clock high
                    scl_oe_q <= 1'b0;
                    // Use LATCH: cmd_wr_i may be 0 (self-cleared)
                    if (latch_wr_q) begin
                        sda_oe_q <= 1'b0;       // release SDA to read slave ACK
                        rxack_q  <= sda_i;       // 0=ACK, 1=NACK
                    end else begin
                        sda_oe_q <= ~cmd_ack_i; // 0=send ACK, 1=send NACK
                    end
                end
                ACK_CLK_L: begin
                    scl_oe_q <= 1'b1;
                end
                DONE: begin
                    sr_rxack_o <= rxack_q;
                    rxr_o      <= shift_rx;
                    sr_tip_o   <= 1'b0;
                    sr_if_o    <= 1'b1;
                    bit_cnt    <= 3'd7;
                    // Clear latches for next byte
                    latch_wr_q  <= 1'b0;
                    latch_rd_q  <= 1'b0;
                    latch_sto_q <= 1'b0;
                end
                default: ;
            endcase
        end
    end

    // Open-drain outputs: always drive 0 through pad's OE pin
    assign sda_o    = 1'b0;
    assign sda_oe_o = sda_oe_q;
    assign scl_o    = 1'b0;
    assign scl_oe_o = scl_oe_q;
endmodule


// ============================================================================
// Sub-module 3: OBI Register Interface
// Maps OBI bus reads/writes to control/status registers.
// ============================================================================
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