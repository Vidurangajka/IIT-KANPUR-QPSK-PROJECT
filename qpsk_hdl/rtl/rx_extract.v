`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// rx_extract - payload gating, phase ambiguity resolution, QPSK slicer and
// descrambler.
//
// A QPSK constellation is rotationally symmetric, so once the fine frequency
// loop has stopped the constellation spinning the recovered symbols can
// still be offset by 0, 90, 180 or 270 degrees.  The preamble correlator
// output at the detected peak carries exactly that offset, so the quadrant
// is read off the signs and relative magnitudes of cI and cQ and removed by
// swapping and negating the rails - no multiplier needed.
//
// The symbol stream is delayed by DELAY symbol events so that a detection,
// which is only declared at the end of the peak search window and after the
// detector pipeline, still has the payload in flight.  DELAY is chosen so
// the payload always finishes before the next packet is detected.
// ---------------------------------------------------------------------------
`default_nettype none

module rx_extract (
    input  wire                 clk,
    input  wire                 rst_n,

    input  wire                 in_valid,
    input  wire signed [15:0]   in_i,
    input  wire signed [15:0]   in_q,

    input  wire                 det_valid,
    input  wire [3:0]           det_age,
    input  wire signed [20:0]   det_cI,
    input  wire signed [20:0]   det_cQ,

    output reg                  bit_valid,
    output reg  [1:0]           bit_data,   // two bits per symbol, I then Q
    output reg                  pkt_start,
    output reg                  pkt_done
);

`include "qpsk_defs.vh"

    // The detector pipeline declares DET_PIPE symbol events after the symbol
    // the model declares on, and det_valid is observed one event later still
    // because it is registered.  So a detection for model index idx is seen
    // at event idx+DET_PIPE+1, and the payload symbol idx-age+1 leaves the
    // delay line DET_DLY-1-age events after that.
    localparam integer DET_PIPE = 2;
    localparam integer DELAY    = DET_DLY - 1 + DET_PIPE;   // 10

    localparam [1:0] S_IDLE = 2'd0, S_WAIT = 2'd1, S_PAY = 2'd2;

    reg signed [15:0] dI [0:DELAY-1];
    reg signed [15:0] dQ [0:DELAY-1];

    reg [1:0]         state;
    reg [4:0]         cnt;
    reg [15:0]        remain;
    reg signed [20:0] cI, cQ;
    reg [6:0]         lfsr;

    // ---- quadrant removal -------------------------------------------------
    wire signed [20:0] acI = cI[20] ? -cI : cI;
    wire signed [20:0] acQ = cQ[20] ? -cQ : cQ;
    wire               use_i = (acI >= acQ);

    wire signed [15:0] oI = dI[DELAY-1];
    wire signed [15:0] oQ = dQ[DELAY-1];

    wire signed [15:0] zI =  use_i ? (cI[20] ? -oI :  oI)
                                   : (cQ[20] ? -oQ :  oQ);
    wire signed [15:0] zQ =  use_i ? (cI[20] ? -oQ :  oQ)
                                   : (cQ[20] ?  oI : -oI);

    // ---- slicer + descrambler ---------------------------------------------
    wire start_now = (state == S_WAIT) && (cnt == 5'd1);

    wire rawI = zI[15];                 // sign bit: 1 means negative
    wire rawQ = zQ[15];
    // the descrambler is reloaded for the first payload symbol of a packet,
    // mirroring the transmitter, so there is no error propagation
    wire [6:0] lfsr_eff = start_now ? SCRAM_SEED : lfsr;
    wire fbA  = lfsr_eff[6] ^ lfsr_eff[3];
    wire fbB  = lfsr_eff[5] ^ lfsr_eff[2];
    wire [6:0] lfsr_n = {lfsr_eff[4:0], fbA, fbB};

    integer k;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (k = 0; k < DELAY; k = k + 1) begin
                dI[k] <= 16'sd0;
                dQ[k] <= 16'sd0;
            end
            state     <= S_IDLE;
            cnt       <= 5'd0;
            remain    <= 16'd0;
            cI        <= 0;
            cQ        <= 0;
            lfsr      <= SCRAM_SEED;
            bit_valid <= 1'b0;
            bit_data  <= 2'd0;
            pkt_start <= 1'b0;
            pkt_done  <= 1'b0;
        end else begin
            bit_valid <= 1'b0;
            pkt_start <= 1'b0;
            pkt_done  <= 1'b0;

            if (in_valid) begin
                for (k = DELAY-1; k > 0; k = k - 1) begin
                    dI[k] <= dI[k-1];
                    dQ[k] <= dQ[k-1];
                end
                dI[0] <= in_i;
                dQ[0] <= in_q;

                case (state)
                S_IDLE: begin
                    if (det_valid) begin
                        cI    <= det_cI;
                        cQ    <= det_cQ;
                        cnt   <= DET_DLY[4:0] - 5'd1 - {1'b0, det_age};
                        state <= S_WAIT;
                    end
                end
                S_WAIT: begin
                    cnt <= cnt - 1'b1;
                    if (cnt == 5'd1) begin
                        state     <= S_PAY;
                        // this cycle emits the first payload symbol, so
                        // DATA_SYMS-1 remain
                        remain    <= DATA_SYMS[15:0] - 16'd1;
                        lfsr      <= lfsr_n;
                        bit_valid <= 1'b1;
                        bit_data  <= {rawQ ^ fbB, rawI ^ fbA};
                        pkt_start <= 1'b1;
                    end
                end
                S_PAY: begin
                    lfsr      <= lfsr_n;
                    bit_valid <= 1'b1;
                    bit_data  <= {rawQ ^ fbB, rawI ^ fbA};
                    remain    <= remain - 1'b1;
                    if (remain == 16'd1) begin
                        state    <= S_IDLE;
                        pkt_done <= 1'b1;
                    end
                end
                default: state <= S_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
