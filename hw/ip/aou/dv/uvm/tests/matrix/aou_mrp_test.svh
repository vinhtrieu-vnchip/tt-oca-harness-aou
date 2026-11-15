// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Multi-RP traffic (plan 2.12): aou_mrp_vseq's scenarios with aou_mrp_chk's
// per-RP accounting (T1-M01, the per-RP statistics of 12.19), arbitration
// (T1-M02) and independence (T1-M03) checks. Both directions, every size up
// to each side's width, 1-16 beats. +mrp_scn=crd_rr opens round-robin credit
// windows for the env's aou_t1_crd_rr_chk (T1-C03).
class aou_mrp_test extends aou_dp_base_test;
  `uvm_component_utils(aou_mrp_test)

  aou_mrp_chk chk;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    vseq_type = "aou_mrp_vseq";
  endfunction

  // Port QoS on a merge group (FEAT-R36): +mrp_arb_mode programs ARB_MODE and
  // +mrp_priors one 2-bit RPn_PRIOR per port, so the merged ports can be given
  // different tiers. +mrp_timer_threshold/resolution program PRIOR_TIMER; with
  // the maximum threshold no promotion is possible inside a scenario, which is
  // what makes the strict-tier order assertable.
  function void configure();
    int unsigned am;
    int unsigned pv;
    int unsigned th;
    int unsigned rs;
    bit has_am;
    bit has_pv;
    bit has_th;
    bit has_rs;
    has_am = $value$plusargs("mrp_arb_mode=%d", am);
    has_pv = $value$plusargs("mrp_priors=%h", pv);
    has_th = $value$plusargs("mrp_timer_threshold=%d", th);
    has_rs = $value$plusargs("mrp_timer_resolution=%d", rs);
    if (has_am || has_pv || has_th || has_rs) begin
      if (k.feat == null) k.feat = aou_t1_feature_cfg::type_id::create("feat");
      if (has_am) k.feat.arb_mode = int'(am);
      if (has_pv)
        foreach (k.feat.rp_prior[r]) k.feat.rp_prior[r] = int'(pv[2 * r +: 2]);
      if (has_th) k.feat.timer_threshold = int'(th);
      if (has_rs) k.feat.timer_resolution = int'(rs);
    end
    super.configure();
  endfunction

  // crd_rr runs remote-die requests only.
  function void configure_test();
    string scn;
    if ($value$plusargs("mrp_scn=%s", scn) && scn == "crd_rr") min_l2r = 0;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    chk = aou_mrp_chk::type_id::create("chk", this);
    uvm_config_db#(aou_mrp_chk)::set(null, "*", "mrp_chk", chk);
  endfunction

  function void connect_phase(uvm_phase phase);
    int unsigned fixed_map;
    int unsigned require_merge;
    super.connect_phase(phase);
    foreach (env.s_mgr[r]) env.s_mgr[r].ap.connect(chk.loc_fifo.analysis_export);
    env.rmgr.ap.connect(chk.rem_fifo.analysis_export);
    env.l3.ap_rx_msg.connect(chk.dut_fifo.analysis_export);
    chk.rp_map = env.rp_map;
    if ($value$plusargs("rp_map=%h", fixed_map) &&
        $value$plusargs("rp_map_require_merge=%d", require_merge) && require_merge != 0) begin
      if (fixed_map != 32'h181)
        `uvm_fatal(get_type_name(), "+rp_map_require_merge is defined for +rp_map=181")
      env.rp_map.require_merge_observation = 1'b1;
    end
  endfunction
endclass
