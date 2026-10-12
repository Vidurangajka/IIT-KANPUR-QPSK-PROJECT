`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// fine_freq_rec - decision directed carrier phase / residual frequency
// tracking.
//
// The phase error detector is the angle of the derotated symbol taken modulo
// 90 degrees and centred on the 45 degree QPSK constellation points.  In the
// 16 bit turn format that is a subtract and a bit mask, it is exact, and it
// is completely independent of the signal amplitude.
//
// Rotation preserves angles, so the angle of the derotated symbol is just
//   angle(y) + rotation_angle
// and the CORDICs can both be feed forward.  Measuring the angle of the
// rotated symbol instead would put two CORDIC pipelines inside the loop and
// force the clock to be tens of times the symbol rate; this way the feedback
// path is a subtract, a mask and the loop filter.
// ---------------------------------------------------------------------------
`default_nettype none

module fine_freq_rec (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    output wire                 out_valid,
    output wire signed [15:0]   out_i,
    output wire signed [15:0]   out_q,

    output reg  signed [13:0]   err_dbg
);

`include "qpsk_defs.vh"

    localparam integer PHW = FF_PH_W;       // 24

    reg [PHW-1:0]      ph;
    reg signed [39:0]  integ;

    wire signed [15:0] ang = -$signed(ph[PHW-1:FF_PH_F]);

    // ---- feed forward derotation ----------------------------------------
    cordic_rot #(.UNIT_INPUT(0), .TAGW(1)) u_rot (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .x_i(in_i), .y_i(in_q), .z_i(ang), .tag_i(1'b0), .tag_o(),
        .out_valid(out_valid), .x_o(out_i), .y_o(out_q));

    // ---- angle of the input, with its rotation angle carried alongside ---
    wire               vo_v;
    wire signed [15:0] vo_z;
    wire [15:0]        vo_ang;

    cordic_vec #(.TAGW(16)) u_vec (
        .clk(clk), .rst_n(rst_n), .in_valid(in_valid),
        .x_i({{2{in_i[15]}}, in_i}), .y_i({{2{in_q[15]}}, in_q}),
        .tag_i(ang), .tag_o(vo_ang),
        .out_valid(vo_v), .z_o(vo_z));

    // ---- phase error and loop filter -------------------------------------
    wire signed [15:0] th_r = vo_z + $signed(vo_ang);   // angle after rotation
    wire signed [13:0] e    = th_r - $signed(FF_OFFS[15:0]);

    wire signed [39:0] integ_n = integ
                               + ((e * $signed(FF_KI_M[17:0])) >>> FF_KI_S);
    wire signed [39:0] prop    = (e * $signed(FF_KP_M[17:0])) >>> FF_KP_S;
    wire signed [39:0] inc     = prop + (integ_n >>> FF_INTEG_F);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ph      <= {PHW{1'b0}};
            integ   <= 40'sd0;
            err_dbg <= 14'sd0;
        end else if (vo_v) begin
            integ   <= integ_n;
            ph      <= ph + inc[PHW-1:0];
            err_dbg <= e;
        end
    end

endmodule

`default_nettype wire
