`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// cordic_rot - pipelined CORDIC rotation
//
//   (x_o, y_o) = (x_i + j*y_i) * exp(j*2*pi*z_i/65536)
//
// Angles use the 16 bit turn format: one full turn is 2**16, so the signed
// input covers [-180, +180) degrees and arithmetic on angles wraps for free.
// Data is Q1.15.  The CORDIC processing gain is removed by pre-scaling the
// input by 1/K, so the output comes back at unit gain.
//
// Latency: CORDIC_NITER + 3 clocks, fully pipelined, one result per clock.
// ---------------------------------------------------------------------------
`default_nettype none

module cordic_rot #(
    parameter UNIT_INPUT = 0,       // 1: ignore x_i/y_i and rotate (1, 0),
                                    //    which needs no pre-scale multiplier
    parameter TAGW       = 1        // user bits carried alongside the data
) (
    input  wire                     clk,
    input  wire                     rst_n,
    input  wire                     in_valid,
    input  wire signed [15:0]       x_i,
    input  wire signed [15:0]       y_i,
    input  wire signed [15:0]       z_i,
    input  wire [TAGW-1:0]          tag_i,
    output wire                     out_valid,
    output wire [TAGW-1:0]          tag_o,
    output wire signed [15:0]       x_o,
    output wire signed [15:0]       y_o
);

`include "qpsk_defs.vh"

    localparam integer N   = CORDIC_NITER;
    localparam integer CW  = CORDIC_W;       // internal x/y width
    localparam integer ZW  = AW + 2;         // internal angle width
    localparam integer SH  = CORDIC_F - FRAC; // input alignment shift
    localparam signed [ZW-1:0] QUARTER = 1 <<< (AW - 2);

    // ---- stage 0: pre-scale by 1/K --------------------------------------
    reg                   v0;
    reg signed [CW-1:0]   x0, y0;
    reg signed [ZW-1:0]   z0;

    // round half up, then align into the internal fractional format.
    // Note the explicit $signed and arithmetic shift: a part select would be
    // unsigned and would silently drop the sign.
    wire signed [32:0] px = $signed(x_i) * $signed(CORDIC_KINV);
    wire signed [32:0] py = $signed(y_i) * $signed(CORDIC_KINV);
    wire signed [32:0] sx = (px + 33'sd16384) >>> 15;
    wire signed [32:0] sy = (py + 33'sd16384) >>> 15;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0 <= 1'b0; x0 <= 0; y0 <= 0; z0 <= 0;
        end else begin
            v0 <= in_valid;
            if (UNIT_INPUT) begin
                x0 <= $signed({{(CW-16){1'b0}}, CORDIC_KINV}) <<< SH;
                y0 <= {CW{1'b0}};
            end else begin
                x0 <= $signed(sx) <<< SH;
                y0 <= $signed(sy) <<< SH;
            end
            z0 <= $signed({{(ZW-AW){z_i[AW-1]}}, z_i});
        end
    end

    // ---- stage 1: fold the angle into the convergence range -------------
    // one quadrant step is enough because 90 + 99.9 > 180
    reg                   v1;
    reg signed [CW-1:0]   x1, y1;
    reg signed [ZW-1:0]   z1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; x1 <= 0; y1 <= 0; z1 <= 0;
        end else begin
            v1 <= v0;
            if (z0 > QUARTER) begin             // pre-rotate by +90 degrees
                x1 <= -y0;
                y1 <=  x0;
                z1 <=  z0 - QUARTER;
            end else if (z0 < -QUARTER) begin   // pre-rotate by -90 degrees
                x1 <=  y0;
                y1 <= -x0;
                z1 <=  z0 + QUARTER;
            end else begin
                x1 <= x0;
                y1 <= y0;
                z1 <= z0;
            end
        end
    end

    // ---- CORDIC iterations ----------------------------------------------
    reg                 vp [0:N];
    reg signed [CW-1:0] xp [0:N];
    reg signed [CW-1:0] yp [0:N];
    reg signed [ZW-1:0] zp [0:N];

    integer k;
    always @(*) begin
        vp[0] = v1; xp[0] = x1; yp[0] = y1; zp[0] = z1;
    end

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_iter
            wire signed [CW-1:0] xs = xp[i] >>> i;
            wire signed [CW-1:0] ys = yp[i] >>> i;
            wire signed [AW-1:0] at = CORDIC_ATAN[AW*i +: AW];
            wire                 dneg = zp[i][ZW-1];   // d = -1 when z < 0

            reg                 vr;
            reg signed [CW-1:0] xr, yr;
            reg signed [ZW-1:0] zr;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    vr <= 1'b0; xr <= 0; yr <= 0; zr <= 0;
                end else begin
                    vr <= vp[i];
                    if (dneg) begin
                        xr <= xp[i] + ys;
                        yr <= yp[i] - xs;
                        zr <= zp[i] + $signed({{(ZW-AW){at[AW-1]}}, at});
                    end else begin
                        xr <= xp[i] - ys;
                        yr <= yp[i] + xs;
                        zr <= zp[i] - $signed({{(ZW-AW){at[AW-1]}}, at});
                    end
                end
            end
            always @(*) begin
                vp[i+1] = vr; xp[i+1] = xr; yp[i+1] = yr; zp[i+1] = zr;
            end
        end
    endgenerate

    // ---- output: round back to Q1.15 and saturate ------------------------
    wire signed [CW-1:0] xf = xp[N];
    wire signed [CW-1:0] yf = yp[N];
    wire signed [CW:0]   xr_ = ($signed({xf[CW-1], xf})
                                + $signed({{CW{1'b0}}, 1'b1} <<< (SH-1))) >>> SH;
    wire signed [CW:0]   yr_ = ($signed({yf[CW-1], yf})
                                + $signed({{CW{1'b0}}, 1'b1} <<< (SH-1))) >>> SH;

    reg                 vo;
    reg signed [15:0]   xo, yo;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vo <= 1'b0; xo <= 0; yo <= 0;
        end else begin
            vo <= vp[N];
            xo <= (xr_ >  32767) ?  16'sd32767 :
                  (xr_ < -32768) ? -16'sd32768 : xr_[15:0];
            yo <= (yr_ >  32767) ?  16'sd32767 :
                  (yr_ < -32768) ? -16'sd32768 : yr_[15:0];
        end
    end

    // ---- tag pipeline, matched to the data latency -----------------------
    localparam integer LAT = N + 3;         // stage0, prerotate, N iters, out
    reg [TAGW-1:0] tagpipe [0:LAT-1];
    integer t;
    always @(posedge clk) begin
        tagpipe[0] <= tag_i;
        for (t = 1; t < LAT; t = t + 1)
            tagpipe[t] <= tagpipe[t-1];
    end

    assign out_valid = vo;
    assign x_o = xo;
    assign y_o = yo;
    assign tag_o = tagpipe[LAT-1];

endmodule

`default_nettype wire
