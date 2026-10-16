#=============================================================================
# run_synth_impl.tcl
# Synthesis + implementation of ascon_aead using the Vivado project flow
# (ascon_aead.xpr, runs synth_1 / impl_1 with the project's run strategies,
# constraints in constrs_1, e.g. timing.xdc).
#
# Usage (from project root; the script path can be absolute from anywhere):
#   vivado -mode batch -source scripts/run_synth_impl.tcl
#   vivado -mode batch -source scripts/run_synth_impl.tcl -tclargs -jobs 16
#   vivado -mode batch -source scripts/run_synth_impl.tcl -tclargs \
#       -impl_strategy Performance_ExplorePostRoutePhysOpt
#   vivado -mode batch -source scripts/run_synth_impl.tcl -tclargs -impl_directives timing
#
# Args:
#   -jobs <n>                 parallel jobs for launch_runs (default: 8)
#   -synth_strategy <name>    set synth_1 strategy before running
#   -impl_strategy <name>     set impl_1 strategy before running
#   -impl_directives timing   set impl_1 step directives for best Fmax:
#                             opt Explore, place ExtraTimingOpt,
#                             phys_opt AggressiveExplore,
#                             route AggressiveExplore,
#                             post-route phys_opt AggressiveExplore
#                             (applied after -impl_strategy)
#                             (all of these are saved in the project; default:
#                              keep the project's current settings)
#   -synth_only               stop after synthesis
#
# Close the project in the Vivado GUI before running this script.
#
# Results: ascon_aead.runs/{synth_1,impl_1}/ (Vivado run reports)
#          build/project_flow/summary.txt
# Exit code: 0 = timing met, 1 = timing violated or run failed
#=============================================================================

set proj_dir  [file normalize [file join [file dirname [info script]] ..]]
set proj_file [file join $proj_dir ascon_aead.xpr]
set out_dir   [file join $proj_dir build project_flow]

#-----------------------------------------------------------------------------
# Arguments
#-----------------------------------------------------------------------------
set jobs           8
set synth_strategy ""
set impl_strategy  ""
set impl_directives ""
set synth_only     0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -jobs           { incr i; set jobs           [lindex $argv $i] }
        -synth_strategy { incr i; set synth_strategy [lindex $argv $i] }
        -impl_strategy  { incr i; set impl_strategy  [lindex $argv $i] }
        -impl_directives { incr i; set impl_directives [lindex $argv $i] }
        -synth_only     { set synth_only 1 }
        default {
            puts "ERROR: unknown argument '$a' (valid: -jobs, -synth_strategy, -impl_strategy, -impl_directives, -synth_only)"
            exit 2
        }
    }
}

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
# Launch a run and wait. Returns 1 if it completed without error.
proc run_and_wait {run jobs} {
    reset_run $run
    launch_runs $run -jobs $jobs
    wait_on_run $run
    set status   [get_property STATUS   [get_runs $run]]
    set progress [get_property PROGRESS [get_runs $run]]
    puts "  $run: $status ($progress)"
    # "Complete, Failed Timing!" is a completed run; timing is reported in the summary
    return [expr {$progress eq "100%" && ![string match "*ERROR*" $status] &&
                  ![string match "*Failed\\!*" [string map {"Failed Timing!" ""} $status]]}]
}

# "used / available (util%)" from a utilization report string
proc util_of {util name} {
    if {[regexp "\\| $name +\\| +(\\d+) \\|\[^\n\]*\\| +(\\d+) \\| +(\[\\d.<\]+) \\|" $util -> used avail pct]} {
        return "$used / $avail ($pct%)"
    }
    return "n/a"
}

proc write_summary {out_dir text} {
    file mkdir $out_dir
    set fh [open [file join $out_dir summary.txt] w]
    puts $fh $text
    close $fh
}

#-----------------------------------------------------------------------------
# Project
#-----------------------------------------------------------------------------
open_project $proj_file

if {$synth_strategy ne ""} {
    set_property strategy $synth_strategy [get_runs synth_1]
}
if {$impl_strategy ne ""} {
    set_property strategy $impl_strategy [get_runs impl_1]
}
if {$impl_directives eq "timing"} {
    set r [get_runs impl_1]
    set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE               Explore           $r
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE             ExtraTimingOpt    $r
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED              true              $r
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE          AggressiveExplore $r
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE             AggressiveExplore $r
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED   true              $r
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $r
} elseif {$impl_directives ne ""} {
    puts "ERROR: unknown -impl_directives '$impl_directives' (valid: timing)"
    exit 2
}

set top  [get_property top [current_fileset]]
set part [get_property part [current_project]]

