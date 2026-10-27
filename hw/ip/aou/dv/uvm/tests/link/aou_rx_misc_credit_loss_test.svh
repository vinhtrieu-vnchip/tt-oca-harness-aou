// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Focused detector for multiple Misc starts in one 12-granule decode chunk.
// The current DUT is expected to report T1-C43 until its RX candidate capacity
// is corrected by the RTL owner. This scenario is not in PASS-only groups.
class aou_rx_misc_credit_loss_test extends aou_base_test;
  `uvm_component_utils(aou_rx_misc_credit_loss_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
    vseq_type = "aou_rx_misc_credit_loss_vseq";
    min_l2r = 0;
    min_r2l = 0;
  endfunction

  function void configure();
    if (cfg.v0p8)
      `uvm_fatal(get_type_name(), "this directed packing regression requires the v0.7.1 contract")
    cfg.l1_cancel_pct = 0;
    cfg.l1_bubble_pct = 0;
    cfg.l1_gap_pct = 0;
    cfg.l3_cfg.pol.cred_method = AOU_CRM_GRANT;
    cfg.l3_cfg.pol.v07_activation_with_credits = 1'b1;
    cfg.l3_cfg.pol.misc_per_half_max = 2;
    cfg.l3_cfg.rx_depth = '{64, 64, 128, 192, 8};
    cfg.rx_misc_dense_cov_en = 1'b1;
    cfg.rx_misc_ordered_grant_chk_en = 1'b1;
    cfg.rx_misc_rdata_counter_chk_en = 1'b1;
  endfunction
endclass
