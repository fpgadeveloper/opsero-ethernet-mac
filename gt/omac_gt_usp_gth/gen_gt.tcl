# SPDX-License-Identifier: MIT
#
# gen_gt.tcl - create the gtwizard_ultrascale IP (free, no license) used by
# omac_gt_usp_gth (one GTH channel, omac_10g), omac_gt_usp_gth_x4 (four GTH
# channels of one quad, omac_40g) and omac_gt_usp_gth_quad (four GTH channels of
# one quad as four independent omac_10g lanes): 10GBASE-R lanes, 64B/66B
# asynchronous gearbox, 64-bit user data per lane at 156.25 MHz.
#
# In a Vivado project or non-project session:
#   source gt/omac_gt_usp_gth/gen_gt.tcl
#   omac_gen_gth <ip_dir> ?channels? ?freerun_mhz? ?module_name?
#   omac_gen_gth_x4 <ip_dir> ?channels? ?freerun_mhz? ?module_name?
#   omac_gen_gth_quad <ip_dir> ?channels? ?freerun_mhz? ?module_name? ?refclk?
# `channels` is the board's GT channel site (e.g. X0Y14) or a list of four sites of
# one quad in lane order (lane 0 first); the first one is the master (its TXOUTCLK makes the shared TX user clock) and gives the
# reference clock (MGTREFCLK0 of the quad). With more than one channel the RX
# user clocks are made per channel in the wrapper (LOCATE_RX_USER_CLOCKING
# EXAMPLE_DESIGN): every lane keeps its own recovered clock, as omac_40g expects.
# Batch:
#   vivado -mode batch -source gt/omac_gt_usp_gth/gen_gt.tcl \
#          -tclargs <ip_dir> <part> ?channels? ?freerun_mhz? ?module_name?
# A script that sources this file with its own -tclargs sets omac_gen_gth_noauto
# first, so the batch part does not run.
# The channel sites and the reference clock pin come from the board's / FMC's
# pinout: a design always passes its own sites. The fallback sites (X0Y14, and
# X0Y14 X0Y13 X0Y15 X0Y12 for omac_gen_gth_x4: example sites of one xczu7ev
# quad) exist only so the repository's own synthesis jobs run. Other defaults:
# free-running clock 100 MHz, module name omac_gth_10g (omac_gen_gth_x4:
# omac_gth_40g, omac_gen_gth_quad: omac_gth_quad); the wrappers instantiate the
# module by that name. omac_gen_gth_quad = omac_gen_gth_x4 plus the per-channel
# ports rxpmareset_in, rxresetdone_out, rxcdrlock_out and qpll0lock_out (the
# per-lane RX resets of omac_gt_usp_gth_quad) and the DRP ports, on one to four
# channels of one quad (omac_gt_usp_gth_quad NLANES = the number of sites given;
# the other channels of the quad are not instantiated). `refclk` (clk0 default,
# or clk1) selects MGTREFCLK0 or MGTREFCLK1 of the master's quad (the IP's port is
# gtrefclk00_in either way: the wrapper does not change).
#
# Settings (checked against the generated IP, Vivado 2025.2, gtwizard_ultrascale 1.7):
#   preset GTH-10GBASE-R: line rate 10.3125 Gb/s, QPLL0 (FBDIV 66, REFCLK_DIV 1),
#   reference clock 156.25 MHz, TX/RX encoding 64B66B_ASYNC, internal data width
#   32 (the only value the GTH allows here), TX/RX OUTCLK = PROGDIVCLK 312.5 MHz,
#   RX PPM offset 200; changed: user data width 64 (USRCLK 312.5 MHz, USRCLK2
#   156.25 MHz), user clocking helpers in the core, the channel and its refclk,
#   optional ports for loopback, polarity, TX driver settings, LPM/DFE, status.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

