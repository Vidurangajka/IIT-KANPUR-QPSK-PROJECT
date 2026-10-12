`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// qpsk_rx - QPSK receiver top level
//
//   baseband samples at Fs = SPS*Rsym
//     -> AGC
//     -> RRC matched filter (non decimating)
//     -> symbol timing recovery   (Gardner, Fs -> Rsym)
//     -> coarse frequency recovery (fourth power, feed forward)
//     -> fine frequency recovery   (decision directed, feedback)
//     -> packet detector (Barker correlation, dynamic threshold)
//     -> phase ambiguity removal, slicer, descrambler
//     -> payload bits
//
// Clocking.  The datapath is sample enabled rather than running one sample
// per clock: in_valid marks an input sample and the design needs at least
// MIN_CLKS_PER_SAMPLE clocks between two of them.  That is how a real
// receiver is built anyway (the reference application runs a 1.92 MHz symbol
// rate on a 350 MHz clock) and it leaves room for the pipelined CORDICs and
// the timing loop filter inside one sample period.
//
// The requirement comes from the symbol timing loop, which is the tightest:
// a sample is interpolated, the Gardner error formed and the loop filter
// updated in 7 clocks, and the result has to be in place before the next
// sample arrives.
// ---------------------------------------------------------------------------
`default_nettype none

module qpsk_rx (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    output wire                 bit_valid,
    output wire [1:0]           bit_data,   // I rail bit, then Q rail bit
    output wire                 pkt_start,
    output wire                 pkt_done,

    // observation taps for the testbench
    output wire                 agc_valid,
    output wire signed [15:0]   agc_i,
    output wire signed [15:0]   agc_q,
    output wire [19:0]          agc_gain,
    output wire                 mf_valid,
    output wire signed [15:0]   mf_i,
    output wire signed [15:0]   mf_q,
    output wire                 sym_valid,
    output wire signed [15:0]   sym_i,
    output wire signed [15:0]   sym_q,
    output wire                 cf_valid,
    output wire signed [15:0]   cf_i,
    output wire signed [15:0]   cf_q,
    output wire signed [23:0]   cf_rate,
    output wire                 ff_valid,
    output wire signed [15:0]   ff_i,
    output wire signed [15:0]   ff_q,
    output wire                 det_valid,
    output wire [3:0]           det_age
);

`include "qpsk_defs.vh"

    localparam integer MIN_CLKS_PER_SAMPLE = 8;

    wire signed [20:0] det_cI, det_cQ;

    rx_agc u_agc (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
        .out_valid(agc_valid), .out_i(agc_i), .out_q(agc_q),
        .gain(agc_gain));

    fir_rrc_rx u_mf (
        .clk(clk), .rst_n(rst_n),
        .in_valid(agc_valid), .in_i(agc_i), .in_q(agc_q),
        .out_valid(mf_valid), .out_i(mf_i), .out_q(mf_q));

    symbol_timing_recovery u_str (
        .clk(clk), .rst_n(rst_n),
        .in_valid(mf_valid), .in_i(mf_i), .in_q(mf_q),
        .sym_valid(sym_valid), .sym_i(sym_i), .sym_q(sym_q),
        .mu_dbg());

    coarse_freq_rec u_cf (
        .clk(clk), .rst_n(rst_n),
        .in_valid(sym_valid), .in_i(sym_i), .in_q(sym_q),
        .out_valid(cf_valid), .out_i(cf_i), .out_q(cf_q),
        .frate_dbg(cf_rate));

    fine_freq_rec u_ff (
        .clk(clk), .rst_n(rst_n),
        .in_valid(cf_valid), .in_i(cf_i), .in_q(cf_q),
        .out_valid(ff_valid), .out_i(ff_i), .out_q(ff_q),
        .err_dbg());

    packet_detector u_det (
        .clk(clk), .rst_n(rst_n),
        .in_valid(ff_valid), .in_i(ff_i), .in_q(ff_q),
        .det_valid(det_valid), .det_age(det_age),
        .det_cI(det_cI), .det_cQ(det_cQ));

    rx_extract u_ext (
        .clk(clk), .rst_n(rst_n),
        .in_valid(ff_valid), .in_i(ff_i), .in_q(ff_q),
        .det_valid(det_valid), .det_age(det_age),
        .det_cI(det_cI), .det_cQ(det_cQ),
        .bit_valid(bit_valid), .bit_data(bit_data),
        .pkt_start(pkt_start), .pkt_done(pkt_done));

endmodule

`default_nettype wire
