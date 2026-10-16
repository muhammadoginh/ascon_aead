#=============================================================================
# run_synth.tcl
# Out-of-context synthesis of ascon_aead (Vivado non-project flow).
#
# The core has ~800 I/O ports, more than any package pin count, so it is
# synthesized out-of-context (no I/O buffers). Bitstream generation needs a
# top-level wrapper (e.g. AXI for PYNQ) around it.
#
# Usage (from project root; the script path can be absolute from anywhere):
#   vivado -mode batch -source scripts/run_synth.tcl
#   vivado -mode batch -source scripts/run_synth.tcl -tclargs -period 8.0
#
# Args:
#   -top <name>       top module (default: ascon_aead)
#   -part <part>      target part (default: xc7z020clg400-1, PYNQ-Z1)
#   -period <ns>      clk period constraint (default: 10.0 = 100 MHz)
#
# Results: build/synth/{post_synth.dcp, *.rpt, synth.xdc}
#=============================================================================

set proj_dir [file normalize [file join [file dirname [info script]] ..]]
set src_dir  [file join $proj_dir ascon_aead.srcs sources_1 new]
set out_dir  [file join $proj_dir build synth]

#-----------------------------------------------------------------------------
# Arguments
#-----------------------------------------------------------------------------
set top    "ascon_aead"
set part   "xc7z020clg400-1"
set period 10.0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -top    { incr i; set top    [lindex $argv $i] }
        -part   { incr i; set part   [lindex $argv $i] }
        -period { incr i; set period [lindex $argv $i] }
        default {
            puts "ERROR: unknown argument '$a' (valid: -top, -part, -period)"
            exit 2
        }
    }
}

file mkdir $out_dir

#-----------------------------------------------------------------------------
# Constraints
#-----------------------------------------------------------------------------
set xdc [file join $out_dir synth.xdc]
set fh [open $xdc w]
puts $fh "create_clock -period $period -name clk \[get_ports clk\]"
close $fh

#-----------------------------------------------------------------------------
# Synthesis
#-----------------------------------------------------------------------------
puts "\n=================================================================="
puts " SYNTH: $top   part: $part   clk: $period ns"
puts "=================================================================="

read_verilog [lsort [glob -directory $src_dir *.v]]
read_xdc -mode out_of_context $xdc

synth_design -top $top -part $part -mode out_of_context

write_checkpoint -force [file join $out_dir post_synth.dcp]
report_utilization    -file [file join $out_dir utilization.rpt]
report_utilization    -hierarchical -file [file join $out_dir utilization_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $out_dir timing_summary.rpt]

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
set wns  [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
# "used / available (util%)" from the utilization report
set util [report_utilization -return_string]
proc util_of {util name} {
    if {[regexp "\\| $name +\\| +(\\d+) \\|\[^\n\]*\\| +(\\d+) \\| +(\[\\d.<\]+) \\|" $util -> used avail pct]} {
        return "$used / $avail ($pct%)"
    }
    return "n/a"
}
set luts [util_of $util "Slice LUTs\\*?"]
set ffs  [util_of $util "Slice Registers"]

set summary "\n==================================================================\n"
append summary " SYNTH SUMMARY  ([clock format [clock seconds]])\n"
append summary "==================================================================\n"
append summary [format "  %-12s %s\n" "top"    $top]
append summary [format "  %-12s %s\n" "part"   $part]
append summary [format "  %-12s %s ns\n" "clk period" $period]
append summary [format "  %-12s %s ns (estimate before place & route)\n" "WNS" $wns]
append summary [format "  %-12s %s\n" "Slice LUT" $luts]
append summary [format "  %-12s %s\n" "Slice FF"  $ffs]
append summary "  reports:     $out_dir\n"
append summary "==================================================================\n"

puts $summary
set fh [open [file join $out_dir summary.txt] w]
puts $fh $summary
close $fh

exit 0
