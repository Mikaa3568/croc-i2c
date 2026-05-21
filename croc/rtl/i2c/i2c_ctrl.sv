// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
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
            ACK_CLK_L: if (clk_en_i) state_d = DONE;
            DONE:      state_d = latch_sto_q ? STO_A : IDLE;
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
                    if (clk_en_i && latch_rd_q) shift_rx <= {shift_rx[6:0], sda_i};
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
                    if (clk_en_i) shift_rx <= {shift_rx[6:0], sda_i};
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
