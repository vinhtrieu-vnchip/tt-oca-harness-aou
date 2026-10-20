// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Diagnostic-only proof that selected AXI-R01..R05 stability checks observed
// real stalls and releases. The existing monitor remains the protocol oracle.
// +st_bp=all stalls the controllable S-side channels and M-side AW/W/AR; the
// DUT's M-side BREADY/RREADY have no direct bench control and are measured only.
class aou_axi_stability_test extends aou_stress_test;
  `uvm_component_utils(aou_axi_stability_test)

  bit negative_control;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void configure_test();
    super.configure_test();
    void'($value$plusargs("dg05_negative_control=%d", negative_control));
  endfunction

  protected function void require_channel(aou_axi_monitor mon, aou_axi_ch_e ch,
                                           string port, bit require_stall);
    if (mon.n_handshakes[ch] == 0)
      `uvm_error(get_type_name(), $sformatf("DG05: %s %s had no sampled handshake",
                                            port, aou_axi_ch_name(ch)))
    if (require_stall) begin
      if (mon.n_stall_entries[ch] == 0)
        `uvm_error(get_type_name(), $sformatf("DG05: %s %s had no stall entry", port,
                                              aou_axi_ch_name(ch)))
      if (mon.n_sustained_stall_cycles[ch] == 0)
        `uvm_error(get_type_name(), $sformatf("DG05: %s %s had no sustained stall cycle",
                                              port, aou_axi_ch_name(ch)))
      if (mon.n_stall_releases[ch] == 0)
        `uvm_error(get_type_name(), $sformatf("DG05: %s %s had no stall-to-handshake release",
                                              port, aou_axi_ch_name(ch)))
      if (mon.n_stability_activations[ch] == 0)
        `uvm_error(get_type_name(), $sformatf("DG05: %s %s did not activate AXI-R stability check",
                                              port, ch.name()))
      if (mon.n_stall_aborts[ch] != 0)
        `uvm_error(get_type_name(), $sformatf("DG05: %s %s had %0d stalled VALID abort(s)",
                                              port, aou_axi_ch_name(ch), mon.n_stall_aborts[ch]))
    end
  endfunction

  function void check_phase(uvm_phase phase);
    aou_axi_monitor s;
    aou_axi_monitor m;
    string why;
    super.check_phase(phase);
    if (cfg.n_rp != 1) begin
      `uvm_error(get_type_name(), "DG05 diagnostic requires exactly one RP")
      return;
    end
    s = env.s_mgr[0].mon;
    m = env.m_sub[0].mon;
    if (s == null || m == null) begin
      `uvm_error(get_type_name(), "DG05 AXI monitors unavailable")
      return;
    end
    if (!s.cfg.checks_en || !m.cfg.checks_en)
      `uvm_error(get_type_name(), "DG05 observations cannot qualify with AXI checks disabled")

    // S port: the manager drives AW/W/AR and BREADY/RREADY is controlled.
    foreach (s.n_handshakes[c]) require_channel(s, aou_axi_ch_e'(c), "S", 1'b1);
    // M port: the subordinate controls AW/W/ARREADY. It has no direct control
    // of the DUT's BREADY/RREADY, so those response channels are observed only.
    require_channel(m, AOU_AXI_CH_AW, "M", 1'b1);
    require_channel(m, AOU_AXI_CH_W,  "M", 1'b1);
    require_channel(m, AOU_AXI_CH_B,  "M", 1'b0);
    require_channel(m, AOU_AXI_CH_AR, "M", 1'b1);
    require_channel(m, AOU_AXI_CH_R,  "M", 1'b0);
    if (s.observation_epoch == 0 || m.observation_epoch == 0)
      `uvm_error(get_type_name(), "DG05 observations are not associated with a bus-reset epoch")

    if (env.outstanding(why) != 0)
      `uvm_error(get_type_name(), {"DG05 normal drain incomplete: ", why})
    `uvm_info(get_type_name(), $sformatf(
        {"DG05 summary: S epoch=%0d; M epoch=%0d; link-loss epochs=0 (not stimulated); ",
         "negative_control=%0b; outstanding=%0d"}, s.observation_epoch, m.observation_epoch,
        negative_control, env.outstanding(why)), UVM_LOW)
  endfunction
endclass
