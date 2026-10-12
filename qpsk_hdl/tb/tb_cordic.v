// Self checking testbench: CORDIC rotation / unit / vectoring against the
// vectors produced by model/gen_cordic_vectors.py
`timescale 1ns/1ps
`default_nettype none

module tb_cordic;

`include "qpsk_defs.vh"

    localparam integer NV = 4096;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    // stimulus / expected
    reg signed [15:0] sx  [0:NV-1];
    reg signed [15:0] sy  [0:NV-1];
    reg signed [15:0] sz  [0:NV-1];
    reg signed [15:0] rx  [0:NV-1];   // expected rotation output
    reg signed [15:0] ry  [0:NV-1];
    reg signed [15:0] ux  [0:NV-1];   // expected unit output
    reg signed [15:0] uy  [0:NV-1];
    reg signed [15:0] va  [0:NV-1];   // expected atan2 output

    integer errors = 0;
    integer i;

    // ---- DUTs ------------------------------------------------------------
    reg               in_v = 0;
    reg signed [15:0] in_x, in_y, in_z;

    wire               rv, uv, vv;
    wire signed [15:0] ro_x, ro_y, uo_x, uo_y, vo_z;

    cordic_rot #(.UNIT_INPUT(0)) u_rot (
        .clk(clk), .rst_n(rst_n), .in_valid(in_v),
        .x_i(in_x), .y_i(in_y), .z_i(in_z), .tag_i(1'b0), .tag_o(),
        .out_valid(rv), .x_o(ro_x), .y_o(ro_y));

    cordic_rot #(.UNIT_INPUT(1)) u_unit (
        .clk(clk), .rst_n(rst_n), .in_valid(in_v),
        .x_i(16'sd0), .y_i(16'sd0), .z_i(in_z), .tag_i(1'b0), .tag_o(),
        .out_valid(uv), .x_o(uo_x), .y_o(uo_y));

    cordic_vec u_vec (
        .clk(clk), .rst_n(rst_n), .in_valid(in_v),
        .x_i(in_x[15] ? {2'b11, in_x} : {2'b00, in_x}),
        .y_i(in_y[15] ? {2'b11, in_y} : {2'b00, in_y}), .tag_i(1'b0), .tag_o(),
        .out_valid(vv), .z_o(vo_z));

    // ---- capture ---------------------------------------------------------
    integer nr = 0, nu = 0, nvv = 0;

    always @(posedge clk) if (rst_n && rv) begin
        if (ro_x !== rx[nr] || ro_y !== ry[nr]) begin
            if (errors < 20)
                $display("ROT   [%0d] got (%0d,%0d) want (%0d,%0d)",
                         nr, ro_x, ro_y, rx[nr], ry[nr]);
            errors = errors + 1;
        end
        nr = nr + 1;
    end

    always @(posedge clk) if (rst_n && uv) begin
        if (uo_x !== ux[nu] || uo_y !== uy[nu]) begin
            if (errors < 20)
                $display("UNIT  [%0d] got (%0d,%0d) want (%0d,%0d)",
                         nu, uo_x, uo_y, ux[nu], uy[nu]);
            errors = errors + 1;
        end
        nu = nu + 1;
    end

    always @(posedge clk) if (rst_n && vv) begin
        if (vo_z !== va[nvv]) begin
            if (errors < 20)
                $display("ATAN2 [%0d] got %0d want %0d", nvv, vo_z, va[nvv]);
            errors = errors + 1;
        end
        nvv = nvv + 1;
    end

    // ---- drive -----------------------------------------------------------
    initial begin
        $readmemh("../vectors/cordic_x.hex", sx);
        $readmemh("../vectors/cordic_y.hex", sy);
        $readmemh("../vectors/cordic_z.hex", sz);
        $readmemh("../vectors/cordic_rot_x.hex", rx);
        $readmemh("../vectors/cordic_rot_y.hex", ry);
        $readmemh("../vectors/cordic_unit_x.hex", ux);
        $readmemh("../vectors/cordic_unit_y.hex", uy);
        $readmemh("../vectors/cordic_atan.hex", va);

        repeat (4) @(posedge clk);
        rst_n = 1;
        @(posedge clk);

        for (i = 0; i < NV; i = i + 1) begin
            @(negedge clk);
            in_v = 1; in_x = sx[i]; in_y = sy[i]; in_z = sz[i];
        end
        @(negedge clk);
        in_v = 0;

        repeat (CORDIC_NITER + 16) @(posedge clk);

        if (nr != NV || nu != NV || nvv != NV) begin
            $display("COUNT MISMATCH rot %0d unit %0d atan %0d (expected %0d)",
                     nr, nu, nvv, NV);
            errors = errors + 1;
        end
        if (errors == 0)
            $display("tb_cordic: PASS  (%0d vectors x 3 modes)", NV);
        else
            $display("tb_cordic: FAIL  %0d mismatches", errors);
        $finish;
    end

endmodule

`default_nettype wire
