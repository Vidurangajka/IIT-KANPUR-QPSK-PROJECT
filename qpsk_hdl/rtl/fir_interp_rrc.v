`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// fir_interp_rrc - root raised cosine pulse shaping filter, interpolate by SPS
//
// Polyphase structure: the 44 tap prototype (41 real taps zero padded to a
// multiple of SPS) is split into SPS phases of TX_NTAP_P taps.  The symbol
// delay line advances once per symbol and one output sample is produced every
// clock, so only TX_NTAP_P complex multiplies are needed rather than the full
// 44.
//
// sym_req is raised during the last sample phase of a symbol so the source
// has the next symbol ready when the delay line shifts.
// ---------------------------------------------------------------------------
`default_nettype none

module fir_interp_rrc (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 en,

    output wire                 sym_req,
    input  wire                 sym_stall,
    input  wire signed [15:0]   sym_i,
    input  wire signed [15:0]   sym_q,
    input  wire                 sym_valid,

    output reg                  out_valid,
    output reg  signed [15:0]   out_i,
    output reg  signed [15:0]   out_q
);

`include "qpsk_defs.vh"

    localparam integer NT   = TX_NTAP_P;          // 11
    localparam integer PW   = $clog2(SPS);        // 2
    localparam integer ACCW = 2*W + 4;            // 36, room for 11 products

    // ---- sample phase ----------------------------------------------------
    localparam signed [ACCW-1:0] RND = (1 <<< (FRAC-1));

    reg [PW-1:0] phase;
    reg          started;
    wire         advance  = en && !sym_stall;
    wire         last_ph  = (phase == SPS-1);

    // Ask for the next symbol one phase early: qpsk_tx_sym registers it, so
    // sym_valid is then high during the last phase and the delay line shifts
    // on the same edge that wraps the phase back to 0.
    assign sym_req = en && (phase == SPS-2);

    // sym_valid is a one clock pulse on the clock after the request.  With en
    // held high that clock is the last-phase advance; with en pulsed it may
    // not be an advance at all, so the symbol is held until the delay line
    // next shifts.  With en held high the hold register is never used.
    reg               hold_v;
    reg signed [15:0] hold_i, hold_q;
    wire              have_sym = sym_valid || hold_v;
    wire signed [15:0] new_i   = sym_valid ? sym_i : hold_i;
    wire signed [15:0] new_q   = sym_valid ? sym_q : hold_q;
    wire              shift    = advance && last_ph && have_sym;

    // ---- symbol delay line ----------------------------------------------
    reg signed [15:0] dI [0:NT-1];
    reg signed [15:0] dQ [0:NT-1];

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < NT; k = k + 1) begin
                dI[k] <= 16'sd0;
                dQ[k] <= 16'sd0;
            end
            phase   <= SPS - 1;
            started <= 1'b0;
            hold_v  <= 1'b0;
            hold_i  <= 16'sd0;
            hold_q  <= 16'sd0;
        end else begin
            if (shift)
                hold_v <= 1'b0;
            else if (sym_valid) begin
                hold_v <= 1'b1;
                hold_i <= sym_i;
                hold_q <= sym_q;
            end

            if (advance) begin
                if (shift) begin
                    for (k = NT-1; k > 0; k = k - 1) begin
                        dI[k] <= dI[k-1];
                        dQ[k] <= dQ[k-1];
                    end
                    dI[0]   <= new_i;
                    dQ[0]   <= new_q;
                    started <= 1'b1;
                end
                phase <= last_ph ? {PW{1'b0}} : (phase + 1'b1);
            end
        end
    end

    // ---- coefficient selection -------------------------------------------
    wire signed [15:0] coef [0:NT-1];
    genvar g;
    generate
        for (g = 0; g < NT; g = g + 1) begin : g_coef
            assign coef[g] = (phase == 2'd0) ? $signed(TX_H0[W*g +: W]) :
                             (phase == 2'd1) ? $signed(TX_H1[W*g +: W]) :
                             (phase == 2'd2) ? $signed(TX_H2[W*g +: W]) :
                                               $signed(TX_H3[W*g +: W]);
        end
    endgenerate

    // ---- stage 1: products ------------------------------------------------
    reg signed [2*W-1:0] pI [0:NT-1];
    reg signed [2*W-1:0] pQ [0:NT-1];
    reg                  v1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < NT; k = k + 1) begin
                pI[k] <= 0;
                pQ[k] <= 0;
            end
            v1 <= 1'b0;
        end else begin
            v1 <= advance && started;
            if (advance) begin
                for (k = 0; k < NT; k = k + 1) begin
                    pI[k] <= dI[k] * coef[k];
                    pQ[k] <= dQ[k] * coef[k];
                end
            end
        end
    end

    // ---- stage 2: adder tree ----------------------------------------------
    reg signed [ACCW-1:0] accI, accQ;
    reg                   v2;

    integer j;
    reg signed [ACCW-1:0] sI, sQ;
    always @(*) begin
        sI = {ACCW{1'b0}};
        sQ = {ACCW{1'b0}};
        for (j = 0; j < NT; j = j + 1) begin
            sI = sI + pI[j];        // both signed: Verilog sign extends
            sQ = sQ + pQ[j];
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

    // ---- stage 3: round to Q1.15 and saturate ------------------------------
    // RND is a signed localparam so the add stays signed and >>> is arithmetic
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
