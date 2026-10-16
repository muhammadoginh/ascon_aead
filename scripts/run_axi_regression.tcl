#=============================================================================
# run_axi_regression.tcl
# AXI4-Lite simulation regression for ascon_aead_axi using xsim (tb_ascon_aead_axi).
#
# Usage (from project root; the script path can be absolute from anywhere):
#   vivado -mode batch -source scripts/run_axi_regression.tcl
#   vivado -mode batch -source scripts/run_axi_regression.tcl -tclargs -gui
#   vivado -mode batch -source scripts/run_axi_regression.tcl -tclargs -timeout "20 ms"
#
# Args:
#   -gui               open the waveform GUI
#   -timeout <time>    max sim time (default: "10 ms")
#
# Results: regression/axi/{compile,elab,sim}.log
#          regression/axi/summary.txt
#=============================================================================

set test_name "axi"
set top       "tb_ascon_aead_axi"
set pass_str  "ALL AXI TESTS PASSED"

set proj_dir [file normalize [file join [file dirname [info script]] ..]]
set src_dir  [file join $proj_dir ascon_aead.srcs sources_1 new]
set tb_dir   [file join $proj_dir ascon_aead.srcs sim_1 new]
set tv_dir   [file join $proj_dir python_simulation]
set wdir     [file join $proj_dir regression $test_name]

#-----------------------------------------------------------------------------
# Arguments
#-----------------------------------------------------------------------------
set gui     0
set timeout "10 ms"

for {set i 0} {$i < [llength $argv]} {incr i} {
    set a [lindex $argv $i]
    switch -- $a {
        -gui     { set gui 1 }
        -timeout { incr i; set timeout [lindex $argv $i] }
        default {
            puts "ERROR: unknown argument '$a' (valid: -gui, -timeout <time>)"
            exit 2
        }
    }
}

#-----------------------------------------------------------------------------
# Helpers
#-----------------------------------------------------------------------------
proc find_tool {name} {
    set t [auto_execok $name]
    if {$t eq "" && [info exists ::env(XILINX_VIVADO)]} {
        set t [auto_execok [file join $::env(XILINX_VIVADO) bin $name]]
    }
    if {$t eq ""} {
        puts "ERROR: '$name' not found. Run from Vivado or source settings64."
        exit 2
    }
    return $t
}

# Run a tool, all output to log. Returns 1 on success.
proc run_tool {log args} {
    if {[catch {exec {*}$args >& $log}]} {
        return 0
    }
    return 1
}

proc read_file {f} {
    if {![file exists $f]} { return "" }
    set fh [open $f r]
    set txt [read $fh]
    close $fh
    return $txt
}

set xvlog [find_tool xvlog]
set xelab [find_tool xelab]
set xsim  [find_tool xsim]

set rtl_files [lsort [glob -directory $src_dir *.v]]
set tb_files  [file join $tb_dir ${top}.sv]

#-----------------------------------------------------------------------------
# Run
#-----------------------------------------------------------------------------
puts "\n=================================================================="
puts " TEST: $test_name   (top: $top)"
puts "=================================================================="

file delete -force $wdir
file mkdir $wdir
# Testbench opens "python_simulation/<x>_tv.txt" relative to cwd
file mkdir [file join $wdir python_simulation]
foreach f [glob -directory $tv_dir *_tv.txt] {
    file copy -force $f [file join $wdir python_simulation]
}

set old_pwd [pwd]
cd $wdir

set status ""

# Compile
puts "  compile ..."
if {![run_tool compile.log {*}$xvlog -sv {*}$rtl_files {*}$tb_files]} {
    set status "COMPILE_ERROR"
}

# Elaborate
if {$status eq ""} {
    puts "  elaborate ..."
    set dbg [expr {$gui ? "all" : "typical"}]
    if {![run_tool elab.log {*}$xelab $top -debug $dbg -s ${top}_snap]} {
        set status "ELAB_ERROR"
    }
}

# Simulate
if {$status eq ""} {
    puts "  simulate ..."
    set fh [open xsim_run.tcl w]
    if {$gui} {
        puts $fh "log_wave -r /"
        puts $fh "run $timeout"
    } else {
        puts $fh "run $timeout"
        puts $fh "quit"
    }
    close $fh

    if {$gui} {
        run_tool sim.log {*}$xsim ${top}_snap -gui -tclbatch xsim_run.tcl
    } else {
        run_tool sim.log {*}$xsim ${top}_snap -tclbatch xsim_run.tcl
    }

    set log [read_file sim.log]
    if {[string first $pass_str $log] >= 0} {
        set status "PASS"
    } elseif {[regexp {(\d+) \w+ TESTS FAILED} $log -> n]} {
        set status "FAIL ($n errors)"
    } elseif {[string match "*Error opening*" $log]} {
        set status "FAIL (test vectors not found)"
    } else {
        set status "FAIL (timeout / no summary)"
    }

    # Echo failing lines
    foreach line [split $log "\n"] {
        if {[string match "*FAIL*" $line]} { puts "    $line" }
    }
}

cd $old_pwd

#-----------------------------------------------------------------------------
# Summary
#-----------------------------------------------------------------------------
set summary "\n==================================================================\n"
append summary " REGRESSION SUMMARY  ([clock format [clock seconds]])\n"
append summary "==================================================================\n"
append summary [format "  %-10s %-12s %s\n" $test_name $top $status]
if {$status ne "PASS"} {
    append summary "  logs: [file join $wdir *.log]\n"
}
append summary "==================================================================\n"

puts $summary
set fh [open [file join $wdir summary.txt] w]
puts $fh $summary
close $fh

exit [expr {$status eq "PASS" ? 0 : 1}]
