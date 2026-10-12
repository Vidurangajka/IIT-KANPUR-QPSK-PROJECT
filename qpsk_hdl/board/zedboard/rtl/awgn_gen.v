`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// awgn_gen - approximately Gaussian noise, one I/Q pair at a time
//
// Each rail is the sum of 16 signed 16 bit uniforms (Irwin-Hall), taken from
// a 64 bit xorshift generator four at a time over four clocks.  The sum has
// standard deviation sqrt(16 * 2**32 / 12) = 75674 LSB and its tails reach
// 6.9 sigma, which is ample for BER down to 1e-6.
//
// A finished pair is latched every four clocks into n_i / n_q.  A consumer
// that samples them less often than that (the channel samples once every
// CLKS_PER_SAMPLE clocks) always sees a pair built from fresh uniforms, so
// successive noise samples are independent.
// ---------------------------------------------------------------------------
`default_nettype none

module awgn_gen #(
    parameter [63:0] SEED_I = 64'h9E37_79B9_7F4A_7C15,
    parameter [63:0] SEED_Q = 64'hD1B5_4A32_D192_ED03
) (
    input  wire                 clk,
    input  wire                 rst_n,
    output reg  signed [20:0]   n_i,
    output reg  signed [20:0]   n_q
);

    function [63:0] xorshift64(input [63:0] s);
        reg [63:0] t;
        begin
            t = s ^ (s << 13);
            t = t ^ (t >> 7);
            xorshift64 = t ^ (t << 17);
        end
    endfunction

    function signed [17:0] sum4(input [63:0] r);
        sum4 = $signed(r[15:0])  + $signed(r[31:16])
             + $signed(r[47:32]) + $signed(r[63:48]);
    endfunction

    reg [63:0]         si, sq;
    reg signed [20:0]  ai, aq;
    reg [1:0]          cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            si  <= SEED_I;
            sq  <= SEED_Q;
            ai  <= 0;
            aq  <= 0;
            cnt <= 2'd0;
            n_i <= 0;
            n_q <= 0;
        end else begin
            si  <= xorshift64(si);
            sq  <= xorshift64(sq);
            cnt <= cnt + 1'b1;
            if (cnt == 2'd3) begin
                n_i <= ai + sum4(si);
                n_q <= aq + sum4(sq);
                ai  <= 0;
                aq  <= 0;
            end else begin
                ai  <= ai + sum4(si);
                aq  <= aq + sum4(sq);
            end
        end
    end

endmodule

`default_nettype wire
