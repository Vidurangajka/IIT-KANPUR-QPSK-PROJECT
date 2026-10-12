`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// packet_detector - Barker preamble correlator with a dynamic threshold,
// peak picking and a post detection inhibit.
//
// The preamble symbols are A*b*(1+j) with b the Barker 13 code, so
// correlating against their conjugate needs no multipliers at all:
//
//   u = yI + yQ,  v = yQ - yI
//   cI = sum_k b[N-1-k] * u[n-k]      (a +-1 adder tree)
//   cQ = sum_k b[N-1-k] * v[n-k]
//
// and the constant A is absorbed into the threshold.  A perfectly received
// preamble gives |c|^2 = 2*N^2*Ps with Ps the mean symbol power, so the
// threshold is a fixed fraction of that, taken from a running sum of |y|^2
// over DET_WIN symbols.  Being relative to the measured signal power, the
// detector works unchanged over the whole receiver input level range.
//
// After the threshold is first crossed the strongest peak within
// DET_PEAK_WIN symbols is selected, and detection is then inhibited until
// just before the next packet is due, which suppresses mid packet peaks.
//
// All three stages advance on in_valid, so det_valid is always asserted on a
// symbol event: exactly DET_PIPE = 2 events after the symbol the golden
// model declares on.  det_age gives the distance back to the actual peak.
// ---------------------------------------------------------------------------
`default_nettype none

module packet_detector (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    output reg                  det_valid,
    output reg  [3:0]           det_age,
    output reg  signed [20:0]   det_cI,
    output reg  signed [20:0]   det_cQ
);

