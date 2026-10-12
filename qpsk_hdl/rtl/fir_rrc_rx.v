`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// fir_rrc_rx - receive root raised cosine matched filter
//
// Non decimating, so the symbol timing recovery that follows still has SPS
// samples per symbol to interpolate between and can correct any fractional
// delay and timing drift.
//
// The prototype is symmetric, so taps k and RX_NTAPS-1-k are pre-added
// before the multiply: 21 multipliers per rail instead of 41.
//
// Latency: 3 clocks (pre-add, product, sum+round), feed forward.
// ---------------------------------------------------------------------------
`default_nettype none

module fir_rrc_rx (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    output reg                  out_valid,
    output reg  signed [15:0]   out_i,
    output reg  signed [15:0]   out_q
);

`include "qpsk_defs.vh"

    localparam integer NT   = RX_NTAPS;     // 41
    localparam integer NH   = RX_NHALF;     // 21, index 20 is the centre tap
    localparam integer ACCW = 2*W + 7;      // 39, room for 21 products
    localparam signed [ACCW-1:0] RND = (1 <<< (FRAC-1));

    // ---- sample delay line ----------------------------------------------
    // dI[j] holds x[n-1-j]; tap k of the filter is the incoming sample for
    // k = 0 and dI[k-1] otherwise, so the current sample is included
    reg signed [15:0] dI [0:NT-2];
    reg signed [15:0] dQ [0:NT-2];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < NT-1; k = k + 1) begin
                dI[k] <= 16'sd0;
                dQ[k] <= 16'sd0;
            end
        end else if (in_valid) begin
            for (k = NT-2; k > 0; k = k - 1) begin
                dI[k] <= dI[k-1];
                dQ[k] <= dQ[k-1];
            end
            dI[0] <= in_i;
            dQ[0] <= in_q;
        end
    end

    function signed [15:0] tapI(input integer idx);
        tapI = (idx == 0) ? in_i : dI[idx-1];
    endfunction
    function signed [15:0] tapQ(input integer idx);
        tapQ = (idx == 0) ? in_q : dQ[idx-1];
    endfunction

    // ---- stage 1: symmetric pre-add --------------------------------------
    reg signed [16:0] aI [0:NH-1];
    reg signed [16:0] aQ [0:NH-1];
    reg               v1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < NH; k = k + 1) begin
                aI[k] <= 17'sd0;
                aQ[k] <= 17'sd0;
            end
            v1 <= 1'b0;
        end else begin
            v1 <= in_valid;
            if (in_valid) begin
                for (k = 0; k < NH; k = k + 1) begin
                    if (k == NT-1-k) begin          // centre tap, no pair
                        aI[k] <= tapI(k);
                        aQ[k] <= tapQ(k);
                    end else begin
                        aI[k] <= tapI(k) + tapI(NT-1-k);
                        aQ[k] <= tapQ(k) + tapQ(NT-1-k);
                    end
                end
            end
        end
    end

    // ---- stage 2: products + adder tree ----------------------------------
    reg signed [ACCW-1:0] accI, accQ;
    reg                   v2;

    reg signed [ACCW-1:0] sI, sQ;
    integer j;
    always @(*) begin
        sI = {ACCW{1'b0}};
        sQ = {ACCW{1'b0}};
        for (j = 0; j < NH; j = j + 1) begin
            sI = sI + aI[j] * $signed(RX_H[W*j +: W]);
            sQ = sQ + aQ[j] * $signed(RX_H[W*j +: W]);
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            accI <= 0; accQ <= 0; v2 <= 1'b0;
        end else begin
            accI <= sI;
            accQ <= sQ;
            v2   <= v1;
        end
    end

    // ---- stage 3: round and saturate -------------------------------------
    wire signed [ACCW-1:0] rI = (accI + RND) >>> FRAC;
    wire signed [ACCW-1:0] rQ = (accQ + RND) >>> FRAC;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0; out_i <= 16'sd0; out_q <= 16'sd0;
        end else begin
            out_valid <= v2;
            out_i <= (rI >  32767) ?  16'sd32767 :
                     (rI < -32768) ? -16'sd32768 : rI[15:0];
            out_q <= (rQ >  32767) ?  16'sd32767 :
                     (rQ < -32768) ? -16'sd32768 : rQ[15:0];
        end
    end

endmodule

`default_nettype wire
