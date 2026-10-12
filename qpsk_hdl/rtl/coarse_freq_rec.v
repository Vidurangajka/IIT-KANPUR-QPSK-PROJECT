`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// coarse_freq_rec - fourth power carrier frequency estimator with feed
// forward NCO correction.
//
// For QPSK the data modulation is removed by raising the signal to the
// fourth power.  Rather than computing y**4, which grows the word length
// fast, the estimator works in the phase domain:
//
//   theta[n] = angle(y[n])                       (CORDIC vectoring)
//   d4[n]    = wrap(4*(theta[n] - theta[n-1]))   (a shift; wraps for free in
//                                                 the 16 bit turn format)
//   acc     += exp(j*d4[n])                      (CORDIC rotation of (1,0))
//
// Summing unit vectors is the magnitude normalised form of
// sum(z[n]*conj(z[n-1])) with z = y**4, so the estimate is unbiased but the
// accumulator only grows as log2 of the block length.  At the end of a block
// of CF_BLK symbols the angle of the accumulator divided by four is the
// frequency offset in turns per symbol.
//
// Nothing here sits in a feedback loop, so the CORDIC latency is free.  The
// block estimate is ready a couple of symbols after the block ends; it is
// held in `pending` and applied at the symbol whose index is congruent to
// CF_GUARD modulo CF_BLK, which makes the update a symbol aligned event that
// the golden model reproduces exactly.
//
// The first CF_FAST_BLK estimates are applied in full for fast acquisition;
// after that the NCO rate is updated through a first order filter, which
// removes the estimate-to-estimate jitter that otherwise makes the fine
// frequency loop slip a quadrant at low SNR.
// ---------------------------------------------------------------------------
`default_nettype none

module coarse_freq_rec (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    output wire                 out_valid,
    output wire signed [15:0]   out_i,
    output wire signed [15:0]   out_q,

    output reg  signed [23:0]   frate_dbg   // NCO rate, Q0.24 turns/symbol
);

`include "qpsk_defs.vh"

    localparam integer PHW = CF_PH_W;       // 24
    localparam integer ACW = CF_ACC_W;      // 25

    // =====================================================================
    //  NCO and feed forward rotation
    // =====================================================================
    reg [PHW-1:0]      ph;
    reg signed [PHW-1:0] frate;
    reg signed [PHW-1:0] pending;
    reg                have_pending;
    reg [CF_BLK_W-1:0] scnt;                // symbol index modulo CF_BLK
    reg [15:0]         nblk;

    wire signed [15:0] rot_ang = -$signed(ph[PHW-1:CF_PH_F]);

    cordic_rot #(.UNIT_INPUT(0), .TAGW(1)) u_rot (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .x_i(in_i), .y_i(in_q), .z_i(rot_ang), .tag_i(1'b0), .tag_o(),
        .out_valid(out_valid), .x_o(out_i), .y_o(out_q));

    // =====================================================================
    //  phase domain estimator
    // =====================================================================
    // one vectoring CORDIC serves both the per symbol angle (tag 0) and the
    // once per block accumulator angle (tag 1); they are hundreds of clocks
    // apart so a single unit is plenty
    reg                blk_req;
    reg signed [17:0]  blk_x, blk_y;

    wire               vec_sel = blk_req && !in_valid;
    wire               vec_v   = in_valid || vec_sel;
    wire signed [17:0] vec_x   = vec_sel ? blk_x : {{2{in_i[15]}}, in_i};
    wire signed [17:0] vec_y   = vec_sel ? blk_y : {{2{in_q[15]}}, in_q};

    wire               vo_v;
    wire               vo_tag;
    wire signed [15:0] vo_z;

    cordic_vec #(.TAGW(1)) u_vec (
        .clk(clk), .rst_n(rst_n), .in_valid(vec_v),
        .x_i(vec_x), .y_i(vec_y), .tag_i(vec_sel),
        .out_valid(vo_v), .tag_o(vo_tag), .z_o(vo_z));

    // ---- theta difference, times four ------------------------------------
    reg signed [15:0] th_prev;
    reg               have_prev;

    wire signed [15:0] d4 = (vo_z - th_prev) <<< 2;     // wraps in 16 bits
    wire               d4_v = vo_v && !vo_tag && have_prev;

    wire               uo_v;
    wire signed [15:0] uo_x, uo_y;

    cordic_rot #(.UNIT_INPUT(1), .TAGW(1)) u_unit (
        .clk(clk), .rst_n(rst_n), .in_valid(d4_v),
        .x_i(16'sd0), .y_i(16'sd0), .z_i(d4), .tag_i(1'b0), .tag_o(),
        .out_valid(uo_v), .x_o(uo_x), .y_o(uo_y));

    // ---- block accumulator -----------------------------------------------
    reg signed [ACW-1:0]   accI, accQ;
    reg [CF_BLK_W:0]       acc_cnt;

    wire                   blk_end = uo_v && (acc_cnt == CF_BLK - 1);

    // ---- rate update -----------------------------------------------------
    wire signed [PHW-1:0]  fest    = $signed({{(PHW-AW){vo_z[AW-1]}}, vo_z})
                                     >>> 2;
    wire signed [PHW-1:0]  tgt     = fest <<< CF_PH_F;
    wire                   apply   = in_valid && have_pending
                                     && (scnt == CF_GUARD);
    wire signed [PHW-1:0]  frate_n = (nblk < CF_FAST_BLK)
                                     ? pending
                                     : frate + ((pending - frate)
                                                >>> CF_SLOW_SHIFT);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph           <= {PHW{1'b0}};
            frate        <= {PHW{1'b0}};
            pending      <= {PHW{1'b0}};
            have_pending <= 1'b0;
            scnt         <= {CF_BLK_W{1'b0}};
            nblk         <= 16'd0;
            th_prev      <= 16'sd0;
            have_prev    <= 1'b0;
            accI         <= 0;
            accQ         <= 0;
            acc_cnt      <= 0;
            blk_req      <= 1'b0;
            blk_x        <= 18'sd0;
            blk_y        <= 18'sd0;
            frate_dbg    <= 24'sd0;
        end else begin
            // --- per symbol: advance the NCO, count symbols ---------------
            if (in_valid) begin
                ph   <= ph + frate[PHW-1:0];
                scnt <= (scnt == CF_BLK - 1) ? {CF_BLK_W{1'b0}}
                                             : (scnt + 1'b1);
                if (apply) begin
                    frate        <= frate_n;
                    frate_dbg    <= frate_n;
                    nblk         <= nblk + 1'b1;
                    have_pending <= 1'b0;
                end
            end

            // --- per symbol angle -----------------------------------------
            if (vo_v && !vo_tag) begin
                th_prev   <= vo_z;
                have_prev <= 1'b1;
            end

            // --- accumulate unit vectors ----------------------------------
            if (uo_v) begin
                if (blk_end) begin
                    // latch the completed sum and restart
                    blk_x   <= (accI + uo_x) >>> CF_ACC_SH;
                    blk_y   <= (accQ + uo_y) >>> CF_ACC_SH;
                    blk_req <= 1'b1;
                    accI    <= 0;
                    accQ    <= 0;
                    acc_cnt <= 0;
                end else begin
                    accI    <= accI + uo_x;
                    accQ    <= accQ + uo_y;
                    acc_cnt <= acc_cnt + 1'b1;
                end
            end

            // --- issue the block angle request ----------------------------
            if (vec_sel) blk_req <= 1'b0;

            // --- capture the block result ---------------------------------
            if (vo_v && vo_tag) begin
                pending      <= tgt;
                have_pending <= 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
