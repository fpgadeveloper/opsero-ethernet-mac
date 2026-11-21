# SPDX-License-Identifier: MIT
#
# gen_gt.tcl - create the gtwizard_ultrascale IP (free, no license) used by
# omac_gt_usp_gty_quad: one to four UltraScale+ GTY channels of one quad as
# independent 10GBASE-R lanes (one omac_10g each), 64B/66B asynchronous gearbox,
# 64-bit user data per lane at 156.25 MHz. The GTY twin of
# gt/omac_gt_usp_gth/gen_gt.tcl omac_gen_gth_quad: the same settings, clocking
# and optional ports, so omac_gt_usp_gty_quad has the same structure and ports
# as omac_gt_usp_gth_quad.
#
# In a Vivado project or non-project session:
#   source gt/omac_gt_usp_gty/gen_gt.tcl
#   omac_gen_gty_quad <ip_dir> ?channels? ?freerun_mhz? ?module_name? ?refclk?
# `channels`: the board's GT channel sites in lane order (lane 0 first, one to
# four sites of one quad), e.g. {X0Y12 X0Y13}; the first one is the master (its
# TXOUTCLK makes the shared TX user clock). `refclk`: clk0 (default) or clk1 =
# MGTREFCLK0 / MGTREFCLK1 of the master's quad (omac_gt_usp_gty_quad REFCLK_SEL
# must match). Every RX user clock is made per channel in the wrapper
# (LOCATE_RX_USER_CLOCKING EXAMPLE_DESIGN). Defaults: sites X0Y12 X0Y13 (an
# example pair of an xcku5p quad, only so the repository's own jobs run: a
# design always passes its own sites), free-running clock 100 MHz, module name
# omac_gty_quad (the name the wrapper instantiates).
# Batch:
#   vivado -mode batch -source gt/omac_gt_usp_gty/gen_gt.tcl \
#          -tclargs <ip_dir> <part> ?channels? ?freerun_mhz? ?module_name? ?refclk?
# A script that sources this file with its own -tclargs sets omac_gen_gty_noauto
# first, so the batch part does not run.
#
# Settings (checked against the generated IP, Vivado 2025.2, gtwizard_ultrascale 1.7):
#   preset GTY-10GBASE-R: line rate 10.3125 Gb/s, QPLL0, reference clock
#   156.25 MHz, TX/RX encoding 64B66B_ASYNC, internal data width 32, TX/RX
#   OUTCLK = PROGDIVCLK, RX PPM offset 200; changed: user data width 64
#   (USRCLK 312.5 MHz, USRCLK2 156.25 MHz, as on the GTH), user clocking: TX in
#   the core, RX in the wrapper, the channels and their refclk, optional ports
#   for loopback, polarity, TX driver settings, LPM/DFE, status, per-channel
#   RXPMARESET and DRP. The GTY also accepts an internal width of 64
#   (USRCLK = USRCLK2 = 156.25 MHz); 32 is kept so that the GTY and GTH
#   wrappers share one clocking structure.
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