proc omac_gen_gth {ip_dir {channel X0Y14} {freerun_mhz 100} {name omac_gth_10g} {extra_ports {}} {refclk clk0}} {
    set master [lindex $channel 0]
    if {$refclk ni {clk0 clk1}} { error "omac_gen_gth: refclk must be clk0 or clk1, got $refclk" }
    # MGTREFCLK0 is the gtwizard's default source of every channel and is named for the
    # master only; MGTREFCLK1 must be named for every channel (one QPLL0, one source)
    set rsrc [expr {$refclk eq "clk0" ? "$master clk0" : [join [lmap c [lsort -dictionary $channel] {list $c $refclk}]]}]
    # per-channel RX user clocks in the wrapper for several channels and for the _quad IPs
    set rxuc [expr {([llength $channel] > 1 || [llength $extra_ports]) ? "EXAMPLE_DESIGN" : "CORE"}]
    file mkdir $ip_dir
    create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name $name -dir $ip_dir -force
    set ip [get_ips $name]
    set_property CONFIG.PRESET GTH-10GBASE-R $ip
    set_property -dict [list \
        CONFIG.CHANNEL_ENABLE            [lsort $channel] \
        CONFIG.TX_MASTER_CHANNEL         $master \
        CONFIG.RX_MASTER_CHANNEL         $master \
        CONFIG.TX_REFCLK_SOURCE          $rsrc \
        CONFIG.RX_REFCLK_SOURCE          $rsrc \
        CONFIG.TX_USER_DATA_WIDTH        64 \
        CONFIG.RX_USER_DATA_WIDTH        64 \
        CONFIG.FREERUN_FREQUENCY         $freerun_mhz \
        CONFIG.LOCATE_TX_USER_CLOCKING   CORE \
        CONFIG.LOCATE_RX_USER_CLOCKING   $rxuc \
        CONFIG.ENABLE_OPTIONAL_PORTS     [concat {loopback_in rxpolarity_in txpolarity_in txdiffctrl_in txpostcursor_in txprecursor_in rxlpmen_in gtpowergood_out rxpmaresetdone_out txpmaresetdone_out} $extra_ports] \
    ] $ip
    # the settings the wrapper relies on
    foreach {k v} {TX_LINE_RATE 10.3125 RX_LINE_RATE 10.3125 TX_REFCLK_FREQUENCY 156.25 \
                   TX_DATA_ENCODING 64B66B_ASYNC RX_DATA_DECODING 64B66B_ASYNC \
                   TX_INT_DATA_WIDTH 32 RX_INT_DATA_WIDTH 32 TX_USER_DATA_WIDTH 64 RX_USER_DATA_WIDTH 64 \
                   TX_PLL_TYPE QPLL0 RX_PLL_TYPE QPLL0} {
        set got [get_property CONFIG.$k $ip]
        if {$got ne $v} { error "omac_gen_gth: $k = $got, expected $v" }
    }
    if {[lsort [get_property CONFIG.CHANNEL_ENABLE $ip]] ne [lsort $channel]} {
        error "omac_gen_gth: CHANNEL_ENABLE = [get_property CONFIG.CHANNEL_ENABLE $ip], expected $channel"
    }
    generate_target {instantiation_template synthesis simulation} $ip
    return $ip
}

proc omac_gen_gth_x4 {ip_dir {channels {X0Y14 X0Y13 X0Y15 X0Y12}} {freerun_mhz 100} {name omac_gth_40g}} {
    if {[llength $channels] != 4} { error "omac_gen_gth_x4: four channels expected" }
    return [omac_gen_gth $ip_dir $channels $freerun_mhz $name]
}

proc omac_gen_gth_quad {ip_dir {channels {X0Y14 X0Y13 X0Y15 X0Y12}} {freerun_mhz 100} {name omac_gth_quad} {refclk clk0}} {
    set n [llength $channels]
    if {$n < 1 || $n > 4} { error "omac_gen_gth_quad: one to four channels of one quad expected" }
    set quads {}
    foreach c $channels {
        if {![regexp {^X(\d+)Y(\d+)$} $c -> x y]} { error "omac_gen_gth_quad: bad channel site $c" }
        lappend quads "X${x}Y[expr {$y / 4}]"
    }
    if {[llength [lsort -unique $quads]] != 1} { error "omac_gen_gth_quad: channels $channels are not in one quad" }
    return [omac_gen_gth $ip_dir $channels $freerun_mhz $name \
        {rxpmareset_in rxresetdone_out rxcdrlock_out qpll0lock_out drpaddr_in drpclk_in drpdi_in drpen_in drpwe_in drpdo_out drprdy_out} $refclk]
}

if {![info exists ::omac_gen_gth_noauto] && [info exists argv] && [llength $argv] >= 2} {
    set ip_dir [lindex $argv 0]
    set part   [lindex $argv 1]
    set ch     [expr {[llength $argv] > 2 ? [lindex $argv 2] : "X0Y14"}]
    set fr     [expr {[llength $argv] > 3 ? [lindex $argv 3] : 100}]
    set nm     [expr {[llength $argv] > 4 ? [lindex $argv 4] : "omac_gth_10g"}]
    create_project -in_memory -part $part
    omac_gen_gth $ip_dir $ch $fr $nm
    puts "OMAC_GEN_GTH done: $ip_dir/$nm/$nm.xci"
}
