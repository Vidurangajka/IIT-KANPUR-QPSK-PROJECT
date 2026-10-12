`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// zed_qpsk_top - QPSK loopback demo for the ZedBoard (xc7z020clg484-1)
//
//   bit source -> qpsk_tx -> qpsk_channel -> qpsk_rx -> ber_monitor
//
// An MMCM derives a 20 MHz design clock from the 100 MHz board clock: the
// core RTL forms each filter output in a single clock (the matched filter is
// a 21-deep DSP cascade, ~38 ns), so it does not close timing any faster.
// One sample is produced every CLKS_PER_SAMPLE clocks, so Fs = 1.25 MS/s and
// the symbol rate is 312.5 kBd.
//
//   sw[1:0]  carrier frequency offset   0, +0.02, -0.04, +0.06 turns/symbol
//   sw[3:2]  noise                      off, Eb/N0 10, 8, 6 dB
//   sw[5:4]  carrier phase offset       37 + 0, 90, 180, 270 degrees
//   sw[7:6]  receive level              1, 1/2, 1/4, 1/8 (relative)
//   BTNC     reset everything
//   BTNU     clear the BER counters (while held)
//
//   LD0      heartbeat
//   LD1      link: a packet was decoded in the last millisecond
//   LD2      bit errors seen recently
//   LD3      a packet was lost or slipped recently
//   LD4-LD7  BER bar over the last 2**18 bits: LD4 any errors, LD5 > 1e-4,
//            LD6 > 1e-3, LD7 > 1e-2
//
// Any channel change restarts the receiver, so it re-acquires as it would
// on a new link, and holds the counters at zero until it has settled.
//
// With USE_DEBUG_CORES defined (build.tcl does this) the counters are
// readable through a VIO and the receiver internals through an ILA in the
// Vivado Hardware Manager.
// ---------------------------------------------------------------------------
`default_nettype none

module zed_qpsk_top #(
    parameter SIM = 0           // 1: no MMCM, short debounce and settle timers
) (
    input  wire         clk_100,
    input  wire [7:0]   sw,
    input  wire         btnc,
    input  wire         btnu,
    output wire [7:0]   led
);