puts "\n=================================================================="
puts " PROJECT FLOW: $top   part: $part"
puts "  synth_1: [get_property strategy [get_runs synth_1]]"
puts "  impl_1 : [get_property strategy [get_runs impl_1]]"
foreach step {OPT_DESIGN PLACE_DESIGN PHYS_OPT_DESIGN ROUTE_DESIGN POST_ROUTE_PHYS_OPT_DESIGN} {
    puts [format "    %-27s %s" $step [get_property STEPS.$step.ARGS.DIRECTIVE [get_runs impl_1]]]
}
puts "=================================================================="

#-----------------------------------------------------------------------------
# Synthesis
#-----------------------------------------------------------------------------
puts "  synthesis ..."
if {![run_and_wait synth_1 $jobs]} {
    puts "ERROR: synth_1 failed, see [get_property DIRECTORY [get_runs synth_1]]/runme.log"
    write_summary $out_dir "SYNTH FAILED"
    close_project
    exit 1
}

if {$synth_only} {
    open_run synth_1
    set wns    [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set util   [report_utilization -return_string]
    set summary "\n==================================================================\n"
    append summary " SYNTH SUMMARY (project flow)  ([clock format [clock seconds]])\n"
    append summary "==================================================================\n"
    append summary [format "  %-12s %s\n" "top"  $top]
    append summary [format "  %-12s %s\n" "part" $part]
    append summary [format "  %-12s %s ns (estimate before place & route)\n" "WNS" $wns]
    append summary [format "  %-12s %s\n" "Slice LUT" [util_of $util "Slice LUTs\\*?"]]
    append summary [format "  %-12s %s\n" "Slice FF"  [util_of $util "Slice Registers"]]
    append summary "==================================================================\n"
    puts $summary
    write_summary $out_dir $summary
    close_project
    exit 0
}

#-----------------------------------------------------------------------------
# Implementation (to route_design; no bitstream for an out-of-context top)
#-----------------------------------------------------------------------------
puts "  implementation ..."
if {![run_and_wait impl_1 $jobs]} {
    puts "ERROR: impl_1 failed, see [get_property DIRECTORY [get_runs impl_1]]/runme.log"
    write_summary $out_dir "IMPL FAILED"
    close_project
    exit 1
}

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
open_run impl_1

set clk    [lindex [get_clocks] 0]
set period [get_property PERIOD $clk]
set wns    [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set whs    [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
set fmax   [format "%.1f" [expr {1000.0 / ($period - $wns)}]]
set met    [expr {$wns >= 0 && $whs >= 0}]
set util   [report_utilization -return_string]
set power  [report_power -return_string]
set p_tot  "n/a"
set p_dyn  "n/a"
regexp {Total On-Chip Power \(W\)\s*\|\s*([\d.]+)} $power -> p_tot
regexp {Dynamic \(W\)\s*\|\s*([\d.]+)}             $power -> p_dyn

file mkdir $out_dir
report_timing_summary -max_paths 10 -file [file join $out_dir timing_summary.rpt]
report_utilization    -hierarchical -file [file join $out_dir utilization_hier.rpt]
report_power          -file [file join $out_dir power.rpt]

set summary "\n==================================================================\n"
append summary " IMPL SUMMARY (project flow)  ([clock format [clock seconds]])\n"
append summary "==================================================================\n"
append summary [format "  %-12s %s\n" "top"  $top]
append summary [format "  %-12s %s\n" "part" $part]
append summary [format "  %-12s %s / %s\n" "strategy" \
    [get_property strategy [get_runs synth_1]] [get_property strategy [get_runs impl_1]]]
append summary [format "  %-12s %s ns ([format %.1f [expr {1000.0 / $period}]] MHz)\n" "clk period" $period]
append summary [format "  %-12s %s ns\n" "WNS (setup)" $wns]
append summary [format "  %-12s %s ns\n" "WHS (hold)"  $whs]
append summary [format "  %-12s %s MHz\n" "Fmax (est)" $fmax]
append summary [format "  %-12s %s\n" "Slice LUT" [util_of $util "Slice LUTs\\*?"]]
append summary [format "  %-12s %s\n" "Slice FF"  [util_of $util "Slice Registers"]]
append summary [format "  %-12s %s W total, %s W dynamic\n" "power" $p_tot $p_dyn]
append summary [format "  %-12s %s\n" "timing" [expr {$met ? "MET" : "VIOLATED"}]]
append summary "  runs:        [file join $proj_dir ascon_aead.runs]\n"
append summary "  reports:     $out_dir\n"
append summary "==================================================================\n"

puts $summary
write_summary $out_dir $summary

close_project
exit [expr {$met ? 0 : 1}]
