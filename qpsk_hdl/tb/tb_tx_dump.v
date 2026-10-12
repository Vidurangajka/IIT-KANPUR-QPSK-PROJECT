// End to end step 1: run the RTL transmitter and dump its baseband samples.
`timescale 1ns/1ps
`default_nettype none

module tb_tx_dump;

`include "qpsk_defs.vh"
`include "e2e_sizes.vh"

    localparam integer NSAMP = NPKT * PKT_SYMS * SPS;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg [0:0] bits [0:NTXBITS-1];

    integer nb = 0, nsa = 0, i, fh;

    reg  din_valid = 0;
    wire din_ready;
    wire [31:0] nbi = (nb < NTXBITS) ? nb[31:0] : 32'd0;
    wire din_bit = bits[nbi][0];

    wire               out_valid;
    wire signed [15:0] out_i, out_q;

    qpsk_tx u_tx (
        .clk(clk), .rst_n(rst_n), .en(1'b1),
        .din_bit(din_bit), .din_valid(din_valid), .din_ready(din_ready),
        .out_valid(out_valid), .out_i(out_i), .out_q(out_q),
        .sym_valid(), .sym_i(), .sym_q(), .sym_sop());

    always @(posedge clk) begin
        if (!rst_n) begin
            nb <= 0; din_valid <= 1'b0;
        end else begin
            if (din_valid && din_ready) nb <= nb + 1;
            if (!din_valid || din_ready) din_valid <= 1'b1;
        end
    end

    always @(posedge clk) if (rst_n && out_valid && nsa < NSAMP) begin
        $fdisplay(fh, "%04x %04x", out_i[15:0], out_q[15:0]);
        nsa = nsa + 1;
    end

    initial begin
        $readmemb("../vectors/e2e_bits.bin", bits);
        fh = $fopen("../vectors/e2e_tx_samp.txt", "w");
        repeat (4) @(posedge clk);
        rst_n = 1;
        for (i = 0; i < NSAMP * 4 + 1000; i = i + 1) begin
            @(posedge clk);
            if (nsa >= NSAMP) i = NSAMP * 4 + 1000;
        end
        $fclose(fh);
        if (nsa < NSAMP)
            $display("tb_tx_dump: FAIL  only %0d of %0d samples", nsa, NSAMP);
        else
            $display("tb_tx_dump: wrote %0d samples", nsa);
        $finish;
    end

endmodule

`default_nettype wire
