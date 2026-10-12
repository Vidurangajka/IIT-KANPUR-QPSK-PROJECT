# ---------------------------------------------------------------------------
# Program the ZedBoard and read the loopback results, from the command line.
#
#   vivado -mode batch -source hw.tcl -tclargs [program] [ber] [ila]
#
# program  download build/zed_qpsk.bit (+ .ltx)
# ber      read the VIO counters and print BER
# ila      capture 4096 recovered symbols into build/ila_symbols.csv
#
# With no arguments all three are done.  Run through hw.sh.
# ---------------------------------------------------------------------------
set here [file dirname [file normalize [info script]]]
set out  $here/build
set bit  $out/zed_qpsk.bit
set ltx  $out/zed_qpsk.ltx

set do_all [expr {[llength $argv] == 0}]
proc want {what} { global argv do_all; expr {$do_all || [lsearch $argv $what] >= 0} }

open_hw_manager
connect_hw_server -allow_non_jtag
open_hw_target
set dev [lindex [get_hw_devices xc7z020*] 0]
if {$dev eq ""} { error "no xc7z020 found on the JTAG chain - is the ZedBoard connected (PROG USB port) and powered?" }
current_hw_device $dev
set_property PROBES.FILE      $ltx $dev
set_property FULL_PROBES.FILE $ltx $dev

if {[want program]} {
    set_property PROGRAM.FILE $bit $dev
    program_hw_devices $dev
    puts "programmed $bit"
    # let the receiver acquire and the settle timer run out
    after 500
}
refresh_hw_device $dev

# probe names are the connected nets, possibly with a hierarchy prefix and a
# bus range; match on the bare net name so pkt_cnt does not find bad_pkt_cnt
proc vio_value {name} {
    foreach p [get_hw_probes -of_objects [get_hw_vios]] {
        regsub {\[.*\]$} [lindex [split $p /] end] {} base
        if {$base eq $name} {
            set_property INPUT_VALUE_RADIX UNSIGNED $p
            return [get_property INPUT_VALUE $p]
        }
    }
    error "VIO probe $name not found"
}

if {[want ber]} {
    refresh_hw_vio [get_hw_vios]
    set bits [vio_value bit_cnt]
    set errs [vio_value err_cnt]
    set pkts [vio_value pkt_cnt]
    set bad  [vio_value bad_pkt_cnt]
    set lost [vio_value lost_cnt]
    set slip [vio_value slip_cnt]
    set ber  [expr {$bits > 0 ? double($errs) / $bits : 0.0}]
    puts [format "packets %d  bits %d  errors %d  BER %.3e  bad packets %d  lost %d  slipped %d" \
              $pkts $bits $errs $ber $bad $lost $slip]
}

if {[want ila]} {
    set ila [lindex [get_hw_ilas] 0]
    # store only samples where the symbol strobe is high, trigger at once
    set_property CONTROL.CAPTURE_MODE BASIC $ila
    set_property CONTROL.TRIGGER_POSITION 0 $ila
    set_property CAPTURE_COMPARE_VALUE eq1'b1 [get_hw_probes *ff_valid* -of_objects $ila]
    run_hw_ila $ila -trigger_now
    wait_on_hw_ila $ila
    set data [upload_hw_ila_data $ila]
    write_hw_ila_data -force -csv_file $out/ila_symbols.csv $data
    puts "wrote $out/ila_symbols.csv  (plot with: python plot_ila.py)"
}

close_hw_target
disconnect_hw_server