`include "qpsk_defs.vh"
`include "board_defs.vh"

    localparam integer DEB_BITS    = SIM ? 4  : 18;     // 13 ms
    localparam integer SETTLE_BITS = SIM ? 17 : 21;     // 105 ms, ~120 packets
    localparam integer LINK_BITS   = 17;                // 6.6 ms, ~7 packets
    localparam integer HOLD_BITS   = SIM ? 8  : 22;     // 210 ms LED stretch
    localparam integer HB_BIT      = 23;                // 1.2 Hz heartbeat

    // ---- clock: 100 MHz -> 20 MHz ----------------------------------------
    wire clk, locked;
    generate
        if (SIM) begin : g_simclk
            assign clk    = clk_100;
            assign locked = 1'b1;
        end else begin : g_mmcm
            wire clk_fb, clk_mmcm;
            MMCME2_BASE #(
                .CLKIN1_PERIOD(10.0),
                .CLKFBOUT_MULT_F(10.0),     // VCO 1000 MHz
                .DIVCLK_DIVIDE(1),
                .CLKOUT0_DIVIDE_F(50.0)     // 20 MHz
            ) u_mmcm (
                .CLKIN1(clk_100), .CLKFBIN(clk_fb), .CLKFBOUT(clk_fb),
                .CLKOUT0(clk_mmcm), .LOCKED(locked),
                .RST(1'b0), .PWRDWN(1'b0),
                .CLKOUT0B(), .CLKOUT1(), .CLKOUT1B(), .CLKOUT2(), .CLKOUT2B(),
                .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
                .CLKFBOUTB());
            BUFG u_bufg (.I(clk_mmcm), .O(clk));
        end
    endgenerate

    // ---- power on reset -------------------------------------------------
    reg [3:0] por = 4'd0;
    always @(posedge clk) if (!por[3]) por <= por + 1'b1;

    // ---- switch and button synchronise + debounce ------------------------
    reg [9:0] in_s1, in_s2;
    reg [9:0] in_db = 10'd0;
    reg [DEB_BITS-1:0] deb_cnt = 0;
    always @(posedge clk) begin
        in_s1 <= {btnu, btnc, sw};
        in_s2 <= in_s1;
        if (in_s2 == in_db) deb_cnt <= 0;
        else begin
            deb_cnt <= deb_cnt + 1'b1;
            if (&deb_cnt) in_db <= in_s2;
        end
    end

    wire [7:0] sw_d   = in_db[7:0];
    wire       btnc_d = in_db[8];
    wire       btnu_d = in_db[9];

    // ---- resets ---------------------------------------------------------
    reg sys_rst_n = 1'b0;
    always @(posedge clk) sys_rst_n <= por[3] && locked && !btnc_d;

    // ---- channel settings -----------------------------------------------
    reg [31:0] fo_inc;
    reg [15:0] sigma;
    always @(*) begin
        case (sw_d[1:0])
            2'd0: fo_inc = FO_INC_0;
            2'd1: fo_inc = FO_INC_1;
            2'd2: fo_inc = FO_INC_2;
            default: fo_inc = FO_INC_3;
        endcase
        case (sw_d[3:2])
            2'd0: sigma = SIGMA_0;
            2'd1: sigma = SIGMA_1;
            2'd2: sigma = SIGMA_2;
            default: sigma = SIGMA_3;
        endcase
    end
    wire [15:0] phase_off = PHASE_OFF + {sw_d[5:4], 14'd0};
    wire [1:0]  level     = sw_d[7:6];

    // a change of any setting restarts the receiver and the settle timer
    reg  [7:0] sw_q;
    reg  [2:0] rx_rst_cnt;
    reg        rx_rst_n;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            sw_q       <= 8'd0;
            rx_rst_cnt <= 3'd7;
            rx_rst_n   <= 1'b0;
        end else begin
            sw_q <= sw_d;
            if (sw_d != sw_q)         rx_rst_cnt <= 3'd7;
            else if (rx_rst_cnt != 0) rx_rst_cnt <= rx_rst_cnt - 1'b1;
            rx_rst_n <= (rx_rst_cnt == 0) && (sw_d == sw_q);
        end
    end

    reg [SETTLE_BITS:0] settle;
    wire settling = !settle[SETTLE_BITS];
    always @(posedge clk or negedge rx_rst_n) begin
        if (!rx_rst_n)     settle <= 0;
        else if (settling) settle <= settle + 1'b1;
    end
    wire clear = settling || btnu_d;

    // ---- sample strobe --------------------------------------------------
    reg [$clog2(CLKS_PER_SAMPLE)-1:0] ph;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) ph <= 0;
        else            ph <= ph + 1'b1;
    end
    wire strobe = (ph == 0);

    // ---- bit source -------------------------------------------------------
    // Each payload is a 16 bit packet number k, MSB first, then PRBS-15
    // seeded with {1, k[13:0]}, so every packet carries different data (see
    // ber_monitor for why that matters and how it is checked).
    reg  [$clog2(DATA_BITS)-1:0] src_n;     // bit index within the payload
    reg  [15:0] src_k;                      // packet number
    reg  [15:0] src_h;                      // header shift register
    reg  [14:0] src_s;                      // PRBS state
    wire [14:0] src_next = {src_s[13:0], src_s[14] ^ src_s[13]};
    wire [15:0] k_next   = src_k + 1'b1;
    wire        in_hdr   = (src_n < 16);
    wire        din_bit  = in_hdr ? src_h[15] : src_next[0];
    wire        din_ready;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            src_n <= 0;
            src_k <= 16'd0;
            src_h <= 16'd0;
            src_s <= {1'b1, 14'd0};
        end else if (din_ready) begin
            if (in_hdr) src_h <= {src_h[14:0], 1'b0};
            else        src_s <= src_next;
            src_n <= src_n + 1'b1;
            if (src_n == DATA_BITS - 1) begin
                src_n <= 0;
                src_k <= k_next;
                src_h <= k_next;
                src_s <= {1'b1, k_next[13:0]};
            end
        end
    end

    // ---- transmitter ----------------------------------------------------
    wire               tx_valid;
    wire signed [15:0] tx_i, tx_q;
    qpsk_tx u_tx (
        .clk(clk), .rst_n(sys_rst_n), .en(strobe),
        .din_bit(din_bit), .din_valid(1'b1), .din_ready(din_ready),
        .out_valid(tx_valid), .out_i(tx_i), .out_q(tx_q),
        .sym_valid(), .sym_i(), .sym_q(), .sym_sop());

    // ---- channel --------------------------------------------------------
    wire               ch_valid;
    wire signed [15:0] ch_i, ch_q;
    qpsk_channel u_ch (
        .clk(clk), .rst_n(sys_rst_n),
        .in_valid(tx_valid), .in_i(tx_i), .in_q(tx_q),
        .fo_inc(fo_inc), .phase_off(phase_off), .noise_sigma(sigma), .level(level),
        .out_valid(ch_valid), .out_i(ch_i), .out_q(ch_q));

    // ---- receiver -------------------------------------------------------
    wire               bit_valid, pkt_start, pkt_done;
    wire [1:0]         bit_data;
    wire               ff_valid;
    wire signed [15:0] ff_i, ff_q;
    wire signed [23:0] cf_rate;
    wire [19:0]        agc_gain;
    qpsk_rx u_rx (
        .clk(clk), .rst_n(rx_rst_n),
        .in_valid(ch_valid), .in_i(ch_i), .in_q(ch_q),
        .bit_valid(bit_valid), .bit_data(bit_data),
        .pkt_start(pkt_start), .pkt_done(pkt_done),
        .agc_valid(), .agc_i(), .agc_q(), .agc_gain(agc_gain),
        .mf_valid(), .mf_i(), .mf_q(),
        .sym_valid(), .sym_i(), .sym_q(),
        .cf_valid(), .cf_i(), .cf_q(), .cf_rate(cf_rate),
        .ff_valid(ff_valid), .ff_i(ff_i), .ff_q(ff_q),
        .det_valid(), .det_age());

    // ---- BER monitor ----------------------------------------------------
    wire [47:0] bit_cnt;
    wire [31:0] err_cnt, pkt_cnt, bad_pkt_cnt, lost_cnt, slip_cnt;
    wire        err_evt, lost_evt;
    ber_monitor u_ber (
        .clk(clk), .rst_n(sys_rst_n), .clear(clear),
        .bit_valid(bit_valid), .bit_data(bit_data),
        .pkt_start(pkt_start), .pkt_done(pkt_done),
        .bit_cnt(bit_cnt), .err_cnt(err_cnt), .pkt_cnt(pkt_cnt),
        .bad_pkt_cnt(bad_pkt_cnt), .lost_cnt(lost_cnt), .slip_cnt(slip_cnt),
        .err_evt(err_evt), .lost_evt(lost_evt));

    // ---- BER bar --------------------------------------------------------
    // errors are counted over windows of 2**BAR_BITS checked bits; at the
    // end of each window the count is compared with fixed thresholds, so
    // no divider is needed
    reg  [47:0] bar_base;
    reg  [31:0] bar_err0;
    reg  [3:0]  bar;
    wire [47:0] bar_span = bit_cnt - bar_base;
    wire [31:0] bar_errs = err_cnt - bar_err0;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            bar_base <= 0; bar_err0 <= 0; bar <= 4'd0;
        end else if (clear) begin
            bar_base <= 0; bar_err0 <= 0; bar <= 4'd0;
        end else if (bar_span >= (48'd1 << BAR_BITS)) begin
            bar_base <= bit_cnt;
            bar_err0 <= err_cnt;
            bar <= {bar_errs > BAR_1E2, bar_errs > BAR_1E3,
                    bar_errs > BAR_1E4, bar_errs != 0};
        end
    end

    // ---- status LEDs ----------------------------------------------------
    reg [HB_BIT:0]      hb;
    reg [LINK_BITS:0]   link_t;
    reg [HOLD_BITS:0]   err_t, lost_t;
    always @(posedge clk or negedge sys_rst_n) begin
        if (!sys_rst_n) begin
            hb <= 0; link_t <= 0; err_t <= 0; lost_t <= 0;
        end else begin
            hb <= hb + 1'b1;
            // each timer's top bit is set on an event and runs down to clear
            link_t <= pkt_done ? {1'b1, {LINK_BITS{1'b0}}}
                    : (link_t != 0) ? link_t + 1'b1 : link_t;
            err_t  <= (err_evt && !clear) ? {1'b1, {HOLD_BITS{1'b0}}}
                    : (err_t != 0) ? err_t + 1'b1 : err_t;
            lost_t <= (lost_evt && !clear) ? {1'b1, {HOLD_BITS{1'b0}}}
                    : (lost_t != 0) ? lost_t + 1'b1 : lost_t;
        end
    end

    assign led = {bar,
                  lost_t[HOLD_BITS], err_t[HOLD_BITS], link_t[LINK_BITS], hb[HB_BIT]};

    // ---- debug cores ----------------------------------------------------
`ifdef USE_DEBUG_CORES
    vio_qpsk u_vio (
        .clk(clk),
        .probe_in0(bit_cnt),            // 48  bits checked
        .probe_in1(err_cnt),            // 32  bit errors
        .probe_in2(pkt_cnt),            // 32  packets checked
        .probe_in3(bad_pkt_cnt),        // 32  packets with errors
        .probe_in4(lost_cnt),           // 32  packets lost
        .probe_in5(cf_rate),            // 24  coarse frequency estimate
        .probe_in6(agc_gain),           // 20  AGC gain
        .probe_in7({settling, sw_d}),   // 9   status and settings
        .probe_in8(slip_cnt));          // 32  packets decoded but unrecognisable

    ila_qpsk u_ila (
        .clk(clk),
        .probe0(ff_valid),              // 1   symbol strobe
        .probe1(ff_i),                  // 16  recovered symbol I
        .probe2(ff_q),                  // 16  recovered symbol Q
        .probe3(ch_valid),              // 1   channel sample strobe
        .probe4(ch_i),                  // 16  channel output I
        .probe5(ch_q),                  // 16  channel output Q
        .probe6(pkt_start),             // 1
        .probe7(err_evt));              // 1
`endif

endmodule

`default_nettype wire
