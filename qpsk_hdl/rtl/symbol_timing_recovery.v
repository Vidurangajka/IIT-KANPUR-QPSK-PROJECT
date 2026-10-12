`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// symbol_timing_recovery - Gardner timing error detector, cubic Farrow
// interpolator and a modulo-1 decrementing NCO.
//
// The NCO runs at two strobes per symbol: the on time strobe and the half
// symbol strobe the Gardner detector needs.  Only the on time strobes are
// output, so the output rate is Rsym and the sample rate drops by SPS.
//
//   w      = W_NOM + vctl                 control word, Q0.16
//   strobe = cnt < w                      modulo-1 underflow
//   mu     = cnt / w  ~= cnt * SPS/2      fractional interval
//   cnt   <= (cnt - w) mod 1
//
// mu is formed as a shift rather than a divide: w only ever departs from
// W_NOM by the small loop correction, so cnt*(1/W_NOM) is accurate to the
// same order as the loop error itself.
//
// Timing requirement: the loop filter result must be ready before the next
// input sample, which is 8 clocks after the sample that produced it.  The
// receiver therefore needs at least RX_MIN_CPS clocks between input samples.
// ---------------------------------------------------------------------------
`default_nettype none

module symbol_timing_recovery (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    output reg                  sym_valid,
    output reg  signed [15:0]   sym_i,
    output reg  signed [15:0]   sym_q,
    output wire [15:0]          mu_dbg
);