`include "qpsk_defs.vh"

    localparam integer NB   = PREAMBLE_SYMS;        // 13
    localparam integer NW   = 1 << DET_WIN_SHIFT;   // 32
    localparam integer CWD  = 21;                   // correlator output width
    localparam integer PWW  = 32;                   // |y|^2 width
    localparam integer RSW  = PWW + DET_WIN_SHIFT;  // running sum width
    localparam integer C2W  = 2*CWD + 1;            // |c|^2 width
    localparam integer THW  = RSW + 8;              // threshold width

    // ---- correlator -------------------------------------------------------
    // su[j] holds y[n-1-j]; the current symbol comes straight from u/v, so
    // correlator tap k is u for k = 0 and su[k-1] otherwise
    reg signed [16:0] su [0:NB-2];
    reg signed [16:0] sv [0:NB-2];
    wire signed [16:0] u = in_i + in_q;
    wire signed [16:0] v = in_q - in_i;

    wire [NB-1:0] bk = BARKER;

    integer k;
    reg signed [16:0]    tu, tv;
    reg signed [CWD-1:0] cI_c, cQ_c;
    always @(*) begin
        cI_c = {CWD{1'b0}};
        cQ_c = {CWD{1'b0}};
        for (k = 0; k < NB; k = k + 1) begin
            tu = (k == 0) ? u : su[k-1];
            tv = (k == 0) ? v : sv[k-1];
            if (bk[NB-1-k]) begin               // weight b[NB-1-k] = +1
                cI_c = cI_c + tu;
                cQ_c = cQ_c + tv;
            end else begin                      // weight -1
                cI_c = cI_c - tu;
                cQ_c = cQ_c - tv;
            end
        end
    end

    // ---- running power window --------------------------------------------
    reg [PWW-1:0] spw [0:NW-1];
    reg [RSW-1:0] runsum;
    wire [31:0]   sq_i = in_i * in_i;
    wire [31:0]   sq_q = in_q * in_q;
    wire [PWW-1:0] pw  = sq_i + sq_q;
    wire [RSW-1:0] rs_c = runsum + pw - spw[NW-1];

    // ---- pipeline registers (all advance on in_valid) --------------------
    reg                  a_v;
    reg signed [CWD-1:0] a_cI, a_cQ;
    reg [RSW-1:0]        a_rs;

    reg                  b_v;
    reg [C2W-1:0]        b_c2;
    reg [THW-1:0]        b_thr;
    reg signed [CWD-1:0] b_cI, b_cQ;

    wire [C2W-1:0] c2_c  = a_cI * a_cI + a_cQ * a_cQ;
    wire [THW-1:0] thr_c = (a_rs * DET_THR_NUM) >> DET_THR_SHIFT;

    // ---- peak picking -----------------------------------------------------
    reg                  searching;
    reg [3:0]            win;
    reg [C2W-1:0]        best_c2;
    reg [3:0]            best_i;
    reg signed [CWD-1:0] best_cI, best_cQ;
    reg [15:0]           inhibit;

    wire                 newbest = (b_c2 > best_c2);
    wire [3:0]           pk_i    = newbest ? win     : best_i;
    wire signed [CWD-1:0] pk_cI  = newbest ? b_cI    : best_cI;
    wire signed [CWD-1:0] pk_cQ  = newbest ? b_cQ    : best_cQ;

    integer m;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < NB-1; k = k + 1) begin
                su[k] <= 17'sd0;
                sv[k] <= 17'sd0;
            end
            for (m = 0; m < NW; m = m + 1)
                spw[m] <= {PWW{1'b0}};
            runsum    <= {RSW{1'b0}};
            a_v       <= 1'b0; a_cI <= 0; a_cQ <= 0; a_rs <= 0;
            b_v       <= 1'b0; b_c2 <= 0; b_thr <= 0; b_cI <= 0; b_cQ <= 0;
            searching <= 1'b0;
            win       <= 4'd0;
            best_c2   <= 0; best_i <= 4'd0; best_cI <= 0; best_cQ <= 0;
            inhibit   <= 16'd0;
            det_valid <= 1'b0;
            det_age   <= 4'd0;
            det_cI    <= 0; det_cQ <= 0;
        end else begin
            // det_valid is held until the next symbol event, so a consumer
            // that is itself clocked by in_valid always sees it
            if (in_valid) begin
                det_valid <= 1'b0;
                // ---- shift the correlator and power histories ------------
                for (k = NB-2; k > 0; k = k - 1) begin
                    su[k] <= su[k-1];
                    sv[k] <= sv[k-1];
                end
                su[0]  <= u;
                sv[0]  <= v;
                runsum <= rs_c;
                for (m = NW-1; m > 0; m = m - 1)
                    spw[m] <= spw[m-1];
                spw[0] <= pw;

                // ---- stage A: correlator value for this symbol -----------
                a_v  <= 1'b1;
                a_cI <= cI_c;
                a_cQ <= cQ_c;
                a_rs <= rs_c;

                // ---- stage B: magnitude squared and threshold ------------
                b_v   <= a_v;
                b_c2  <= c2_c;
                b_thr <= thr_c;
                b_cI  <= a_cI;
                b_cQ  <= a_cQ;

                // ---- stage C: threshold crossing and peak pick -----------
                if (b_v) begin
                    if (inhibit != 0) begin
                        inhibit <= inhibit - 1'b1;
                    end else if (!searching) begin
                        if (b_c2 > b_thr) begin
                            searching <= 1'b1;
                            win       <= 4'd1;
                            best_c2   <= b_c2;
                            best_i    <= 4'd0;
                            best_cI   <= b_cI;
                            best_cQ   <= b_cQ;
                        end
                    end else begin
                        if (win == DET_PEAK_WIN - 1) begin
                            det_valid <= 1'b1;
                            det_age   <= (DET_PEAK_WIN - 1) - pk_i;
                            det_cI    <= pk_cI;
                            det_cQ    <= pk_cQ;
                            searching <= 1'b0;
                            inhibit   <= DET_INHIBIT[15:0];
                            win       <= 4'd0;
                        end else begin
                            win <= win + 1'b1;
                            if (newbest) begin
                                best_c2 <= b_c2;
                                best_i  <= win;
                                best_cI <= b_cI;
                                best_cQ <= b_cQ;
                            end
                        end
                    end
                end
            end
        end
    end

endmodule

`default_nettype wire
