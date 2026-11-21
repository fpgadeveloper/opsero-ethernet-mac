# SPDX-License-Identifier: MIT
#
# gen_gt.tcl - create the Versal transceiver IP (AMD gt_quad_base, free, no
# license) used by omac_gt_versal_gty_quad: one to four channels of one Versal
# GTY (GTYE5) quad as independent 10GBASE-R lanes (one omac_10g each), each
# channel its own protocol of the quad (PROT0 = lane 0, PROT1 = lane 1, ...),
# 64B/66B asynchronous gearbox, 64-bit user data per lane at 156.25 MHz, RPLL
# from a 156.25 MHz reference clock. The Versal counterpart of
# gt/omac_gt_usp_gty/gen_gt.tcl omac_gen_gty_quad.
#
# Versal transceivers are configured only through the gt_quad_base IP (the GT
# primitives cannot be parameterised by hand). The IP is generated as a plain
# IP (.xci) and instantiated in RTL by the wrapper, exactly like the
# gtwizard_ultrascale IP of the UltraScale+ wrappers; no block design is needed.
#
# In a Vivado project or non-project session:
#   source gt/omac_gt_versal_gty/gen_gt.tcl
#   omac_gen_versal_gty_quad <ip_dir> ?channels? ?freerun_mhz? ?module_name? ?gt_type?
# `channels`: the quad channel numbers (0-3) of the lanes in lane order (lane 0
# first), e.g. {0 1} for two lanes on the quad's channels 0 and 1; lane 0 is the
# master (its TX output clock is the shared TX user clock). The quad itself is
# chosen by the design's pin constraints (the serial pins / reference clock
# pin): the IP is not tied to a quad. `gt_type`: GTY (Versal Prime / AI Core,
# GTYE5) or GTYP (Versal Premium / AI Edge Gen 2 / HBM: the IP is generated and
# checked the same way, but its port list differs and omac_gt_versal_gty_quad does
# not instantiate it yet, see the docs).
# Defaults: channels {0 1}, free-running clock 100 MHz, module name
# omac_versal_gty_quad (the name the wrapper instantiates), GTY.
# Batch:
#   vivado -mode batch -source gt/omac_gt_versal_gty/gen_gt.tcl \
#          -tclargs <ip_dir> <part> ?channels? ?freerun_mhz? ?module_name? ?gt_type?
# (batch: channels comma-separated, e.g. 0,1)
# A script that sources this file with its own -tclargs sets
# omac_gen_versal_gty_noauto first, so the batch part does not run.
#
# Settings (checked against the generated IP, Vivado 2025.2, gt_quad_base 1.1):
#   per protocol: preset <GT>-10GBASE-R (line rate 10.3125 Gb/s, reference clock
#   156.25 MHz, TX/RX encoding 64B66B_ASYNC, RX PPM offset 200, TX/RX OUTCLK =
#   PROGDIVCLK); changed: PLL = RPLL (TX and RX; the preset's LCPLL is not
#   used), internal and user data width 64 (one user clock per direction,
#   156.25 MHz, no USRCLK2 on Versal), programmable dividers at 156.25 MHz from
#   the RPLL. Lane l -> protocol PROTl -> channel `channels[l]`; the channels
#   of the quad not listed are left unconnected (powered down).
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

