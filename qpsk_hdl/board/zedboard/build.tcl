# ---------------------------------------------------------------------------
# Vivado batch build for the ZedBoard QPSK loopback demo.
#
#   vivado -mode batch -source build.tcl                  with VIO + ILA
#   vivado -mode batch -source build.tcl -tclargs -nodebug
#
# Run through build.sh, which regenerates the constant headers first.
# Outputs land in build/: zed_qpsk.bit, zed_qpsk.ltx (debug probes),
# utilization.rpt and timing.rpt.
# ---------------------------------------------------------------------------
set here  [file dirname [file normalize [info script]]]
set root  [file normalize $here/../..]
set out   $here/build
set part  xc7z020clg484-1
set debug [expr {[lsearch $argv -nodebug] < 0}]
set jobs  8

file mkdir $out
create_project -force -part $part zed_qpsk $out/proj

set core {
    qpsk_tx.v qpsk_tx_sym.v fir_interp_rrc.v
    qpsk_rx.v rx_agc.v fir_rrc_rx.v symbol_timing_recovery.v
    coarse_freq_rec.v fine_freq_rec.v packet_detector.v rx_extract.v
    cordic_rot.v cordic_vec.v
}
foreach f $core { add_files -norecurse $root/rtl/$f }
foreach f {zed_qpsk_top.v qpsk_channel.v awgn_gen.v ber_monitor.v} {
    add_files -norecurse $here/rtl/$f
}
add_files -norecurse $root/rtl/qpsk_defs.vh $here/rtl/board_defs.vh
set_property file_type {Verilog Header} [get_files *.vh]
set_property include_dirs [list $root/rtl $here/rtl] [current_fileset]
set_property top zed_qpsk_top [current_fileset]
add_files -fileset constrs_1 -norecurse $here/zedboard.xdc

if {$debug} {
    set_property verilog_define USE_DEBUG_CORES [current_fileset]

    # counters, read in the Hardware Manager
    create_ip -name vio -vendor xilinx.com -library ip -module_name vio_qpsk
    set_property -dict [list \
        CONFIG.C_NUM_PROBE_IN  {9} \
        CONFIG.C_NUM_PROBE_OUT {0} \
        CONFIG.C_PROBE_IN0_WIDTH {48} \
        CONFIG.C_PROBE_IN1_WIDTH {32} \
        CONFIG.C_PROBE_IN2_WIDTH {32} \
        CONFIG.C_PROBE_IN3_WIDTH {32} \
        CONFIG.C_PROBE_IN4_WIDTH {32} \
        CONFIG.C_PROBE_IN5_WIDTH {24} \
        CONFIG.C_PROBE_IN6_WIDTH {20} \
        CONFIG.C_PROBE_IN7_WIDTH {9}  \
        CONFIG.C_PROBE_IN8_WIDTH {32} \
    ] [get_ips vio_qpsk]

    # receiver internals; storage qualification lets a capture keep only
    # the symbol strobes, which gives a constellation of 4096 symbols
    create_ip -name ila -vendor xilinx.com -library ip -module_name ila_qpsk
    set_property -dict [list \
        CONFIG.C_NUM_OF_PROBES {8} \
        CONFIG.C_DATA_DEPTH {4096} \
        CONFIG.C_EN_STRG_QUAL {1} \
        CONFIG.C_PROBE0_WIDTH {1}  \
        CONFIG.C_PROBE1_WIDTH {16} \
        CONFIG.C_PROBE2_WIDTH {16} \
        CONFIG.C_PROBE3_WIDTH {1}  \
        CONFIG.C_PROBE4_WIDTH {16} \
        CONFIG.C_PROBE5_WIDTH {16} \
        CONFIG.C_PROBE6_WIDTH {1}  \
        CONFIG.C_PROBE7_WIDTH {1}  \
    ] [get_ips ila_qpsk]

    generate_target all [get_ips]
}

launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {
    error "synthesis failed"
}

launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "implementation failed"
}

open_run impl_1
report_utilization -file $out/utilization.rpt
report_timing_summary -max_paths 10 -file $out/timing.rpt

# a bitstream that misses timing would fail in ways no simulation shows, so
# only export one that meets it
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
file delete -force $out/zed_qpsk.bit $out/zed_qpsk.ltx
if {$wns < 0 || $whs < 0} {
    error "timing not met: WNS $wns ns, WHS $whs ns - see $out/timing.rpt"
}

set rundir [get_property DIRECTORY [get_runs impl_1]]
file copy -force $rundir/zed_qpsk_top.bit $out/zed_qpsk.bit
if {$debug} {
    write_debug_probes -force $out/zed_qpsk.ltx
}
puts "BUILD DONE  WNS $wns ns  WHS $whs ns  -> $out/zed_qpsk.bit"
