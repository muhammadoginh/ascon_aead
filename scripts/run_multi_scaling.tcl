#=============================================================================
# run_multi_scaling.tcl
# Resource / timing scaling of ascon_aead_axi_multi #(K) (non-project flow,
# out-of-context synthesis + implementation for each K).
#
# Usage (from project root):
#   vivado -mode batch -source scripts/run_multi_scaling.tcl
#   vivado -mode batch -source scripts/run_multi_scaling.tcl -tclargs \
#       -k "1 2 4 8" -period 3.283 -part xc7z020clg400-1
#   # resource-only on another device:
#   vivado -mode batch -source scripts/run_multi_scaling.tcl -tclargs \
#       -part xc7a100tcsg324-1 -synth_only
#
# Args:
#   -k "<list>"      core counts            (default: "1 2 4 8")
#   -period <ns>     clock constraint       (default: 3.283)
#   -part <part>     target part            (default: xc7z020clg400-1)
#   -synth_only      skip implementation (resource numbers from synthesis)
#
# Results: build/multi_scaling/<part>/scaling.csv
#          build/multi_scaling/<part>/K<k>/*.rpt
# WNS here is with default implementation directives; use find_fmax.tcl
# (project flow) for the closed-timing Fmax of a chosen K.
#=============================================================================

set proj_dir [file normalize [file join [file dirname [info script]] ..]]
set src_dir  [file join $proj_dir ascon_aead.srcs sources_1 new]

set k_list     {1 2 4 8}
set period     3.283
set part       "xc7z020clg400-1"
set synth_only 0

for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -k          { incr i; set k_list [lindex $argv $i] }
        -period     { incr i; set period [lindex $argv $i] }
        -part       { incr i; set part   [lindex $argv $i] }
        -synth_only { set synth_only 1 }
        default {
            puts "ERROR: unknown argument '$a' (valid: -k, -period, -part, -synth_only)"
            exit 2
        }
    }
}

set out_dir [file join $proj_dir build multi_scaling $part]
file mkdir $out_dir

proc util_of {util name} {
    if {[regexp "\\| $name +\\| +(\\d+) \\|" $util -> used]} { return $used }
    return "n/a"
}

set rtl [list ascon_round.v ascon_aead_datapath.v ascon_aead_control.v ascon_aead.v ascon_aead_axi_multi.v]

set fh [open [file join $out_dir scaling.csv] w]
puts $fh "part,K,stage,lut,ff,period_ns,wns_ns,whs_ns,power_w,dyn_power_w"

foreach k $k_list {
    puts "\n>>> K = $k ($part)"
    set kdir [file join $out_dir K$k]
    file mkdir $kdir

    foreach f $rtl { read_verilog [file join $src_dir $f] }
    synth_design -top ascon_aead_axi_multi -part $part -mode out_of_context -generic K=$k
    create_clock -period $period -name clk [get_ports s_axi_aclk]

    set stage synth
    if {!$synth_only} {
        opt_design
        place_design
        phys_opt_design
        route_design
        set stage impl
    }

    set util  [report_utilization -return_string]
    set lut   [util_of $util "Slice LUTs\\*?"]
    set ff    [util_of $util "Slice Registers"]
    set wns   [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
    set whs   [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
    set power [report_power -return_string]
    set p_tot "n/a"; set p_dyn "n/a"
    regexp {Total On-Chip Power \(W\)\s*\|\s*([\d.]+)} $power -> p_tot
    regexp {Dynamic \(W\)\s*\|\s*([\d.]+)}             $power -> p_dyn

    report_utilization -hierarchical -file [file join $kdir utilization_hier.rpt]
    report_timing_summary -max_paths 5 -file [file join $kdir timing_summary.rpt]
    report_power -file [file join $kdir power.rpt]

    puts $fh "$part,$k,$stage,$lut,$ff,$period,$wns,$whs,$p_tot,$p_dyn"
    flush $fh
    puts "RESULT K=$k $stage LUT=$lut FF=$ff WNS=$wns WHS=$whs P=$p_tot"
    close_design
}
close $fh
exit 0
