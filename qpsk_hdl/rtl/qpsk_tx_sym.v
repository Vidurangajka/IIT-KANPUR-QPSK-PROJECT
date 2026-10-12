`timescale 1ns/1ps
// ---------------------------------------------------------------------------
// qpsk_tx_sym - bit packetiser, scrambler and QPSK symbol mapper
//
// Builds packets of PREAMBLE_SYMS Barker symbols followed by DATA_SYMS
// payload symbols.  Payload bits are taken two at a time from a small
// prefetch register; the scrambler (additive, x^7 + x^4 + 1) is reloaded at
// the start of every payload so the receiver can descramble from the packet
// boundary alone, with no error propagation.
//
// A new symbol is presented on sym_valid.  The caller requests one by
// raising sym_req; if the payload bits are not there yet the module raises
// sym_stall instead and the caller must hold its phase.
// ---------------------------------------------------------------------------
`default_nettype none

module qpsk_tx_sym (
    input  wire                 clk,
    input  wire                 rst_n,

    // payload bit input
    input  wire                 din_bit,
    input  wire                 din_valid,
    output wire                 din_ready,

    // symbol output
    input  wire                 sym_req,    // take a new symbol this clock
    output wire                 sym_stall,  // cannot: payload bits missing
    output reg                  sym_valid,
    output reg  signed [15:0]   sym_i,
    output reg  signed [15:0]   sym_q,
    output reg                  sym_sop,    // first symbol of a packet
    output reg                  sym_pay     // this symbol carries payload
);

`include "qpsk_defs.vh"

    localparam integer SIW = $clog2(PKT_SYMS);

    // ---- payload bit prefetch -------------------------------------------
    reg [1:0] pre;
    reg [1:0] pre_n;
    wire      push = din_valid && din_ready;

    assign din_ready = (pre_n < 2'd2);

    // ---- symbol sequencing ----------------------------------------------
    reg [SIW-1:0] sym_idx;          // index of the symbol being produced
    reg [6:0]     lfsr;

    wire                  last_sym  = (sym_idx == PKT_SYMS - 1);
    wire [SIW-1:0]        nxt_idx   = last_sym ? {SIW{1'b0}} : (sym_idx + 1'b1);
    wire                  nxt_is_pre = (nxt_idx < PREAMBLE_SYMS);
    wire                  need_bits  = sym_req && !nxt_is_pre;
    wire                  pop        = need_bits && (pre_n == 2'd2);

    assign sym_stall = need_bits && (pre_n != 2'd2);

    // The scrambler is reloaded for the first payload symbol of each packet,
    // so that symbol must already see the seed.
    wire reload = (nxt_idx == PREAMBLE_SYMS);
    wire [6:0] lfsr_eff = reload ? SCRAM_SEED : lfsr;

    // two scrambler steps unrolled:
    //   fb = s[6]^s[3];  s' = {s[5:0], fb}
    wire fbA = lfsr_eff[6] ^ lfsr_eff[3];
    wire fbB = lfsr_eff[5] ^ lfsr_eff[2];
    wire [6:0] lfsr_n = {lfsr_eff[4:0], fbA, fbB};
    wire bI = pre[0] ^ fbA;         // first bit  -> I rail
    wire bQ = pre[1] ^ fbB;         // second bit -> Q rail

    // preamble symbol: Barker +1 maps to (+A,+A), -1 to (-A,-A)
    wire [15:0] barker_w = {3'b000, BARKER};
    wire        pre_bit  = barker_w[nxt_idx[3:0]];

    wire signed [15:0] pay_i = bI ? -QPSK_A : QPSK_A;
    wire signed [15:0] pay_q = bQ ? -QPSK_A : QPSK_A;
    wire signed [15:0] prm   = pre_bit ? QPSK_A : -QPSK_A;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pre       <= 2'd0;
            pre_n     <= 2'd0;
            sym_idx   <= PKT_SYMS - 1;      // so the first symbol issued is 0
            lfsr      <= SCRAM_SEED;
            sym_valid <= 1'b0;
            sym_i     <= 16'sd0;
            sym_q     <= 16'sd0;
            sym_sop   <= 1'b0;
            sym_pay   <= 1'b0;
        end else begin
            sym_valid <= 1'b0;

            // prefetch bookkeeping; a push and a pop cannot collide because
            // din_ready is low when the prefetch is full
            if (push) begin
                if (pre_n == 2'd0) pre[0] <= din_bit;
                else               pre[1] <= din_bit;
                pre_n <= pre_n + 1'b1;
            end else if (pop) begin
                pre_n <= 2'd0;
            end

            if (sym_req && !sym_stall) begin
                sym_idx   <= nxt_idx;
                sym_valid <= 1'b1;
                sym_sop   <= (nxt_idx == 0);
                sym_pay   <= !nxt_is_pre;
                if (nxt_is_pre) begin
                    sym_i <= prm;
                    sym_q <= prm;
                end else begin
                    sym_i <= pay_i;
                    sym_q <= pay_q;
                    lfsr  <= lfsr_n;
                end
            end
        end
    end

endmodule

`default_nettype wire
