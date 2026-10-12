`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// ber_monitor - checks the receiver output against the transmitted payload
//
// Payload format (zed_qpsk_top's bit source), DATA_BITS bits per packet:
//
//   bits 0..15    packet number k, MSB first
//   bits 16..     PRBS-15 (x^15 + x^14 + 1) seeded with {1, k[13:0]}
//
// Every packet therefore carries different data.  This matters: with the
// same payload in every packet a correlation sidelobe of the payload can
// repeat at the same place in every packet, and if the packet detector
// happens to lock onto it after a reset the inhibit window masks the true
// preamble for good.
//
// The checker tests two hypotheses for each packet in parallel: that it is
// the packet after the last one (k_last + 1), and that it is the packet whose
// number it actually received in the header.  The first is right unless
// packets were lost, the second unless the header took a bit error; the one
// with fewer errors wins, so bit errors are counted exactly and packet loss
// is counted from the jump in k.  A packet that matches neither (more than
// SLIP_ERRS errors) is counted as slipped, not as bit errors.
//
// While clear is high all counters are held at zero, so the warm up after a
// reset or a channel change is not counted.
// ---------------------------------------------------------------------------
`default_nettype none

module ber_monitor #(
    parameter integer SLIP_ERRS = 128       // a quarter of the packet
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,

    input  wire         bit_valid,
    input  wire [1:0]   bit_data,       // [0] = I rail bit, sent first
    input  wire         pkt_start,
    input  wire         pkt_done,

    output reg  [47:0]  bit_cnt,
    output reg  [31:0]  err_cnt,
    output reg  [31:0]  pkt_cnt,        // packets checked
    output reg  [31:0]  bad_pkt_cnt,    // checked packets with any error
    output reg  [31:0]  lost_cnt,       // packets never decoded
    output reg  [31:0]  slip_cnt,       // decoded but unrecognisable
    output reg          err_evt,        // pulse: a packet had bit errors
    output reg          lost_evt        // pulse: a packet was lost or slipped
);

`include "qpsk_defs.vh"

    localparam integer HDR_SYMS = 8;            // 16 header bits

    function [14:0] prbs_step(input [14:0] s);
        prbs_step = {s[13:0], s[14] ^ s[13]};
    endfunction

    function [14:0] seed(input [15:0] k);
        seed = {1'b1, k[13:0]};
    endfunction

    function [4:0] popcount16(input [15:0] v);
        integer i;
        begin
            popcount16 = 5'd0;
            for (i = 0; i < 16; i = i + 1)
                popcount16 = popcount16 + v[i];
        end
    endfunction

    reg  [7:0]  idx;            // symbol index within the payload
    reg  [15:0] hdr;            // received header
    reg  [15:0] k_last;
    reg         have_k;
    reg  [14:0] sa, sb;         // reference PRBS: predicted k / received k
    reg  [9:0]  ea, eb;         // payload errors under each hypothesis

    wire [7:0]  idx_c   = pkt_start ? 8'd0 : idx;
    wire        in_hdr  = (idx_c < HDR_SYMS);
    wire        first   = (idx_c == HDR_SYMS);
    wire [15:0] k_pred  = k_last + 1'b1;
    wire [15:0] hdr_n   = {hdr[13:0], bit_data[0], bit_data[1]};

    // two PRBS steps per symbol under each hypothesis
    wire [14:0] a0 = first ? seed(k_pred) : sa;
    wire [14:0] b0 = first ? seed(hdr)    : sb;
    wire [14:0] a1 = prbs_step(a0), a2 = prbs_step(a1);
    wire [14:0] b1 = prbs_step(b0), b2 = prbs_step(b1);
    wire [1:0]  na = {1'b0, bit_data[0] ^ a1[0]} + {1'b0, bit_data[1] ^ a2[0]};
    wire [1:0]  nb = {1'b0, bit_data[0] ^ b1[0]} + {1'b0, bit_data[1] ^ b2[0]};
    wire [9:0]  ea_n = (in_hdr ? 10'd0 : (first ? 10'd0 : ea) + na);
    wire [9:0]  eb_n = (in_hdr ? 10'd0 : (first ? 10'd0 : eb) + nb);

    // end of packet decision; header errors only count against hypothesis A
    wire [9:0]  tot_a  = ea_n + popcount16(hdr ^ k_pred);
    wire        use_a  = have_k && (tot_a <= eb_n);
    wire [9:0]  best   = use_a ? tot_a : eb_n;
    wire [15:0] k_use  = use_a ? k_pred : hdr;
    wire [15:0] jump   = k_use - k_pred;           // packets skipped
    wire        slip   = (best > SLIP_ERRS);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            idx <= 0; hdr <= 0; k_last <= 0; have_k <= 1'b0;
            sa <= 0; sb <= 0; ea <= 0; eb <= 0;
            bit_cnt <= 0; err_cnt <= 0; pkt_cnt <= 0;
            bad_pkt_cnt <= 0; lost_cnt <= 0; slip_cnt <= 0;
            err_evt <= 1'b0; lost_evt <= 1'b0;
        end else begin
            err_evt  <= 1'b0;
            lost_evt <= 1'b0;

            if (bit_valid) begin
                idx <= idx_c + 1'b1;
                if (in_hdr) hdr <= hdr_n;
                else begin
                    sa <= a2;  sb <= b2;
                    ea <= ea_n; eb <= eb_n;
                end
            end

            if (pkt_done) begin
                // a slipped packet is assumed to have been the next one
                if (!slip) begin
                    k_last <= k_use;
                    have_k <= 1'b1;
                end else if (have_k)
                    k_last <= k_pred;
                if (!clear) begin
                    if (slip) begin
                        slip_cnt <= slip_cnt + 1'b1;
                        lost_evt <= 1'b1;
                    end else begin
                        pkt_cnt <= pkt_cnt + 1'b1;
                        bit_cnt <= bit_cnt + DATA_BITS;
                        err_cnt <= err_cnt + best;
                        if (best != 0) begin
                            bad_pkt_cnt <= bad_pkt_cnt + 1'b1;
                            err_evt     <= 1'b1;
                        end
                        // a large jump is a resynchronisation, not loss
                        if (have_k && jump != 0 && jump < 16'd1024) begin
                            lost_cnt <= lost_cnt + jump;
                            lost_evt <= 1'b1;
                        end
                    end
                end
            end

            if (clear) begin
                bit_cnt <= 0; err_cnt <= 0; pkt_cnt <= 0;
                bad_pkt_cnt <= 0; lost_cnt <= 0; slip_cnt <= 0;
            end
        end
    end

endmodule

`default_nettype wire
