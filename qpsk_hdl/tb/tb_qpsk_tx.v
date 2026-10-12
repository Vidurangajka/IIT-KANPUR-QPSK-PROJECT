// Self checking transmitter testbench.  Compares the QPSK symbol stream and
// the RRC interpolator output against the bit exact Python model, sample for
// sample.  The payload bit source deliberately stalls at random so the
// valid/ready handshake is exercised.
//
// With the +en_random plusarg the sample enable is also randomised, including
// isolated one clock pulses, as it is when the transmitter runs sample
// enabled on a faster clock.  The output must be identical either way.
`timescale 1ns/1ps
`default_nettype none

module tb_qpsk_tx;

`include "qpsk_defs.vh"

    localparam integer NPKT   = 8;
    localparam integer NBITS  = NPKT * DATA_BITS;
    localparam integer NSYM   = NPKT * PKT_SYMS;
    localparam integer NSAMP  = NSYM * SPS;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [0:0]         bits   [0:NBITS-1];
    reg signed [15:0] esym_i [0:NSYM-1];
    reg signed [15:0] esym_q [0:NSYM-1];
    reg signed [15:0] esmp_i [0:NSAMP-1];
    reg signed [15:0] esmp_q [0:NSAMP-1];

    integer errors = 0;
    integer nb = 0, ns = 0, nsa = 0;
    integer i;
    integer seed = 32'h1234_5678;

    // ---- DUT -------------------------------------------------------------
    reg  din_valid = 0;
    wire din_ready;
    // index is clamped so the source can keep offering after the packets
    // under test have been consumed
    wire [31:0] nbi = (nb < NBITS) ? nb[31:0] : 32'd0;
    wire din_bit = bits[nbi][0];

    wire               out_valid, sym_valid, sym_sop;
    wire signed [15:0] out_i, out_q, sym_i, sym_q;

    // ---- sample enable: always on, or random at about 1/3 duty -----------
    reg en = 1'b1;
    reg en_random = 1'b0;
    integer en_seed = 32'h0bad_cafe;
    initial en_random = $test$plusargs("en_random");
    always @(posedge clk)
        if (en_random) en <= (($random(en_seed) % 3) == 0);

    qpsk_tx u_tx (
        .clk(clk), .rst_n(rst_n), .en(en),
        .din_bit(din_bit), .din_valid(din_valid), .din_ready(din_ready),
        .out_valid(out_valid), .out_i(out_i), .out_q(out_q),
        .sym_valid(sym_valid), .sym_i(sym_i), .sym_q(sym_q),
        .sym_sop(sym_sop));

    // ---- bit source: proper valid/ready with random gaps -----------------
    // data and valid are held until ready is seen, and the index advances on
    // the clock edge where the transfer actually happens
    always @(posedge clk) begin
        if (!rst_n) begin
            nb        <= 0;
            din_valid <= 1'b0;
        end else begin
            if (din_valid && din_ready)
                nb <= nb + 1;
            if (!din_valid || din_ready)
                din_valid <= (($random(seed) % 10) != 0);
        end
    end

    // ---- checkers --------------------------------------------------------
    always @(posedge clk) if (rst_n && sym_valid && ns < NSYM) begin
        if (sym_i !== esym_i[ns] || sym_q !== esym_q[ns]) begin
            if (errors < 20)
                $display("SYM  [%0d] got (%0d,%0d) want (%0d,%0d)",
                         ns, sym_i, sym_q, esym_i[ns], esym_q[ns]);
            errors = errors + 1;
        end
        ns = ns + 1;
    end

    always @(posedge clk) if (rst_n && out_valid && nsa < NSAMP) begin
        if (out_i !== esmp_i[nsa] || out_q !== esmp_q[nsa]) begin
            if (errors < 20)
                $display("SAMP [%0d] got (%0d,%0d) want (%0d,%0d)",
                         nsa, out_i, out_q, esmp_i[nsa], esmp_q[nsa]);
            errors = errors + 1;
        end
        nsa = nsa + 1;
    end

    // ---- run -------------------------------------------------------------
    initial begin
        $readmemb("../vectors/tx_bits.bin",   bits);
        $readmemh("../vectors/tx_sym_i.hex",  esym_i);
        $readmemh("../vectors/tx_sym_q.hex",  esym_q);
        $readmemh("../vectors/tx_samp_i.hex", esmp_i);
        $readmemh("../vectors/tx_samp_q.hex", esmp_q);

        repeat (4) @(posedge clk);
        rst_n = 1;

        // allow generous time: the source stalls about 10% of the time and
        // a random enable is high about a third of the time
        for (i = 0; i < NSAMP * 12 + 2000; i = i + 1) begin
            @(posedge clk);
            if (nsa >= NSAMP) i = NSAMP * 12 + 2000;
        end

        if (nsa < NSAMP) begin
            $display("TIMEOUT: only %0d of %0d samples produced", nsa, NSAMP);
            errors = errors + 1;
        end
        if (ns < NSYM) begin
            $display("TIMEOUT: only %0d of %0d symbols produced", ns, NSYM);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("tb_qpsk_tx: PASS  (%0d symbols, %0d samples, %0d bits, %0s enable)",
                     ns, nsa, nb, en_random ? "random" : "constant");
        else
            $display("tb_qpsk_tx: FAIL  %0d mismatches (%0s enable)",
                     errors, en_random ? "random" : "constant");
        $finish;
    end

endmodule

`default_nettype wire
