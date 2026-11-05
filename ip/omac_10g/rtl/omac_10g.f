# omac_10g source list (paths relative to the repository root), in compile order.
# Top: omac_10g (SystemVerilog) or omac_10g_bd (Verilog wrapper for IP integrator module reference).
common/omac_pkg.sv
common/omac_crc32.sv
common/omac_scrambler.sv
common/omac_descrambler.sv
common/omac_sync_bit.sv
common/omac_sync_reset.sv
common/omac_cdc_event.sv
common/omac_async_fifo.sv
common/omac_block_lock.sv
common/omac_ber_mon.sv
common/omac_rs_fault.sv
common/omac_pause.sv
common/omac_pause_frame.sv
ip/omac_10g/rtl/omac_10g_pcs_tx.sv
ip/omac_10g/rtl/omac_10g_pcs_rx.sv
ip/omac_10g/rtl/omac_10g_mac_tx.sv
ip/omac_10g/rtl/omac_10g_mac_rx.sv
ip/omac_10g/rtl/omac_10g.sv
