#=============================================================================
# run_impl.tcl
# Out-of-context implementation of ascon_aead (Vivado non-project flow).
# Starts from build/synth/post_synth.dcp, so run run_synth.tcl first.
#
# Usage (from project root; the script path can be absolute from anywhere):
#   vivado -mode batch -source scripts/run_synth.tcl
#   vivado -mode batch -source scripts/run_impl.tcl
#
# The clock constraint and part come from the synthesis checkpoint.
#
# Results: build/impl/{post_place.dcp, post_route.dcp, *.rpt}
# Exit code: 0 = timing met, 1 = timing violated
#=============================================================================

set proj_dir [file normalize [file join [file dirname [info script]] ..]]
set synth_dcp [file join $proj_dir build synth post_synth.dcp]
set out_dir   [file join $proj_dir build impl]

if {[llength $argv] > 0} {
    puts "ERROR: run_impl.tcl takes no arguments"
    exit 2
}

if {![file exists $synth_dcp]} {
    puts "ERROR: $synth_dcp not found. Run scripts/run_synth.tcl first."
    exit 2
}

file mkdir $out_dir

#-----------------------------------------------------------------------------
# Implementation
#-----------------------------------------------------------------------------
puts "\n=================================================================="
puts " IMPL: $synth_dcp"
puts "=================================================================="

open_checkpoint $synth_dcp

opt_design
place_design
phys_opt_design
write_checkpoint -force [file join $out_dir post_place.dcp]

route_design
write_checkpoint -force [file join $out_dir post_route.dcp]

report_utilization    -file [file join $out_dir utilization.rpt]
report_utilization    -hierarchical -file [file join $out_dir utilization_hier.rpt]
report_timing_summary -max_paths 10 -file [file join $out_dir timing_summary.rpt]
report_route_status   -file [file join $out_dir route_status.rpt]
report_drc            -file [file join $out_dir drc.rpt]
report_power          -file [file join $out_dir power.rpt]

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
set top    [get_property TOP [current_design]]
set part   [get_property PART [current_design]]
set period [get_property PERIOD [get_clocks clk]]
set wns    [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs    [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
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
set fmax   [format "%.1f" [expr {1000.0 / ($period - $wns)}]]
set met    [expr {$wns >= 0 && $whs >= 0}]

set summary "\n==================================================================\n"
append summary " IMPL SUMMARY  ([clock format [clock seconds]])\n"
append summary "==================================================================\n"
append summary [format "  %-12s %s\n" "top"    $top]
append summary [format "  %-12s %s\n" "part"   $part]
append summary [format "  %-12s %s ns\n" "clk period" $period]
append summary [format "  %-12s %s ns\n" "WNS (setup)" $wns]
append summary [format "  %-12s %s ns\n" "WHS (hold)"  $whs]
append summary [format "  %-12s %s MHz\n" "Fmax (est)" $fmax]
append summary [format "  %-12s %s\n" "Slice LUT" $luts]
append summary [format "  %-12s %s\n" "Slice FF"  $ffs]
append summary [format "  %-12s %s\n" "timing" [expr {$met ? "MET" : "VIOLATED"}]]
append summary "  reports:     $out_dir\n"
append summary "==================================================================\n"

puts $summary
set fh [open [file join $out_dir summary.txt] w]
puts $fh $summary
close $fh

exit [expr {$met ? 0 : 1}]
