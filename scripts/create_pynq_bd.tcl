#=============================================================================
# create_pynq_bd.tcl
# PYNQ-Z1 overlay for the per-message gateway latency measurement:
# Zynq PS (M_AXI_GP0, FCLK_CLK0) -> AXI interconnect -> ascon_aead_axi_multi #(K)
# at 0x43C0_0000 (4 KB). Builds the bitstream and exports <name>.bit + .hwh
# for PYNQ (same basename, as PYNQ requires).
#
# Usage (from project root; separate project, does not touch ascon_aead.xpr):
#   vivado -mode batch -source scripts/create_pynq_bd.tcl
#   vivado -mode batch -source scripts/create_pynq_bd.tcl -tclargs -k 4 -fclk 142.86
#
# Args:
#   -k <n>        number of cores                       (default 4)
#   -fclk <MHz>   requested PL clock FCLK_CLK0          (default 142.86;
#                 Zynq IO PLL 1 GHz -> 250, 200, 166.67, 142.86, 125, 100, ...)
#   -jobs <n>     parallel jobs                         (default 8)
#
# Uses the PYNQ-Z1 board preset when the board files are installed, else the
# plain part xc7z020clg400-1 (enough for a PYNQ overlay: the PS DDR / MIO are
# configured by the PYNQ boot image, the overlay only sets FCLK and GP0).
#
# Results: build/pynq/overlay/ascon_gw.bit, ascon_gw.hwh, build_info.txt
# Exit code 1 if routed timing fails (WNS < 0 or WHS < 0) - no bitstream is
# exported then; re-run with a lower -fclk.
# Vivado 2023.2, K = 4: 200 MHz fails (WNS -1.338 ns); 142.86 MHz meets
# (WNS +0.303 ns, 6,302 LUT, 4,938 FF).
#=============================================================================

set proj_dir [file normalize [file join [file dirname [info script]] ..]]
set src_dir  [file join $proj_dir ascon_aead.srcs sources_1 new]
set out_dir  [file join $proj_dir build pynq]
set ovl_dir  [file join $out_dir overlay]

set k    4
set fclk 142.86
set jobs 8
for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -k    { incr i; set k    [lindex $argv $i] }
        -fclk { incr i; set fclk [lindex $argv $i] }
        -jobs { incr i; set jobs [lindex $argv $i] }
        default { puts "ERROR: unknown argument '$a' (valid: -k, -fclk, -jobs)"; exit 2 }
    }
}

set part "xc7z020clg400-1"
set board [lindex [get_board_parts -quiet -latest_file_version *pynq-z1*] 0]

file mkdir $out_dir
create_project pynq_gw [file join $out_dir proj] -part $part -force
if {$board ne ""} {
    set_property board_part $board [current_project]
    puts "INFO: using board part $board"
} else {
    puts "INFO: PYNQ-Z1 board files not found - using part $part"
}

foreach f {ascon_round.v ascon_aead_datapath.v ascon_aead_control.v ascon_aead.v ascon_aead_axi_multi.v} {
    add_files -norecurse [file join $src_dir $f]
}
update_compile_order -fileset sources_1

#-----------------------------------------------------------------------------
# Block design
#-----------------------------------------------------------------------------
create_bd_design gw

set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:processing_system7 ps7]
apply_bd_automation -rule xilinx.com:bd_rule:processing_system7 \
    -config [list make_external "FIXED_IO, DDR" apply_board_preset [expr {$board ne "" ? 1 : 0}] Master "Disable" Slave "Disable"] $ps
set_property -dict [list \
    CONFIG.PCW_USE_M_AXI_GP0 {1} \
    CONFIG.PCW_FPGA0_PERIPHERAL_FREQMHZ $fclk \
    CONFIG.PCW_EN_CLK0_PORT {1} \
    CONFIG.PCW_EN_RST0_PORT {1} \
] $ps

set gw [create_bd_cell -type module -reference ascon_aead_axi_multi gw]
set_property CONFIG.K $k $gw

apply_bd_automation -rule xilinx.com:bd_rule:axi4 -config [list \
    Clk_master {/ps7/FCLK_CLK0 (*)} Clk_slave {Auto} Clk_xbar {Auto} \
    Master {/ps7/M_AXI_GP0} Slave {/gw/s_axi} ddr_seg {Auto} \
    intc_ip {New AXI Interconnect} master_apm {0}] [get_bd_intf_pins gw/s_axi]

# Fixed address 0x43C0_0000, 4 KB (matches gw_latency.c default)
set seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps7/Data]]
set_property offset 0x43C00000 $seg
set_property range 4K $seg

validate_bd_design
save_bd_design

set act_fclk [get_property CONFIG.PCW_ACT_FPGA0_PERIPHERAL_FREQMHZ $ps]
puts "INFO: FCLK_CLK0 requested $fclk MHz, actual $act_fclk MHz"

make_wrapper -files [get_files gw.bd] -top
add_files -norecurse [file join $out_dir proj pynq_gw.gen sources_1 bd gw hdl gw_wrapper.v]
set_property top gw_wrapper [current_fileset]
update_compile_order -fileset sources_1

#-----------------------------------------------------------------------------
# Build
#-----------------------------------------------------------------------------
launch_runs synth_1 -jobs $jobs
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1

open_run impl_1
set wns  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set util [report_utilization -return_string]
regexp {\| Slice LUTs\s+\|\s+(\d+)} $util -> lut
regexp {\| Slice Registers\s+\|\s+(\d+)} $util -> ff
report_timing_summary -max_paths 10 -file [file join $out_dir timing_summary.rpt]
report_utilization -hierarchical  -file [file join $out_dir utilization_hier.rpt]

set info "K=$k fclk_requested=$fclk fclk_actual=$act_fclk WNS=$wns WHS=$whs LUT=$lut FF=$ff part=$part board=$board"
puts "BUILD $info"

if {$wns < 0 || $whs < 0} {
    puts "ERROR: timing not met at $act_fclk MHz - bitstream NOT exported; re-run with a lower -fclk"
    set fh [open [file join $out_dir build_info.txt] w]; puts $fh "TIMING FAILED $info"; close $fh
    exit 1
}

file mkdir $ovl_dir
set bit [glob [file join $out_dir proj pynq_gw.runs impl_1 *.bit]]
set hwh [glob [file join $out_dir proj pynq_gw.gen sources_1 bd gw hw_handoff gw.hwh]]
file copy -force $bit [file join $ovl_dir ascon_gw.bit]
file copy -force $hwh [file join $ovl_dir ascon_gw.hwh]
set fh [open [file join $ovl_dir build_info.txt] w]
puts $fh $info
close $fh
puts "INFO: overlay written to $ovl_dir (ascon_gw.bit, ascon_gw.hwh)"
exit 0
