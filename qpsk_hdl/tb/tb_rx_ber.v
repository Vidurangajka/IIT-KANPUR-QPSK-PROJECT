// End to end step 3: feed the channel corrupted samples into the RTL
// receiver and dump the recovered payload bits for BER analysis.
`timescale 1ns/1ps
`default_nettype none

module tb_rx_ber;

`include "qpsk_defs.vh"
`include "e2e_sizes.vh"

    localparam integer CLKS_PER_SAMPLE = 16;
    localparam integer NIN = NPKT * PKT_SYMS * SPS;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg signed [15:0] xi [0:NIN-1];
    reg signed [15:0] xq [0:NIN-1];

    integer n_in = 0, ph = 0, fh, npk = 0;

    reg               in_valid = 0;
    reg signed [15:0] in_i, in_q;

    wire       bit_valid, pkt_start, pkt_done;
    wire [1:0] bit_data;

    qpsk_rx u_rx (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_i(in_i), .in_q(in_q),
        .bit_valid(bit_valid), .bit_data(bit_data),
        .pkt_start(pkt_start), .pkt_done(pkt_done),
        .agc_valid(), .agc_i(), .agc_q(), .agc_gain(),
        .mf_valid(), .mf_i(), .mf_q(),
        .sym_valid(), .sym_i(), .sym_q(),
        .cf_valid(), .cf_i(), .cf_q(), .cf_rate(),
        .ff_valid(), .ff_i(), .ff_q(),
        .det_valid(), .det_age());

    always @(posedge clk) begin
        if (!rst_n) begin
            in_valid <= 1'b0; ph <= 0;
        end else begin
            in_valid <= 1'b0;
            if (ph == 0 && n_in < NIN) begin
                in_valid <= 1'b1;
                in_i     <= xi[n_in];
                in_q     <= xq[n_in];
                n_in     <= n_in + 1;
            end
            ph <= (ph == CLKS_PER_SAMPLE-1) ? 0 : ph + 1;
        end
    end

    // one line per packet: "P" then the payload bits in transmission order
    always @(posedge clk) if (rst_n) begin
        if (pkt_start) $fwrite(fh, "P ");
        if (bit_valid) $fwrite(fh, "%b%b", bit_data[0], bit_data[1]);
        if (pkt_done) begin
            $fwrite(fh, "\n");
            npk = npk + 1;
        end
    end

    initial begin
        $readmemh("../vectors/e2e_rx_i.hex", xi);
        $readmemh("../vectors/e2e_rx_q.hex", xq);
        fh = $fopen("../vectors/e2e_rx_bits.txt", "w");
        repeat (8) @(posedge clk);
        rst_n = 1;
        wait (n_in == NIN);
        repeat (CLKS_PER_SAMPLE * 400) @(posedge clk);
        $fclose(fh);
        $display("tb_rx_ber: %0d packets decoded", npk);
        $finish;
    end

endmodule

`default_nettype wire
