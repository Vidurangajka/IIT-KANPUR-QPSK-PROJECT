## ZedBoard (xc7z020clg484-1) - QPSK loopback demo
## Pins from Digilent's Zedboard-Master.xdc.

## 100 MHz board clock (bank 13, 3.3 V); the MMCM output clock is derived
set_property PACKAGE_PIN Y9 [get_ports clk_100]
create_clock -name sys_clk -period 10.000 [get_ports clk_100]

## User LEDs LD0-LD7 (bank 33, 3.3 V)
set_property PACKAGE_PIN T22 [get_ports {led[0]}]
set_property PACKAGE_PIN T21 [get_ports {led[1]}]
set_property PACKAGE_PIN U22 [get_ports {led[2]}]
set_property PACKAGE_PIN U21 [get_ports {led[3]}]
set_property PACKAGE_PIN V22 [get_ports {led[4]}]
set_property PACKAGE_PIN W22 [get_ports {led[5]}]
set_property PACKAGE_PIN U19 [get_ports {led[6]}]
set_property PACKAGE_PIN U14 [get_ports {led[7]}]

## User switches SW0-SW7 (banks 35 and 34, VADJ)
set_property PACKAGE_PIN F22 [get_ports {sw[0]}]
set_property PACKAGE_PIN G22 [get_ports {sw[1]}]
set_property PACKAGE_PIN H22 [get_ports {sw[2]}]
set_property PACKAGE_PIN F21 [get_ports {sw[3]}]
set_property PACKAGE_PIN H19 [get_ports {sw[4]}]
set_property PACKAGE_PIN H18 [get_ports {sw[5]}]
set_property PACKAGE_PIN H17 [get_ports {sw[6]}]
set_property PACKAGE_PIN M15 [get_ports {sw[7]}]

## Push buttons (bank 34, VADJ)
set_property PACKAGE_PIN P16 [get_ports btnc]
set_property PACKAGE_PIN T18 [get_ports btnu]

## I/O standards per bank.  Banks 13 and 33 are fixed at 3.3 V.  Banks 34 and
## 35 run at VADJ, set by jumper J18; Digilent's default is 1.8 V.  If your
## J18 is set to 2.5 V or 3.3 V, change the two LVCMOS18 lines to match.
set_property IOSTANDARD LVCMOS33 [get_ports -of_objects [get_iobanks 13]]
set_property IOSTANDARD LVCMOS33 [get_ports -of_objects [get_iobanks 33]]
set_property IOSTANDARD LVCMOS18 [get_ports -of_objects [get_iobanks 34]]
set_property IOSTANDARD LVCMOS18 [get_ports -of_objects [get_iobanks 35]]

## Switches and buttons are asynchronous and go through a synchroniser and
## debouncer; LEDs are static indicators.
set_false_path -from [get_ports {sw[*] btnc btnu}]
set_false_path -to   [get_ports {led[*]}]