proc omac_gen_gty_quad {ip_dir {channels {X0Y12 X0Y13}} {freerun_mhz 100} {name omac_gty_quad} {refclk clk0}} {
    set n [llength $channels]
    if {$n < 1 || $n > 4} { error "omac_gen_gty_quad: one to four channels of one quad expected" }
    if {$refclk ni {clk0 clk1}} { error "omac_gen_gty_quad: refclk must be clk0 or clk1, got $refclk" }
    set quads {}
    foreach c $channels {
        if {![regexp {^X(\d+)Y(\d+)$} $c -> x y]} { error "omac_gen_gty_quad: bad channel site $c" }
        lappend quads "X${x}Y[expr {$y / 4}]"
    }
    if {[llength [lsort -unique $quads]] != 1} { error "omac_gen_gty_quad: channels $channels are not in one quad" }
    set master [lindex $channels 0]
    # MGTREFCLK0 is the gtwizard's default source of every channel and is named for the
    # master only; MGTREFCLK1 must be named for every channel (one QPLL0, one source)
    set rsrc [expr {$refclk eq "clk0" ? "$master clk0" : [join [lmap c [lsort -dictionary $channels] {list $c $refclk}]]}]
    file mkdir $ip_dir
    create_ip -name gtwizard_ultrascale -vendor xilinx.com -library ip -module_name $name -dir $ip_dir -force
    set ip [get_ips $name]
    set_property CONFIG.PRESET GTY-10GBASE-R $ip
    set_property -dict [list \
        CONFIG.CHANNEL_ENABLE            [lsort -dictionary $channels] \
        CONFIG.TX_MASTER_CHANNEL         $master \
        CONFIG.RX_MASTER_CHANNEL         $master \
        CONFIG.TX_REFCLK_SOURCE          $rsrc \
        CONFIG.RX_REFCLK_SOURCE          $rsrc \
        CONFIG.TX_INT_DATA_WIDTH         32 \
        CONFIG.RX_INT_DATA_WIDTH         32 \
        CONFIG.TX_USER_DATA_WIDTH        64 \
        CONFIG.RX_USER_DATA_WIDTH        64 \
        CONFIG.FREERUN_FREQUENCY         $freerun_mhz \
        CONFIG.LOCATE_TX_USER_CLOCKING   CORE \
        CONFIG.LOCATE_RX_USER_CLOCKING   EXAMPLE_DESIGN \
        CONFIG.ENABLE_OPTIONAL_PORTS     {loopback_in rxpolarity_in txpolarity_in txdiffctrl_in txpostcursor_in txprecursor_in rxlpmen_in gtpowergood_out rxpmaresetdone_out txpmaresetdone_out rxpmareset_in rxresetdone_out rxcdrlock_out qpll0lock_out drpaddr_in drpclk_in drpdi_in drpen_in drpwe_in drpdo_out drprdy_out} \
    ] $ip
    # the settings the wrapper relies on
    foreach {k v} {TX_LINE_RATE 10.3125 RX_LINE_RATE 10.3125 TX_REFCLK_FREQUENCY 156.25 \
                   TX_DATA_ENCODING 64B66B_ASYNC RX_DATA_DECODING 64B66B_ASYNC \
                   TX_INT_DATA_WIDTH 32 RX_INT_DATA_WIDTH 32 TX_USER_DATA_WIDTH 64 RX_USER_DATA_WIDTH 64 \
                   TX_PLL_TYPE QPLL0 RX_PLL_TYPE QPLL0 TX_BUFFER_MODE 1 \
                   LOCATE_TX_USER_CLOCKING CORE LOCATE_RX_USER_CLOCKING EXAMPLE_DESIGN} {
        set got [get_property CONFIG.$k $ip]
        if {$got ne $v} { error "omac_gen_gty_quad: $k = $got, expected $v" }
    }
    if {[lsort -dictionary [get_property CONFIG.CHANNEL_ENABLE $ip]] ne [lsort -dictionary $channels]} {
        error "omac_gen_gty_quad: CHANNEL_ENABLE = [get_property CONFIG.CHANNEL_ENABLE $ip], expected $channels"
    }
    if {[get_property CONFIG.TX_REFCLK_SOURCE $ip] ne $rsrc} {
        error "omac_gen_gty_quad: TX_REFCLK_SOURCE = [get_property CONFIG.TX_REFCLK_SOURCE $ip], expected $rsrc"
    }
    generate_target {instantiation_template synthesis simulation} $ip
    return $ip
}

# CH_OF_LANE of omac_gt_usp_gth_quad / omac_gt_usp_gty_quad for a site list in lane
# order: lane l -> index of its site in ascending site order (the gtwizard's channel
# numbering), packed 2 bits per lane.
proc omac_ch_of_lane {channels} {
    set sorted [lsort -dictionary $channels]
    set v 0
    for {set l 0} {$l < [llength $channels]} {incr l} {
        set v [expr {$v | ([lsearch -exact $sorted [lindex $channels $l]] << (2 * $l))}]
    }
    return $v
}

if {![info exists ::omac_gen_gty_noauto] && [info exists argv] && [llength $argv] >= 2} {
    set ip_dir [lindex $argv 0]
    set part   [lindex $argv 1]
    set ch     [expr {[llength $argv] > 2 ? [lindex $argv 2] : {X0Y12 X0Y13}}]
    set fr     [expr {[llength $argv] > 3 ? [lindex $argv 3] : 100}]
    set nm     [expr {[llength $argv] > 4 ? [lindex $argv 4] : "omac_gty_quad"}]
    set rc     [expr {[llength $argv] > 5 ? [lindex $argv 5] : "clk0"}]
    create_project -in_memory -part $part
    omac_gen_gty_quad $ip_dir $ch $fr $nm $rc
    puts "OMAC_GEN_GTY done: $ip_dir/$nm/$nm.xci (CH_OF_LANE [format 0x%02X [omac_ch_of_lane $ch]])"
}
