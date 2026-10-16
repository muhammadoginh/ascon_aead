#=============================================================================
# find_fmax_ooc.tcl
# Closed-timing Fmax of one design (non-project, out-of-context flow).
#
# Fmax = 1 / tightest clock period at which implementation meets timing
# (WNS >= 0 and WHS >= 0). No estimate from negative slack is reported.
#
# Search: run at -start; if it fails, jump to the period implied by the
# slack (rounded up to -step) and loosen by -step until timing is met; then
# tighten by -step until two consecutive periods fail. Every run is logged.
# Synthesis is re-run for every period (the clock constraint is read before
# synth_design). Implementation directives are the same as
# run_synth_impl.tcl -impl_directives timing.
#
# Usage (from project root):
#   vivado -mode batch -source scripts/find_fmax_ooc.tcl -tclargs \
#       -top ascon_aead_axi_multi -k 4 -clk s_axi_aclk -start 4.0
#   vivado -mode batch -source scripts/find_fmax_ooc.tcl -tclargs \
#       -top ascon_aead_axi -clk s_axi_aclk -start 4.0
#
# Args:
#   -top <module>     ascon_aead | ascon_aead_array | ascon_aead_axi | ascon_aead_axi_multi
#   -k <n>            K generic (ascon_aead_array, ascon_aead_axi_multi)
#   -clk <port>       clock port (clk for ascon_aead, s_axi_aclk for wrappers)
#   -start <ns>       first period             (default 4.0)
#   -step <ns>        period step              (default 0.05)
#   -max_runs <n>     safety limit             (default 20)
#   -part <part>      target part              (default xc7z020clg400-1)
#
# Results: build/fmax_ooc/<part>/<name>/results.txt, summary.txt, reports
#=============================================================================

set proj_dir [file normalize [file join [file dirname [info script]] ..]]
set src_dir  [file join $proj_dir ascon_aead.srcs sources_1 new]

set top      ""
set k        ""
set clk      "clk"
set start    4.0
set step     0.05
set max_runs 20
set part     "xc7z020clg400-1"

for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -top      { incr i; set top      [lindex $argv $i] }
        -k        { incr i; set k        [lindex $argv $i] }
        -clk      { incr i; set clk      [lindex $argv $i] }
        -start    { incr i; set start    [lindex $argv $i] }
        -step     { incr i; set step     [lindex $argv $i] }
        -max_runs { incr i; set max_runs [lindex $argv $i] }
        -part     { incr i; set part     [lindex $argv $i] }
        default {
            puts "ERROR: unknown argument '$a'"
            exit 2
        }
    }
}
if {$top eq ""} { puts "ERROR: -top is required"; exit 2 }

set name [expr {$k eq "" ? $top : "${top}_K${k}"}]
set out_dir [file join $proj_dir build fmax_ooc $part $name]
file mkdir $out_dir

set rtl [list ascon_round.v ascon_aead_datapath.v ascon_aead_control.v ascon_aead.v \
              ascon_aead_axi.v ascon_aead_axi_multi.v ascon_aead_array.v]

proc util_of {util name} {
    if {[regexp "\\| $name +\\| +(\\d+) \\|" $util -> used]} { return $used }
    return "n/a"
}