proc omac_gen_versal_gty_quad {ip_dir {channels {0 1}} {freerun_mhz 100} {name omac_versal_gty_quad} {gt_type GTY}} {
    set n [llength $channels]
    if {$n < 1 || $n > 4} { error "omac_gen_versal_gty_quad: one to four channels of one quad expected" }
    foreach c $channels {
        if {$c ni {0 1 2 3}} { error "omac_gen_versal_gty_quad: channel numbers 0-3 expected, got $c" }
    }
    if {[llength [lsort -unique $channels]] != $n} { error "omac_gen_versal_gty_quad: duplicate channel in $channels" }
    if {$gt_type ni {GTY GTYP}} { error "omac_gen_versal_gty_quad: gt_type GTY or GTYP expected, got $gt_type" }
    file mkdir $ip_dir
    create_ip -name gt_quad_base -vendor xilinx.com -library ip -module_name $name -dir $ip_dir -force
    set ip [get_ips $name]
    set_property -dict [list CONFIG.GT_TYPE $gt_type CONFIG.APB3_CLK_FREQUENCY $freerun_mhz] $ip
    # one line-rate setting for every lane: the preset, then the omac changes
    set_property CONFIG.PROT0_PRESET ${gt_type}-10GBASE-R $ip
    set lr [get_property CONFIG.PROT0_LR0_SETTINGS $ip]
    foreach {k v} {TX_PLL_TYPE RPLL RX_PLL_TYPE RPLL TX_INT_DATA_WIDTH 64 RX_INT_DATA_WIDTH 64
                   TX_USER_DATA_WIDTH 64 RX_USER_DATA_WIDTH 64 TXPROGDIV_FREQ_SOURCE RPLL
                   RXPROGDIV_FREQ_SOURCE RPLL TXPROGDIV_FREQ_VAL 156.250 RXPROGDIV_FREQ_VAL 156.250} {
        dict set lr $k $v
    }
    set d [list]
    for {set p 0} {$p < 8} {incr p} {
        if {$p < $n} {
            lappend d CONFIG.PROT${p}_ENABLE true CONFIG.PROT${p}_NO_OF_LANES 1 \
                      CONFIG.PROT${p}_PRESET ${gt_type}-10GBASE-R CONFIG.PROT${p}_LR0_SETTINGS $lr
        } elseif {$p > 0} {
            lappend d CONFIG.PROT${p}_ENABLE false
        }
    }
    for {set c 0} {$c < 4} {incr c} {
        set l [lsearch -exact $channels $c]
        set sel [expr {$l < 0 ? "unconnected" : "PROT$l"}]
        lappend d CONFIG.TX${c}_LANE_SEL $sel CONFIG.RX${c}_LANE_SEL $sel
    }
    set_property -dict $d $ip
    # the settings the wrapper relies on
    if {[get_property CONFIG.QUAD_PACK_SUCCESS $ip] ne "PASS"} {
        error "omac_gen_versal_gty_quad: QUAD_PACK_SUCCESS = [get_property CONFIG.QUAD_PACK_SUCCESS $ip]"
    }
    for {set l 0} {$l < $n} {incr l} {
        set got [get_property CONFIG.PROT${l}_LR0_SETTINGS $ip]
        foreach {k v} {TX_LINE_RATE 10.3125 RX_LINE_RATE 10.3125 TX_REFCLK_FREQUENCY 156.25
                       RX_REFCLK_FREQUENCY 156.25 TX_DATA_ENCODING 64B66B_ASYNC RX_DATA_DECODING 64B66B_ASYNC
                       TX_PLL_TYPE RPLL RX_PLL_TYPE RPLL TX_INT_DATA_WIDTH 64 RX_INT_DATA_WIDTH 64
                       TX_USER_DATA_WIDTH 64 RX_USER_DATA_WIDTH 64 TX_BUFFER_MODE 1
                       TX_OUTCLK_SOURCE TXPROGDIVCLK RX_OUTCLK_SOURCE RXPROGDIVCLK
                       TXPROGDIV_FREQ_VAL 156.250 RXPROGDIV_FREQ_VAL 156.250} {
            if {![dict exists $got $k] || [dict get $got $k] ne $v} {
                set g [expr {[dict exists $got $k] ? [dict get $got $k] : "<none>"}]
                error "omac_gen_versal_gty_quad: PROT$l $k = $g, expected $v"
            }
        }
        set c [lindex $channels $l]
        foreach dir {TX RX} {
            if {[get_property CONFIG.${dir}${c}_LANE_SEL $ip] ne "PROT$l"} {
                error "omac_gen_versal_gty_quad: ${dir}${c}_LANE_SEL = [get_property CONFIG.${dir}${c}_LANE_SEL $ip], expected PROT$l"
            }
        }
    }
    # informational: the IP's own record of the outclk frequencies and the reference clock use
    puts "OMAC_GEN_VERSAL_GTY: [get_property CONFIG.PROT_OUTCLK_VALUES $ip]"
    puts "OMAC_GEN_VERSAL_GTY: [get_property CONFIG.REFCLK_STRING $ip]"
    generate_target {instantiation_template synthesis simulation} $ip
    return $ip
}

# CH_OF_LANE of omac_gt_versal_gty_quad for a channel list in lane order: lane l
# -> quad channel number, packed 2 bits per lane (on Versal the IP always has the
# four channels of the quad, so the map is the channel number itself).
proc omac_versal_ch_of_lane {channels} {
    set v 0
    for {set l 0} {$l < [llength $channels]} {incr l} {
        set v [expr {$v | ([lindex $channels $l] << (2 * $l))}]
    }
    return $v
}

if {![info exists ::omac_gen_versal_gty_noauto] && [info exists argv] && [llength $argv] >= 2} {
    set ip_dir [lindex $argv 0]
    set part   [lindex $argv 1]
    set ch     [expr {[llength $argv] > 2 ? [split [lindex $argv 2] ,] : {0 1}}]
    set fr     [expr {[llength $argv] > 3 ? [lindex $argv 3] : 100}]
    set nm     [expr {[llength $argv] > 4 ? [lindex $argv 4] : "omac_versal_gty_quad"}]
    set gt     [expr {[llength $argv] > 5 ? [lindex $argv 5] : "GTY"}]
    create_project -in_memory -part $part
    omac_gen_versal_gty_quad $ip_dir $ch $fr $nm $gt
    puts "OMAC_GEN_VERSAL_GTY done: $ip_dir/$nm/$nm.xci (CH_OF_LANE [format 0x%02X [omac_versal_ch_of_lane $ch]])"
}
