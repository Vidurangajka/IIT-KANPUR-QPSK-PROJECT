`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// rx_agc - automatic gain control
//
// Holds the mean power of the received samples at AGC_TARGET so that every
// stage after it sees a known signal level.  That is what lets the Gardner
// timing loop and the packet detector threshold use constant gains instead
// of dividing by a running power estimate.
//
//   y = x * g
//   p = p + (|y|^2 - p) >> AGC_AVG_SHIFT         leaky power estimate
//   g = g + g*(target - p) >> AGC_STEP_SHIFT     multiplicative update
//
// The gain update is multiplicative, so the loop settles in a time that does
// not depend on how far off the input level is: the receiver works over the
// full 0.05 .. 1.0 input scaling range with the same constants.
//
// Latency: 1 clock.  The gain used for a sample is the gain computed from
// all previous samples, exactly as in the golden model.
// ---------------------------------------------------------------------------
`default_nettype none

module rx_agc (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    output reg                  out_valid,
    output reg  signed [15:0]   out_i,
    output reg  signed [15:0]   out_q,
    output wire [19:0]          gain        // Q8.12, for observation
);

`include "qpsk_defs.vh"

    localparam integer GW = AGC_GW;         // 20
    localparam integer PW = AGC_PW;         // 26
    localparam signed [36:0] GRND = (1 <<< (AGC_GFRAC - 1));

    reg  [GW-1:0]          g;
    reg  signed [PW-1:0]   p;

    assign gain = g;

    // ---- apply the gain --------------------------------------------------
    wire signed [GW:0]     gs = {1'b0, g};              // unsigned -> signed
    wire signed [36:0]     mi = in_i * gs;
    wire signed [36:0]     mq = in_q * gs;
    wire signed [36:0]     ri = (mi + GRND) >>> AGC_GFRAC;
    wire signed [36:0]     rq = (mq + GRND) >>> AGC_GFRAC;
    wire signed [15:0]     yi = (ri >  32767) ?  16'sd32767 :
                                (ri < -32768) ? -16'sd32768 : ri[15:0];
    wire signed [15:0]     yq = (rq >  32767) ?  16'sd32767 :
                                (rq < -32768) ? -16'sd32768 : rq[15:0];

    // ---- power estimate --------------------------------------------------
    wire        [31:0]     sq_i = yi * yi;              // always non negative
    wire        [31:0]     sq_q = yq * yq;
    wire        [32:0]     mag2 = sq_i + sq_q;          // Q2.30
    wire signed [PW-1:0]   pw   = $signed({{(PW-33+AGC_P_ALIGN){1'b0}},
                                           mag2[32:AGC_P_ALIGN]});
    wire signed [PW-1:0]   pnxt = p + ((pw - p) >>> AGC_AVG_SHIFT);

    // ---- gain update -----------------------------------------------------
    // the error is taken from the UPDATED power estimate, matching the model
    localparam signed [PW:0] TGT = AGC_TARGET;
    wire signed [PW:0]     errv = TGT - pnxt;
    wire signed [63:0]     dgm  = $signed({1'b0, g}) * errv;
    wire signed [63:0]     dg   = dgm >>> (AGC_PFRAC + AGC_STEP_SHIFT);
    wire signed [63:0]     gsum = $signed({{(64-GW){1'b0}}, g}) + dg;
    wire [GW-1:0]          gnxt = (gsum < AGC_G_MIN) ? AGC_G_MIN[GW-1:0] :
                                  (gsum > AGC_G_MAX) ? AGC_G_MAX[GW-1:0] :
                                                       gsum[GW-1:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            g         <= AGC_G_INIT[GW-1:0];
            p         <= AGC_TARGET[PW-1:0];
            out_valid <= 1'b0;
            out_i     <= 16'sd0;
            out_q     <= 16'sd0;
        end else begin
            out_valid <= in_valid;
            if (in_valid) begin
                out_i <= yi;
                out_q <= yq;
                p     <= pnxt;
                g     <= gnxt;
            end
        end
    end

endmodule

`default_nettype wire
