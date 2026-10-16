#=============================================================================
# find_fmax.tcl
# Find the maximum clock frequency of ascon_aead with the Vivado project
# flow: for each clock period, write constrs_1/new/timing.xdc, run synth_1
# and impl_1, and check that timing closes (WNS >= 0 and WHS >= 0).
#
# Fmax is reported as 1 / (tightest period that closes timing) - no
# estimate from negative slack.
#
# The sweep goes from -start down to -min in steps of -step and stops after
# two consecutive failing periods. Vivado results are not strictly
# monotonic in the period, so a step-down sweep is used, not a bisection.
# At the end timing.xdc is set to the best passing period and that run is
# repeated, so the project runs / reports match the reported Fmax.
#
# Usage (from project root; close the project in the Vivado GUI first):
#   vivado -mode batch -source scripts/find_fmax.tcl
#   vivado -mode batch -source scripts/find_fmax.tcl -tclargs \
#       -start 3.333 -min 3.0 -step 0.05 -impl_directives timing
#
# Args:
#   -start <ns>              first (loosest) period    (default: 3.333)
#   -min <ns>                tightest period to try    (default: 2.9)
#   -step <ns>               period step               (default: 0.05)
#   -impl_strategy <name>    impl_1 strategy           (default: keep project's)
#   -impl_directives timing  same as run_synth_impl.tcl (default: keep project's)
#   -jobs <n>                launch_runs jobs          (default: 8)
#
# Results: build/fmax_sweep/results.txt  (one line per period)
#          build/fmax_sweep/summary.txt  (best passing period)
#          build/fmax_sweep/<period>/    (timing / utilization / power reports)
#=============================================================================

set proj_dir  [file normalize [file join [file dirname [info script]] ..]]
set proj_file [file join $proj_dir ascon_aead.xpr]
set xdc_file  [file join $proj_dir ascon_aead.srcs constrs_1 new timing.xdc]
set out_dir   [file join $proj_dir build fmax_sweep]

#-----------------------------------------------------------------------------
# Arguments
#-----------------------------------------------------------------------------
set start           3.333
set min_period      2.9
set step            0.05
set impl_strategy   ""
set impl_directives ""
set jobs            8

for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -start           { incr i; set start           [lindex $argv $i] }
        -min             { incr i; set min_period      [lindex $argv $i] }
        -step            { incr i; set step            [lindex $argv $i] }
        -impl_strategy   { incr i; set impl_strategy   [lindex $argv $i] }
        -impl_directives { incr i; set impl_directives [lindex $argv $i] }
        -jobs            { incr i; set jobs            [lindex $argv $i] }
        default {
            puts "ERROR: unknown argument '$a' (valid: -start, -min, -step, -impl_strategy, -impl_directives, -jobs)"
            exit 2
        }
    }
}

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
proc write_xdc {xdc_file period} {
    set half [format "%.3f" [expr {$period / 2.0}]]
    set fh [open $xdc_file w]
    puts $fh "# Clock constraint (set by scripts/find_fmax.tcl)."
    puts $fh "# Fmax = 1 / period of the tightest constraint that closes timing (WNS >= 0, WHS >= 0)."
    puts $fh "create_clock -period $period -name clk -waveform {0.000 $half} \[get_ports clk\]"
    close $fh
}

# Launch a run and wait. Returns 1 if it completed (timing failure still counts as completed).
proc run_and_wait {run jobs} {
    reset_run $run
    launch_runs $run -jobs $jobs
    wait_on_run $run
    set status   [get_property STATUS   [get_runs $run]]
    set progress [get_property PROGRESS [get_runs $run]]
    return [expr {$progress eq "100%" && ![string match "*ERROR*" $status] &&
                  ![string match "*Failed\\!*" [string map {"Failed Timing!" ""} $status]]}]
}

proc util_of {util name} {
    if {[regexp "\\| $name +\\| +(\\d+) \\|" $util -> used]} { return $used }
    return "n/a"
}

# Run synth + impl at one period; returns {ok wns whs lut ff p_tot p_dyn}
proc try_period {period xdc_file out_dir jobs} {
    write_xdc $xdc_file $period
    if {![run_and_wait synth_1 $jobs]} { return {0 n/a n/a n/a n/a n/a n/a} }
    if {![run_and_wait impl_1  $jobs]} { return {0 n/a n/a n/a n/a n/a n/a} }

    open_run impl_1
    set wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    set util  [report_utilization -return_string]
    set power [report_power -return_string]
    set p_tot "n/a"; set p_dyn "n/a"
    regexp {Total On-Chip Power \(W\)\s*\|\s*([\d.]+)} $power -> p_tot
    regexp {Dynamic \(W\)\s*\|\s*([\d.]+)}             $power -> p_dyn

    set d [file join $out_dir $period]
    file mkdir $d
    report_timing_summary -max_paths 10 -file [file join $d timing_summary.rpt]
    report_utilization    -hierarchical -file [file join $d utilization_hier.rpt]
    report_power          -file [file join $d power.rpt]
    close_design

    return [list 1 $wns $whs [util_of $util "Slice LUTs\\*?"] [util_of $util "Slice Registers"] $p_tot $p_dyn]
}

