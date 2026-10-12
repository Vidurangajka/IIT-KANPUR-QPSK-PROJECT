`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// cordic_vec - pipelined CORDIC vectoring (atan2)
//
//   z_o = angle(x_i + j*y_i)  in the 16 bit turn format
//
// Only the ratio of the inputs matters, so the caller is free to scale a wide
// accumulator down into the VEC_IN_W bit input.  The magnitude output is not
// produced: nothing in this design needs it, and leaving it out saves the
// gain compensation.
//
// Latency: CORDIC_NITER + 2 clocks, fully pipelined.
// ---------------------------------------------------------------------------
`default_nettype none

module cordic_vec #(
    parameter TAGW = 1              // user bits carried alongside the data
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 in_valid,
    input  wire signed [17:0]   x_i,        // VEC_IN_W bits
    input  wire signed [17:0]   y_i,
    input  wire [TAGW-1:0]      tag_i,
    output wire                 out_valid,
    output wire [TAGW-1:0]      tag_o,
    output wire signed [15:0]   z_o
);

`include "qpsk_defs.vh"

    localparam integer N  = CORDIC_NITER;
    localparam integer CW = CORDIC_W;
    localparam integer ZW = AW + 2;
    localparam signed [ZW-1:0] QUARTER = 1 <<< (AW - 2);

    // ---- stage 0: fold into the right half plane ------------------------
    reg                 v0;
    reg signed [CW-1:0] x0, y0;
    reg signed [ZW-1:0] z0;

    wire signed [CW-1:0] xe = {{(CW-VEC_IN_W){x_i[VEC_IN_W-1]}}, x_i[VEC_IN_W-1:0]};
    wire signed [CW-1:0] ye = {{(CW-VEC_IN_W){y_i[VEC_IN_W-1]}}, y_i[VEC_IN_W-1:0]};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v0 <= 1'b0; x0 <= 0; y0 <= 0; z0 <= 0;
        end else begin
            v0 <= in_valid;
            if (xe[CW-1]) begin                 // x < 0
                if (!ye[CW-1]) begin            //   y >= 0 : rotate by -90
                    x0 <=  ye;
                    y0 <= -xe;
                    z0 <=  QUARTER;
                end else begin                  //   y <  0 : rotate by +90
                    x0 <= -ye;
                    y0 <=  xe;
                    z0 <= -QUARTER;
                end
            end else begin
                x0 <= xe;
                y0 <= ye;
                z0 <= {ZW{1'b0}};
            end
        end
    end

    // ---- CORDIC iterations ----------------------------------------------
    reg                 vp [0:N];
    reg signed [CW-1:0] xp [0:N];
    reg signed [CW-1:0] yp [0:N];
    reg signed [ZW-1:0] zp [0:N];

    always @(*) begin
        vp[0] = v0; xp[0] = x0; yp[0] = y0; zp[0] = z0;
    end

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : g_iter
            wire signed [CW-1:0] xs = xp[i] >>> i;
            wire signed [CW-1:0] ys = yp[i] >>> i;
            wire signed [AW-1:0] at = CORDIC_ATAN[AW*i +: AW];
            wire                 dneg = !yp[i][CW-1];  // d = -1 when y >= 0

            reg                 vr;
            reg signed [CW-1:0] xr, yr;
            reg signed [ZW-1:0] zr;
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    vr <= 1'b0; xr <= 0; yr <= 0; zr <= 0;
                end else begin
                    vr <= vp[i];
                    if (dneg) begin             // d = -1
                        xr <= xp[i] + ys;
                        yr <= yp[i] - xs;
                        zr <= zp[i] + $signed({{(ZW-AW){at[AW-1]}}, at});
                    end else begin              // d = +1
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

    // ---- output ----------------------------------------------------------
    reg                 vo;
    reg signed [15:0]   zo;
    wire signed [ZW-1:0] zf = zp[N];
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vo <= 1'b0; zo <= 0;
        end else begin
            vo <= vp[N];
            zo <= (zf >  32767) ?  16'sd32767 :
                  (zf < -32768) ? -16'sd32768 : zf[15:0];
        end
    end

    // ---- tag pipeline, matched to the data latency -----------------------
    localparam integer LAT = N + 2;         // stage0, N iterations, output
    reg [TAGW-1:0] tagpipe [0:LAT-1];
    integer t;
    always @(posedge clk) begin
        tagpipe[0] <= tag_i;
        for (t = 1; t < LAT; t = t + 1)
            tagpipe[t] <= tagpipe[t-1];
    end

    assign out_valid = vo;
    assign z_o = zo;
    assign tag_o = tagpipe[LAT-1];

endmodule

`default_nettype wire
