# SPDX-License-Identifier: MIT
#
# run_gt_sim.tcl - transceiver-level simulation of the per-lane quad wrappers with the
# vendor's GT simulation models (xsim): sim/gt/tb_gt_loop.sv, two omac_10g on two lanes
# of one quad, serial pins crossed like a cable; link-up and frames both ways.
#
#   vivado -mode batch -nojournal -nolog -source sim/gt/run_gt_sim.tcl \
#          -tclargs <gty|gth> <out_dir> ?nframes?
# gty: xcku5p-ffvb676-2-e, sites X0Y12 X0Y13; gth: xczu7ev-ffvc1156-2-e, sites X0Y14 X0Y13
# (lane 0 = X0Y14 = gtwizard channel 1: a non-identity lane map). Prints one line
# "GT_SIM <fam> PASS|FAIL ..." and the TB_ lines; sim/gt/test_gt.py wraps it for the
# regression (sim/run_tests.py --gt). Slow: the GT models simulate every line bit.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

set fam     [lindex $argv 0]
set out_dir [file normalize [lindex $argv 1]]
set nframes [expr {[llength $argv] > 2 ? [lindex $argv 2] : 12}]
set here [file dirname [file normalize [info script]]]
set root [file normalize [file join $here .. ..]]

if {$fam eq "gty"} {
    set part xcku5p-ffvb676-2-e
    set sites {X0Y12 X0Y13}
} elseif {$fam eq "gth"} {
    set part xczu7ev-ffvc1156-2-e
    set sites {X0Y14 X0Y13}
} else {
    error "run_gt_sim.tcl: family gty or gth expected"
}
file delete -force $out_dir
file mkdir $out_dir
create_project gt_sim_$fam $out_dir -part $part -force
set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]

set ::omac_gen_gth_noauto 1
set ::omac_gen_gty_noauto 1
source [file join $root gt omac_gt_usp_gth gen_gt.tcl]
source [file join $root gt omac_gt_usp_gty gen_gt.tcl]
set ipd [file join $out_dir ip]
if {$fam eq "gty"} {
    set ip [omac_gen_gty_quad $ipd $sites 100 omac_gty_quad clk0]
} else {
    set ip [omac_gen_gth_quad $ipd $sites 100 omac_gth_quad clk0]
}
generate_target all [get_files -of_objects [get_filesets sources_1] [get_property IP_FILE $ip]]

set srcs {}
set fh [open [file join $root ip omac_10g rtl omac_10g.f] r]
foreach l [split [read $fh] "\n"] {
    set l [string trim $l]
    if {$l eq "" || [string index $l 0] eq "#"} { continue }
    lappend srcs [file join $root $l]
}
close $fh
lappend srcs [file join $root gt omac_gt_usp_$fam omac_gt_usp_${fam}_quad.sv]
add_files -fileset sources_1 -norecurse $srcs
set_property file_type SystemVerilog [get_files $srcs]
add_files -fileset sim_1 -norecurse [file join $here tb_gt_loop.sv]
set_property file_type SystemVerilog [get_files [file join $here tb_gt_loop.sv]]
set_property top tb_gt_loop [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set chl [omac_ch_of_lane $sites]
set_property generic "GTY=[expr {$fam eq "gty"}] CH_OF_LANE=$chl NFRAMES=$nframes" [get_filesets sim_1]
set_property -name {xsim.simulate.runtime} -value {-all} -objects [get_filesets sim_1]
set_property -name {xsim.elaborate.debug_level} -value {off} -objects [get_filesets sim_1]
update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set t0 [clock seconds]
set err ""
if {[catch {launch_simulation -simset sim_1 -mode behavioral} err]} {
    puts "GT_SIM $fam ERROR launch_simulation: $err"
}
set mins [format %.1f [expr {([clock seconds] - $t0) / 60.0}]]
set log [glob -nocomplain [file join $out_dir gt_sim_$fam.sim sim_1 behav xsim simulate.log]]
set pass 0
set lines {}
if {[llength $log]} {
    set fh [open [lindex $log 0] r]
    foreach l [split [read $fh] "\n"] {
        if {[string match "TB_*" $l]} { lappend lines $l }
        if {[string match "TB_RESULT pass=1*" $l]} { set pass 1 }
    }
    close $fh
}
foreach l $lines { puts $l }
puts "GT_SIM $fam [expr {$pass ? "PASS" : "FAIL"}] part=$part sites=$sites CH_OF_LANE=[format 0x%02X $chl] wall_minutes=$mins"
