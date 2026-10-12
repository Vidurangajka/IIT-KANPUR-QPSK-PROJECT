`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// qpsk_channel - on-chip baseband channel for the loopback demo
//
//   x -> attenuate by 2**BASE_SHIFT
//     -> rotate by exp(j*(phase accumulator + phase offset))   carrier offset
//     -> add noise_sigma-scaled Gaussian noise                 AWGN
//     -> attenuate by 2**level                                 receive level
//
// The rotation reuses the receiver's pipelined cordic_rot, which has unit
// gain.  The phase accumulator advances once per input sample by fo_inc,
// with one turn = 2**32.  Noise is scaled as (g * noise_sigma) >> NOISE_SHIFT
// where g is the awgn_gen output; board_defs.vh holds sigma codes calibrated
// to Eb/N0 against the measured transmitter power.
//
// Latency is CORDIC_NITER + 5 clocks; samples may arrive every clock.
// ---------------------------------------------------------------------------
`default_nettype none

module qpsk_channel (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    input  wire [31:0]          fo_inc,
    input  wire [15:0]          phase_off,
    input  wire [15:0]          noise_sigma,
    input  wire [1:0]           level,

    output reg                  out_valid,
    output reg  signed [15:0]   out_i,
    output reg  signed [15:0]   out_q
);

`include "board_defs.vh"

    // ---- carrier: phase accumulator and rotation ------------------------
    reg [31:0] acc;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        acc <= 32'd0;
        else if (in_valid) acc <= acc + fo_inc;
    end

    wire signed [15:0] a_i = in_i >>> BASE_SHIFT;
    wire signed [15:0] a_q = in_q >>> BASE_SHIFT;
    wire signed [15:0] z   = acc[31:16] + phase_off;

    wire               r_valid;
    wire signed [15:0] r_i, r_q;

    cordic_rot #(.UNIT_INPUT(0), .TAGW(1)) u_rot (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .x_i(a_i), .y_i(a_q), .z_i(z), .tag_i(1'b0),
        .out_valid(r_valid), .tag_o(), .x_o(r_i), .y_o(r_q));

    // ---- noise ----------------------------------------------------------
    wire signed [20:0] g_i, g_q;
    awgn_gen u_awgn (.clk(clk), .rst_n(rst_n), .n_i(g_i), .n_q(g_q));

    localparam signed [37:0] NRND = 38'sd1 <<< (NOISE_SHIFT - 1);

    reg                v1;
    reg signed [15:0]  s1_i, s1_q;
    reg signed [37:0]  p_i, p_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            v1 <= 1'b0; s1_i <= 0; s1_q <= 0; p_i <= 0; p_q <= 0;
        end else begin
            v1   <= r_valid;
            s1_i <= r_i;
            s1_q <= r_q;
            p_i  <= g_i * $signed({1'b0, noise_sigma});
            p_q  <= g_q * $signed({1'b0, noise_sigma});
        end
    end

    // ---- sum, saturate, receive level -----------------------------------
    wire signed [37:0] nz_i = (p_i + NRND) >>> NOISE_SHIFT;
    wire signed [37:0] nz_q = (p_q + NRND) >>> NOISE_SHIFT;
    wire signed [37:0] t_i  = nz_i + s1_i;
    wire signed [37:0] t_q  = nz_q + s1_q;
    wire signed [15:0] c_i  = (t_i >  32767) ?  16'sd32767 :
                              (t_i < -32768) ? -16'sd32768 : t_i[15:0];
    wire signed [15:0] c_q  = (t_q >  32767) ?  16'sd32767 :
                              (t_q < -32768) ? -16'sd32768 : t_q[15:0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            out_valid <= 1'b0; out_i <= 0; out_q <= 0;
        end else begin
            out_valid <= v1;
            out_i     <= c_i >>> level;
            out_q     <= c_q >>> level;
        end
    end

endmodule

`default_nettype wire