# One synth + impl run; returns {wns whs lut ff p_tot p_dyn}
proc run_period {period} {
    global src_dir rtl top k clk part out_dir
    set xdc [file join $out_dir clock.xdc]
    set fh [open $xdc w]
    puts $fh "create_clock -period $period -name clk \[get_ports $clk\]"
    close $fh

    foreach f $rtl { read_verilog [file join $src_dir $f] }
    read_xdc -mode out_of_context $xdc
    if {$k eq ""} {
        synth_design -top $top -part $part -mode out_of_context
    } else {
        synth_design -top $top -part $part -mode out_of_context -generic K=$k
    }
    opt_design      -directive Explore
    place_design    -directive ExtraTimingOpt
    phys_opt_design -directive AggressiveExplore
    route_design    -directive AggressiveExplore
    phys_opt_design -directive AggressiveExplore

    set wns   [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs   [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    set util  [report_utilization -return_string]
    set power [report_power -return_string]
    set p_tot "n/a"; set p_dyn "n/a"
    regexp {Total On-Chip Power \(W\)\s*\|\s*([\d.]+)} $power -> p_tot
    regexp {Dynamic \(W\)\s*\|\s*([\d.]+)}             $power -> p_dyn

    set d [file join $out_dir $period]
    file mkdir $d
    report_timing_summary -max_paths 10 -file [file join $d timing_summary.rpt]
    report_utilization -hierarchical -file [file join $d utilization_hier.rpt]
    report_power -file [file join $d power.rpt]
    close_design
    return [list $wns $whs [util_of $util "Slice LUTs\\*?"] [util_of $util "Slice Registers"] $p_tot $p_dyn]
}

set log [open [file join $out_dir results.txt] w]
proc log_line {text} {
    global log
    puts $text
    puts $log $text
    flush $log
}
log_line "# find_fmax_ooc $name on $part  [clock format [clock seconds]]"
log_line "# directives: opt Explore, place ExtraTimingOpt, phys_opt/route/post-route phys_opt AggressiveExplore"
log_line [format "# %-7s %-7s %-8s %-8s %-6s %-6s %-7s %-7s %s" period MHz WNS WHS LUT FF P_tot P_dyn result]

array set tried {}
set best ""
set runs 0

proc try {period} {
    global tried best runs
    set period [format "%.3f" $period]
    if {[info exists tried($period)]} { return $tried($period) }
    incr runs
    puts "\n>>> period $period ns"
    lassign [run_period $period] wns whs lut ff p_tot p_dyn
    set met [expr {$wns >= 0 && $whs >= 0}]
    set tried($period) [list $met $wns]
    if {$met && ($best eq "" || $period < [lindex $best 0])} {
        set best [list $period $wns $whs $lut $ff $p_tot $p_dyn]
    }
    log_line [format "  %-7s %-7.1f %-8s %-8s %-6s %-6s %-7s %-7s %s" \
        $period [expr {1000.0 / $period}] $wns $whs $lut $ff $p_tot $p_dyn [expr {$met ? "MET" : "VIOLATED"}]]
    return $tried($period)
}

# 1. start, and loosen until met
lassign [try $start] met wns
set p $start
if {!$met} {
    set p [expr {ceil(($start - $wns) / $step - 1e-6) * $step}]
    while {$runs < $max_runs} {
        lassign [try $p] met wns
        if {$met} break
        set p [expr {$p + $step}]
    }
}

# 2. tighten until two consecutive fails
set fails 0
set p [expr {$p - $step}]
while {$fails < 2 && $runs < $max_runs && $best ne ""} {
    lassign [try $p] met wns
    if {$met} { set fails 0 } else { incr fails }
    set p [expr {$p - $step}]
}

if {$best eq ""} {
    log_line "# no period met timing within $max_runs runs"
    close $log
    exit 1
}
lassign $best b_p b_wns b_whs b_lut b_ff b_pt b_pd
set summary [format "%s,%s,%s,%.1f,%s,%s,%s,%s,%s,%s" $part $name $b_p [expr {1000.0 / $b_p}] $b_wns $b_whs $b_lut $b_ff $b_pt $b_pd]
log_line "# BEST $b_p ns = [format %.1f [expr {1000.0 / $b_p}]] MHz (WNS $b_wns, WHS $b_whs)"
close $log
set fh [open [file join $out_dir summary.txt] w]
puts $fh "part,design,period_ns,fmax_mhz,wns_ns,whs_ns,lut,ff,power_w,dyn_power_w"
puts $fh $summary
close $fh
puts "FMAX $summary"
exit 0
