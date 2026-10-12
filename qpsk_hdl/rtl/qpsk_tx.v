`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// qpsk_tx - QPSK transmitter top level
//
//   payload bits -> packetiser / scrambler / QPSK mapper -> RRC interpolate
//   by SPS -> baseband samples at Fs = SPS * Rsym
//
// One output sample is produced per clock while en is high.  Payload bits are
// taken through a simple valid/ready handshake; if the source cannot keep up
// the whole datapath stalls rather than corrupting a packet.
// ---------------------------------------------------------------------------
`default_nettype none

module qpsk_tx (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 en,

    input  wire                 din_bit,
    input  wire                 din_valid,
    output wire                 din_ready,

    output wire                 out_valid,
    output wire signed [15:0]   out_i,
    output wire signed [15:0]   out_q,

    // observation taps, used by the testbench
    output wire                 sym_valid,
    output wire signed [15:0]   sym_i,
    output wire signed [15:0]   sym_q,
    output wire                 sym_sop
);

`include "qpsk_defs.vh"

    wire sym_req, sym_stall, sym_pay;

    qpsk_tx_sym u_sym (
        .clk(clk), .rst_n(rst_n),
        .din_bit(din_bit), .din_valid(din_valid), .din_ready(din_ready),
        .sym_req(sym_req), .sym_stall(sym_stall),
        .sym_valid(sym_valid), .sym_i(sym_i), .sym_q(sym_q),
        .sym_sop(sym_sop), .sym_pay(sym_pay));

    fir_interp_rrc u_fir (
        .clk(clk), .rst_n(rst_n), .en(en),
        .sym_req(sym_req), .sym_stall(sym_stall),
        .sym_i(sym_i), .sym_q(sym_q), .sym_valid(sym_valid),
        .out_valid(out_valid), .out_i(out_i), .out_q(out_q));

endmodule

`default_nettype wire
