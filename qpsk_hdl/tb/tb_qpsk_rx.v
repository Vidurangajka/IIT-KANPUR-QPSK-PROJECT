// ---------------------------------------------------------------------------
// Self checking receiver testbench.
//
// Drives the quantised channel samples into qpsk_rx one sample every
// CLKS_PER_SAMPLE clocks and compares every pipeline stage against the bit
// exact Python golden model: AGC, matched filter, timing recovered symbols,
// coarse and fine frequency corrected symbols, the packet detections and
// finally the recovered payload bits.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps
`default_nettype none

module tb_qpsk_rx;

`include "qpsk_defs.vh"
`include "rx_sizes.vh"

    localparam integer CLKS_PER_SAMPLE = 16;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // ---- stimulus and expected -------------------------------------------
    reg signed [15:0] in_i_m  [0:NIN-1];
    reg signed [15:0] in_q_m  [0:NIN-1];
    reg signed [15:0] e_agc_i [0:NIN-1];
    reg signed [15:0] e_agc_q [0:NIN-1];
    reg signed [15:0] e_mf_i  [0:NIN-1];
    reg signed [15:0] e_mf_q  [0:NIN-1];
    reg signed [15:0] e_sym_i [0:NSYM-1];
    reg signed [15:0] e_sym_q [0:NSYM-1];
    reg signed [15:0] e_cf_i  [0:NSYM-1];
    reg signed [15:0] e_cf_q  [0:NSYM-1];
    reg signed [15:0] e_ff_i  [0:NSYM-1];
    reg signed [15:0] e_ff_q  [0:NSYM-1];
    reg [31:0]        e_didx  [0:NDET-1];
    reg [7:0]         e_dage  [0:NDET-1];
    reg [0:0]         e_bits  [0:NRBIT-1];

    integer errors = 0;
    integer i;

    // per stage counters
    integer n_in = 0, n_agc = 0, n_mf = 0, n_sym = 0;
    integer n_cf = 0, n_ff = 0, n_det = 0, n_bit = 0;
    // error counters per stage, so a failure says which stage broke
    integer e_agc = 0, e_mf = 0, e_sym = 0, e_cf = 0, e_ff = 0;
    integer e_det = 0, e_bitc = 0, n_pktdone = 0;

    // ---- DUT --------------------------------------------------------------
    reg                in_valid = 0;
    reg signed [15:0]  in_i, in_q;

    wire               bit_valid, pkt_start, pkt_done;
    wire [1:0]         bit_data;
    wire               agc_valid, mf_valid, sym_valid, cf_valid, ff_valid;
    wire               det_valid;
    wire [3:0]         det_age;
    wire signed [15:0] agc_i, agc_q, mf_i, mf_q, sym_i, sym_q;
    wire signed [15:0] cf_i, cf_q, ff_i, ff_q;
    wire signed [23:0] cf_rate;
    wire [19:0]        agc_gain;

    qpsk_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
        .bit_valid(bit_valid), .bit_data(bit_data),
        .pkt_start(pkt_start), .pkt_done(pkt_done),
        .agc_valid(agc_valid), .agc_i(agc_i), .agc_q(agc_q),
        .agc_gain(agc_gain),
        .mf_valid(mf_valid), .mf_i(mf_i), .mf_q(mf_q),
        .sym_valid(sym_valid), .sym_i(sym_i), .sym_q(sym_q),
        .cf_valid(cf_valid), .cf_i(cf_i), .cf_q(cf_q), .cf_rate(cf_rate),
        .ff_valid(ff_valid), .ff_i(ff_i), .ff_q(ff_q),
        .det_valid(det_valid), .det_age(det_age));

    // ---- sample driver ----------------------------------------------------
    integer ph = 0;
    always @(posedge clk) begin
        if (!rst_n) begin
            in_valid <= 1'b0;
            ph       <= 0;
        end else begin
            in_valid <= 1'b0;
            if (ph == 0 && n_in < NIN) begin
                in_valid <= 1'b1;
                in_i     <= in_i_m[n_in];
                in_q     <= in_q_m[n_in];
                n_in     <= n_in + 1;
            end
            ph <= (ph == CLKS_PER_SAMPLE-1) ? 0 : ph + 1;
        end
    end

    // ---- checkers ---------------------------------------------------------
    `define CHK2(VLD, GI, GQ, EI, EQ, N, LIM, EC, NAME)                      \
        always @(posedge clk) if (rst_n && VLD) begin                        \
            if (N < LIM) begin                                               \
                if (GI !== EI[N] || GQ !== EQ[N]) begin                      \
                    if (EC < 5) $display("%s [%0d] got (%0d,%0d) want (%0d,%0d)", \
                                         NAME, N, GI, GQ, EI[N], EQ[N]);     \
                    EC = EC + 1; errors = errors + 1;                        \
                end                                                          \
            end                                                              \
            N = N + 1;                                                       \
        end

    `CHK2(agc_valid, agc_i, agc_q, e_agc_i, e_agc_q, n_agc, NIN,  e_agc, "AGC")
    `CHK2(mf_valid,  mf_i,  mf_q,  e_mf_i,  e_mf_q,  n_mf,  NIN,  e_mf,  "MF")
    `CHK2(sym_valid, sym_i, sym_q, e_sym_i, e_sym_q, n_sym, NSYM, e_sym, "SYM")
    `CHK2(cf_valid,  cf_i,  cf_q,  e_cf_i,  e_cf_q,  n_cf,  NSYM, e_cf,  "CF")
    `CHK2(ff_valid,  ff_i,  ff_q,  e_ff_i,  e_ff_q,  n_ff,  NSYM, e_ff,  "FF")

    // Detections.  det_valid is held until the next symbol event, so it is
    // sampled on ff_valid exactly as rx_extract samples it, giving event
    // index idx + DET_PIPE + 1 for model declaration index idx.
    integer ffev = 0;
    always @(posedge clk) if (rst_n && ff_valid) begin
        if (det_valid) begin
            if (n_det < NDET) begin
                if (ffev !== (e_didx[n_det] + 3) ||
                    det_age !== e_dage[n_det]) begin
                    if (e_det < 5)
                        $display("DET [%0d] at ff#%0d age %0d, want ff#%0d age %0d",
                                 n_det, ffev, det_age, e_didx[n_det]+3,
                                 e_dage[n_det]);
                    e_det = e_det + 1; errors = errors + 1;
                end
            end
            n_det = n_det + 1;
        end
        ffev = ffev + 1;
    end

    always @(posedge clk) if (rst_n && pkt_done) n_pktdone = n_pktdone + 1;

    always @(posedge clk) if (rst_n && bit_valid) begin
        if (n_bit + 1 < NRBIT) begin
            if (bit_data[0] !== e_bits[n_bit] ||
                bit_data[1] !== e_bits[n_bit+1]) begin
                if (e_bitc < 5)
                    $display("BIT [%0d] got %b%b want %b%b", n_bit,
                             bit_data[1], bit_data[0],
                             e_bits[n_bit+1], e_bits[n_bit]);
                e_bitc = e_bitc + 1; errors = errors + 1;
            end
        end
        n_bit = n_bit + 2;
    end

    // ---- run ---------------------------------------------------------------
    initial begin
        $readmemh("../vectors/rx_in_i.hex",  in_i_m);
        $readmemh("../vectors/rx_in_q.hex",  in_q_m);
        $readmemh("../vectors/rx_agc_i.hex", e_agc_i);
        $readmemh("../vectors/rx_agc_q.hex", e_agc_q);
        $readmemh("../vectors/rx_mf_i.hex",  e_mf_i);
        $readmemh("../vectors/rx_mf_q.hex",  e_mf_q);
        $readmemh("../vectors/rx_sym_i.hex", e_sym_i);
        $readmemh("../vectors/rx_sym_q.hex", e_sym_q);
        $readmemh("../vectors/rx_cf_i.hex",  e_cf_i);
        $readmemh("../vectors/rx_cf_q.hex",  e_cf_q);
        $readmemh("../vectors/rx_ff_i.hex",  e_ff_i);
        $readmemh("../vectors/rx_ff_q.hex",  e_ff_q);
        $readmemh("../vectors/rx_det_idx.hex", e_didx);
        $readmemh("../vectors/rx_det_age.hex", e_dage);
        $readmemb("../vectors/rx_exp_bits.bin", e_bits);

        repeat (8) @(posedge clk);
        rst_n = 1;

        wait (n_in == NIN);
        repeat (CLKS_PER_SAMPLE * 200) @(posedge clk);

        $display("--------------------------------------------------------");
        $display(" stage      produced   expected   mismatches");
        $display(" AGC        %8d   %8d   %8d", n_agc, NIN,   e_agc);
        $display(" matched    %8d   %8d   %8d", n_mf,  NIN,   e_mf);
        $display(" timing     %8d   %8d   %8d", n_sym, NSYM,  e_sym);
        $display(" coarse     %8d   %8d   %8d", n_cf,  NSYM,  e_cf);
        $display(" fine       %8d   %8d   %8d", n_ff,  NSYM,  e_ff);
        $display(" detections %8d   %8d   %8d", n_det, NDET,  e_det);
        $display(" bits       %8d   %8d   %8d", n_bit, NRBIT, e_bitc);
        $display(" packets    %8d   %8d", n_pktdone, NPKTS);
        $display("--------------------------------------------------------");

        // The model only records packets it saw through to completion; the
        // RTL streams bits as they are sliced, so it also emits the start of
        // a final packet that runs past the end of the stimulus.  Every bit
        // the model produced must match, and the excess must be less than
        // one packet.
        if (n_bit < NRBIT) begin
            $display("TOO FEW BITS: %0d produced, %0d expected", n_bit, NRBIT);
            errors = errors + 1;
        end else if (n_bit - NRBIT >= DATA_BITS) begin
            $display("TOO MANY BITS: %0d produced, %0d expected, excess %0d is a whole packet or more", n_bit, NRBIT, n_bit-NRBIT);
            errors = errors + 1;
        end else if (n_bit > NRBIT) begin
            $display(" (plus %0d bits of a final packet truncated by the end of the stimulus)", n_bit - NRBIT);
        end
        if (n_pktdone != NPKTS) begin
            $display("COUNT MISMATCH: %0d packets completed, %0d expected",
                     n_pktdone, NPKTS);
            errors = errors + 1;
        end
        if (n_det != NDET) begin
            $display("COUNT MISMATCH: %0d detections, %0d expected",
                     n_det, NDET);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("tb_qpsk_rx: PASS");
        else
            $display("tb_qpsk_rx: FAIL  %0d mismatches", errors);
        $finish;
    end

endmodule

`default_nettype wire
