// Board level testbench: drives the switches and buttons of zed_qpsk_top
// through a set of channel conditions and reads its BER counters.  The whole
// loopback - bit source, transmitter, on-chip channel, receiver, checker -
// is the synthesised design; only the debounce and settle timers are
// shortened (SIM=1).
`timescale 1ns/1ps
`default_nettype none

module tb_zed_top;

`include "qpsk_defs.vh"
`include "board_defs.vh"

    localparam integer PKT_CLKS = PKT_SYMS * SPS * CLKS_PER_SAMPLE;

    reg        clk  = 0;
    reg  [7:0] sw   = 8'd0;
    reg        btnc = 1'b0;
    reg        btnu = 1'b0;
    wire [7:0] led;

    always #5 clk = ~clk;       // 100 MHz

    zed_qpsk_top #(.SIM(1)) dut (.clk_100(clk), .sw(sw), .btnc(btnc), .btnu(btnu), .led(led));

    integer fails = 0;

    // sw = {level, phase, noise, fo}
    function [7:0] setting(input [1:0] level, input [1:0] phase,
                           input [1:0] noise, input [1:0] fo);
        setting = {level, phase, noise, fo};
    endfunction

    // run npkt packets after the receiver has settled, then report
    task measure(input [8*30-1:0] label, input integer npkt,
                 input integer noisy);
        real ber;
        begin
            repeat (64) @(posedge clk);
            wait (!dut.settling);
            repeat (npkt * PKT_CLKS) @(posedge clk);
            ber = dut.err_cnt * 1.0 / (dut.bit_cnt == 0 ? 1 : dut.bit_cnt);
            $display("  %0s  pkts %3d  bits %6d  errors %4d  BER %.2e  bad %0d  lost %0d  slip %0d",
                     label, dut.pkt_cnt, dut.bit_cnt, dut.err_cnt, ber,
                     dut.bad_pkt_cnt, dut.lost_cnt, dut.slip_cnt);
            if (dut.pkt_cnt < npkt - 2 || dut.lost_cnt != 0 || dut.slip_cnt != 0
                || (!noisy && dut.err_cnt != 0)
                || (noisy && ber > 2e-2)) begin
                $display("    ^ FAIL");
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        $display("tb_zed_top: %0d clocks per packet", PKT_CLKS);

        sw = setting(0, 0, 0, 1);
        measure("fo +0.02, clean               ", 20, 0);

        // With a fixed payload in every packet this restart point used to
        // lock the packet detector onto a payload sidelobe for good.
        sw = setting(0, 1, 0, 2);
        measure("fo -0.04, phase +90           ", 20, 0);

        sw = setting(2, 1, 0, 3);
        measure("fo +0.06, phase +90, level 1/4", 20, 0);

        sw = setting(3, 2, 0, 1);
        measure("fo +0.02, phase +180, lvl 1/8 ", 20, 0);

        sw = setting(0, 0, 1, 1);
        measure("fo +0.02, Eb/N0 10 dB         ", 30, 1);

        sw = setting(0, 0, 3, 1);
        measure("fo +0.02, Eb/N0 6 dB          ", 40, 1);

        // BTNU holds the counters at zero
        btnu = 1'b1;
        repeat (256) @(posedge clk);
        if (dut.bit_cnt != 0) begin
            $display("  BTNU did not clear the counters  ^ FAIL");
            fails = fails + 1;
        end
        btnu = 1'b0;

        if (fails == 0) $display("tb_zed_top: PASS");
        else            $display("tb_zed_top: FAIL  %0d cases", fails);
        $finish;
    end

endmodule

`default_nettype wire