`include "qpsk_defs.vh"

    localparam signed [20:0] K6   = STR_K6;
    localparam signed [40:0] RND16 = (1 <<< 15);        // round for >>16
    localparam signed [40:0] RND15 = (1 <<< 14);        // round for >>15

    // =====================================================================
    //  NCO and strobe generation
    // =====================================================================
    reg  [STR_CW-1:0]  cnt;
    reg  signed [17:0] vctl;
    reg                ontime;

    wire signed [18:0] w     = $signed({2'b00, STR_W_NOM[STR_CW-1:0]}) + vctl;
    wire [STR_CW-1:0]  wu    = w[STR_CW-1:0];
    wire               strobe = in_valid && ({1'b0, cnt} < w[STR_CW:0]);
    wire [STR_CW:0]    mu_x  = {1'b0, cnt} << STR_MU_SH;
    wire [15:0]        mu    = mu_x[STR_CW] ? 16'hFFFF : mu_x[15:0];

    assign mu_dbg = mu;

    // =====================================================================
    //  input delay line: v0..v3 = x[n-3] .. x[n]
    // =====================================================================
    reg signed [15:0] x1i, x2i, x3i;        // x[n-1], x[n-2], x[n-3]
    reg signed [15:0] x1q, x2q, x3q;

    wire signed [15:0] v3i = in_i, v2i = x1i, v1i = x2i, v0i = x3i;
    wire signed [15:0] v3q = in_q, v2q = x1q, v1q = x2q, v0q = x3q;

    // =====================================================================
    //  Farrow stage 1: the integer combinations, one multiply by 1/6 later
    //     t3 = -v0 + 3v1 - 3v2 + v3      t2 = v0 - 2v1 + v2
    //     t1 = -2v0 - 3v1 + 6v2 - v3     c0 = v1
    // =====================================================================
    wire signed [19:0] t3i = -v0i + 3*v1i - 3*v2i + v3i;
    wire signed [19:0] t2i =  v0i - 2*v1i + v2i;
    wire signed [19:0] t1i = -2*v0i - 3*v1i + 6*v2i - v3i;
    wire signed [19:0] t3q = -v0q + 3*v1q - 3*v2q + v3q;
    wire signed [19:0] t2q =  v0q - 2*v1q + v2q;
    wire signed [19:0] t1q = -2*v0q - 3*v1q + 6*v2q - v3q;

    reg                f1_v, f1_ot;
    reg  [15:0]        f1_mu;
    reg  signed [19:0] f1_t3i, f1_t2i, f1_t1i, f1_t3q, f1_t2q, f1_t1q;
    reg  signed [15:0] f1_c0i, f1_c0q;

    // ---- Farrow stage 2: c3 = t3/6, c2 = t2/2, c1 = t1/6 -----------------
    wire signed [40:0] m3i = f1_t3i * K6;
    wire signed [40:0] m1i = f1_t1i * K6;
    wire signed [40:0] m3q = f1_t3q * K6;
    wire signed [40:0] m1q = f1_t1q * K6;

    reg                f2_v, f2_ot;
    reg  [15:0]        f2_mu;
    reg  signed [20:0] f2_c3i, f2_c2i, f2_c1i, f2_c3q, f2_c2q, f2_c1q;
    reg  signed [15:0] f2_c0i, f2_c0q;

    // ---- Farrow stage 3..5: Horner in mu ---------------------------------
    wire signed [16:0] mus   = {1'b0, f2_mu};           // unsigned -> signed
    wire signed [40:0] h3i   = f2_c3i * mus;
    wire signed [40:0] h3q   = f2_c3q * mus;

    reg                f3_v, f3_ot;
    reg  [15:0]        f3_mu;
    reg  signed [21:0] f3_ai, f3_aq;
    reg  signed [20:0] f3_c1i, f3_c1q;
    reg  signed [15:0] f3_c0i, f3_c0q;

    wire signed [16:0] mus3  = {1'b0, f3_mu};
    wire signed [40:0] h4i   = f3_ai * mus3;
    wire signed [40:0] h4q   = f3_aq * mus3;

    reg                f4_v, f4_ot;
    reg  [15:0]        f4_mu;
    reg  signed [22:0] f4_bi, f4_bq;
    reg  signed [15:0] f4_c0i, f4_c0q;

    wire signed [16:0] mus4  = {1'b0, f4_mu};
    wire signed [40:0] h5i   = f4_bi * mus4;
    wire signed [40:0] h5q   = f4_bq * mus4;
    wire signed [23:0] ci    = ((h5i + RND16) >>> 16) + f4_c0i;
    wire signed [23:0] cq    = ((h5q + RND16) >>> 16) + f4_c0q;

    reg                f5_v, f5_ot;
    reg  signed [15:0] f5_i, f5_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= {STR_CW{1'b0}};
            ontime <= 1'b1;
            x1i <= 0; x2i <= 0; x3i <= 0;
            x1q <= 0; x2q <= 0; x3q <= 0;
            f1_v <= 0; f2_v <= 0; f3_v <= 0; f4_v <= 0; f5_v <= 0;
            f1_ot <= 0; f2_ot <= 0; f3_ot <= 0; f4_ot <= 0; f5_ot <= 0;
            f1_mu <= 0; f2_mu <= 0; f3_mu <= 0; f4_mu <= 0;
            f1_t3i <= 0; f1_t2i <= 0; f1_t1i <= 0;
            f1_t3q <= 0; f1_t2q <= 0; f1_t1q <= 0;
            f1_c0i <= 0; f1_c0q <= 0;
            f2_c3i <= 0; f2_c2i <= 0; f2_c1i <= 0; f2_c0i <= 0;
            f2_c3q <= 0; f2_c2q <= 0; f2_c1q <= 0; f2_c0q <= 0;
            f3_ai <= 0; f3_aq <= 0; f3_c1i <= 0; f3_c1q <= 0;
            f3_c0i <= 0; f3_c0q <= 0;
            f4_bi <= 0; f4_bq <= 0; f4_c0i <= 0; f4_c0q <= 0;
            f5_i <= 0; f5_q <= 0;
        end else begin
            // --- NCO ------------------------------------------------------
            if (in_valid) begin
                cnt    <= cnt - wu;              // modulo 2**STR_CW
                x1i <= in_i; x2i <= x1i; x3i <= x2i;
                x1q <= in_q; x2q <= x1q; x3q <= x2q;
                if (strobe) ontime <= ~ontime;
            end

            // --- Farrow stage 1 -------------------------------------------
            f1_v   <= strobe;
            f1_ot  <= ontime;
            f1_mu  <= mu;
            f1_t3i <= t3i; f1_t2i <= t2i; f1_t1i <= t1i; f1_c0i <= v1i;
            f1_t3q <= t3q; f1_t2q <= t2q; f1_t1q <= t1q; f1_c0q <= v1q;

            // --- Farrow stage 2 -------------------------------------------
            f2_v   <= f1_v;
            f2_ot  <= f1_ot;
            f2_mu  <= f1_mu;
            f2_c3i <= (m3i + RND15) >>> 15;
            f2_c1i <= (m1i + RND15) >>> 15;
            f2_c2i <= (f1_t2i + 20'sd1) >>> 1;
            f2_c0i <= f1_c0i;
            f2_c3q <= (m3q + RND15) >>> 15;
            f2_c1q <= (m1q + RND15) >>> 15;
            f2_c2q <= (f1_t2q + 20'sd1) >>> 1;
            f2_c0q <= f1_c0q;

            // --- Farrow stage 3: a = (c3*mu) + c2 -------------------------
            f3_v   <= f2_v;
            f3_ot  <= f2_ot;
            f3_mu  <= f2_mu;
            f3_ai  <= ((h3i + RND16) >>> 16) + f2_c2i;
            f3_aq  <= ((h3q + RND16) >>> 16) + f2_c2q;
            f3_c1i <= f2_c1i; f3_c1q <= f2_c1q;
            f3_c0i <= f2_c0i; f3_c0q <= f2_c0q;

            // --- Farrow stage 4: b = (a*mu) + c1 --------------------------
            f4_v   <= f3_v;
            f4_ot  <= f3_ot;
            f4_mu  <= f3_mu;
            f4_bi  <= ((h4i + RND16) >>> 16) + f3_c1i;
            f4_bq  <= ((h4q + RND16) >>> 16) + f3_c1q;
            f4_c0i <= f3_c0i; f4_c0q <= f3_c0q;

            // --- Farrow stage 5: y = (b*mu) + c0 --------------------------
            f5_v   <= f4_v;
            f5_ot  <= f4_ot;
            f5_i   <= (ci >  32767) ?  16'sd32767 :
                      (ci < -32768) ? -16'sd32768 : ci[15:0];
            f5_q   <= (cq >  32767) ?  16'sd32767 :
                      (cq < -32768) ? -16'sd32768 : cq[15:0];
        end
    end

    // =====================================================================
    //  Gardner detector and loop filter
    //     e = mid_i*(y_i - prev_i) + mid_q*(y_q - prev_q)
    // =====================================================================
    reg signed [15:0] midI, midQ, prvI, prvQ;

    wire signed [16:0] dI = f5_i - prvI;
    wire signed [16:0] dQ = f5_q - prvQ;
    wire signed [34:0] eI = midI * dI;
    wire signed [34:0] eQ = midQ * dQ;
    wire signed [35:0] e  = eI + eQ;                    // Q.30
    wire signed [21:0] es = e >>> STR_E_SH;             // Q.16

    reg                ted_v;
    reg signed [21:0]  ted_e;

    reg signed [39:0]  integ;
    wire signed [39:0] integ_n = integ + ((ted_e * $signed(STR_KI_M[17:0]))
                                          >>> STR_KI_S);
    wire signed [39:0] prop    = (ted_e * $signed(STR_KP_M[17:0])) >>> STR_KP_S;
    wire signed [39:0] vsum    = prop + (integ_n >>> STR_INTEG_F);
    wire signed [17:0] vclamp  = (vsum >  STR_VCTL_LIM) ?  STR_VCTL_LIM[17:0] :
                                 (vsum < -STR_VCTL_LIM) ? -STR_VCTL_LIM[17:0] :
                                                          vsum[17:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            midI <= 0; midQ <= 0; prvI <= 0; prvQ <= 0;
            ted_v <= 1'b0; ted_e <= 0;
            integ <= 0; vctl <= 18'sd0;
            sym_valid <= 1'b0; sym_i <= 0; sym_q <= 0;
        end else begin
            // capture the interpolator results as they emerge, in order
            ted_v     <= 1'b0;
            sym_valid <= 1'b0;
            if (f5_v) begin
                if (f5_ot) begin
                    ted_e     <= es;
                    ted_v     <= 1'b1;
                    prvI      <= f5_i;
                    prvQ      <= f5_q;
                    sym_valid <= 1'b1;
                    sym_i     <= f5_i;
                    sym_q     <= f5_q;
                end else begin
                    midI <= f5_i;
                    midQ <= f5_q;
                end
            end
            if (ted_v) begin
                integ <= integ_n;
                vctl  <= vclamp;
            end
        end
    end

endmodule

`default_nettype wire