proc log_line {fh text} {
    puts $text
    puts $fh $text
    flush $fh
}

#-----------------------------------------------------------------------------
# Project
#-----------------------------------------------------------------------------
open_project $proj_file

if {$impl_strategy ne ""} {
    set_property strategy $impl_strategy [get_runs impl_1]
}
if {$impl_directives eq "timing"} {
    set r [get_runs impl_1]
    set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE                 Explore           $r
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE               ExtraTimingOpt    $r
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED                true              $r
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE            AggressiveExplore $r
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE               AggressiveExplore $r
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED     true              $r
    set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore $r
} elseif {$impl_directives ne ""} {
    puts "ERROR: unknown -impl_directives '$impl_directives' (valid: timing)"
    exit 2
}

file mkdir $out_dir
set fh [open [file join $out_dir results.txt] w]
log_line $fh "# find_fmax  [clock format [clock seconds]]"
log_line $fh "# synth_1: [get_property strategy [get_runs synth_1]]   impl_1: [get_property strategy [get_runs impl_1]]"
foreach step_name {OPT_DESIGN PLACE_DESIGN PHYS_OPT_DESIGN ROUTE_DESIGN POST_ROUTE_PHYS_OPT_DESIGN} {
    log_line $fh [format "#   %-27s %s" $step_name [get_property STEPS.$step_name.ARGS.DIRECTIVE [get_runs impl_1]]]
}
log_line $fh [format "# %-7s %-8s %-8s %-8s %-6s %-6s %-7s %-7s %s" period MHz WNS WHS LUT FF P_tot P_dyn result]

#-----------------------------------------------------------------------------
# Sweep
#-----------------------------------------------------------------------------
set best    ""
set fails   0
set n_steps [expr {int(floor(($start - $min_period) / $step + 1e-6))}]

for {set k 0} {$k <= $n_steps && $fails < 2} {incr k} {
    set period [format "%.3f" [expr {$start - $k * $step}]]
    puts "\n>>> period $period ns"
    lassign [try_period $period $xdc_file $out_dir $jobs] ok wns whs lut ff p_tot p_dyn

    if {!$ok} {
        set res "RUN_FAILED"
        incr fails
    } elseif {$wns >= 0 && $whs >= 0} {
        set res "MET"
        set best [list $period $wns $whs $lut $ff $p_tot $p_dyn]
        set fails 0
    } else {
        set res "VIOLATED"
        incr fails
    }
    log_line $fh [format "  %-7s %-8.1f %-8s %-8s %-6s %-6s %-7s %-7s %s" \
        $period [expr {1000.0 / $period}] $wns $whs $lut $ff $p_tot $p_dyn $res]
}

#-----------------------------------------------------------------------------
# Leave the project at the best passing period
#-----------------------------------------------------------------------------
if {$best eq ""} {
    log_line $fh "# no period closed timing"
    close $fh
    write_xdc $xdc_file $start
    close_project
    exit 1
}

lassign $best b_period b_wns b_whs b_lut b_ff b_ptot b_pdyn
if {$period ne $b_period} {
    puts "\n>>> re-running best period $b_period ns so the project runs match"
    lassign [try_period $b_period $xdc_file $out_dir $jobs] ok wns whs lut ff p_tot p_dyn
    if {!($ok && $wns >= 0 && $whs >= 0)} {
        log_line $fh "# WARNING: re-run of $b_period ns did not reproduce MET (WNS=$wns WHS=$whs)"
    }
}
close $fh

set summary "\n==================================================================\n"
append summary " FMAX SUMMARY (project flow)  ([clock format [clock seconds]])\n"
append summary "==================================================================\n"
append summary [format "  %-14s %s ns\n"  "best period"  $b_period]
append summary [format "  %-14s %.1f MHz (timing closed)\n" "Fmax" [expr {1000.0 / $b_period}]]
append summary [format "  %-14s %s ns / %s ns\n" "WNS / WHS" $b_wns $b_whs]
append summary [format "  %-14s %s / %s\n" "Slice LUT / FF" $b_lut $b_ff]
append summary [format "  %-14s %s W total, %s W dynamic\n" "power" $b_ptot $b_pdyn]
append summary "  timing.xdc:    set to $b_period ns\n"
append summary "  all periods:   [file join $out_dir results.txt]\n"
append summary "==================================================================\n"
puts $summary
set fh [open [file join $out_dir summary.txt] w]
puts $fh $summary
close $fh

close_project
exit 0
