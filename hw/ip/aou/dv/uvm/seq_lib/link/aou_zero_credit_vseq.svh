// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Zero credit for one class (port of aou_zero_{wreq,rreq,wdata,rdata,wresp}
// _credit_test). The remote die advertises no credit of that class at
// activation; traffic that needs it must stay queued in the DUT, never sent
// without credit (AOU-R16, checked by the model) and never dropped. After
// +hold cycles the remote die grants +grant credits and everything completes
// with correct data.
// Knobs: +credit=wreq|rreq|wdata|rdata|wresp (random) +hold=<cycles>
// +grant=<credits> +T1_TXN=<transactions>.
// +starve_rp=<r> (plan 3.15/12.14): only RP r has no credit of the class;
// traffic runs on every RP, and the others' may complete while RP r's stays
// queued.
// +limit=<k> with +credit=wreq|rreq (plan 8.3/8.6): every RP gets credit for
// exactly k requests and the remote die returns none of it until released,
// with more than k requests queued per RP.
// aou_t1_crd_flow_chk judges both in every test: an RP with credit and queued
// work keeps sending while another RP has none (T1-C01), the DUT uses all the
// credit it holds (T1-C02), never more (AOU-R16, the L3 model).
// +deact=1 (plan 2.5; MAS 7.3.3): with the traffic still queued for want of
// credit, software sets DEACTIVATE_START (CREDIT_MANAGE from +credit_manage,
// default 0), and the grant comes +deact_hold cycles later. Messages waiting
// for credit remain to be transmitted (MAS 7.1), so they must still go out
// before the DUT's DeactivateReq (AOU-R34, AOU-R33 in the L3 model; T1-L47 in
// aou_t1_rx_fifo_chk for responses to the remote die) and every transaction
// completes (scoreboard).
class aou_zero_credit_vseq extends aou_link_base_vseq;
  `uvm_object_utils(aou_zero_credit_vseq)

  // WriteReq and ReadReq are 3 granules (Tables 2 and 4).
  static const int unsigned REQ_GRANULES = 3;

  protected bit others_done;
  protected bit deact_done;

  function new(string name = "aou_zero_credit_vseq");
    super.new(name);
  endfunction

  task body();
    string names[5] = '{"wreq", "rreq", "wdata", "rdata", "wresp"};
    aou_cred_class_e c = class_of(arg_str("credit", names[$urandom_range(4)]));
    int starve = arg_int("starve_rp", -1);
    int unsigned limit = arg_int("limit", 0);
    if (starve >= 0) begin
      starve_one(c, starve);
      return;
    end
    if (limit != 0) begin
      credit_limit(c, limit);
      return;
    end
    zero_all(c);
  endtask

  // DUT requests and write data need traffic from the local side; its
  // read data and write responses answer requests from the remote side.
  function aou_t1_dir_e dir_for(aou_cred_class_e c);
    return (c inside {AOU_CC_RDATA, AOU_CC_WRESP}) ? AOU_T1_R2L : AOU_T1_L2R;
  endfunction

  function aou_t1_traffic_cfg profile_for(aou_cred_class_e c);
    aou_t1_traffic_cfg p = aou_t1_traffic_cfg::named("short");
    p.wr_pct = (c inside {AOU_CC_RREQ, AOU_CC_RDATA}) ? 0 : 100;
    return p;
  endfunction

  function int unsigned default_grant(aou_cred_class_e c);
    // Enough for the largest message of the class at 512 bits (Tables 2-13).
    return (c inside {AOU_CC_WRESP, AOU_CC_WREQ, AOU_CC_RREQ}) ? 8 : 64;
  endfunction

  task grant_rp(aou_cred_class_e c, int unsigned r, int unsigned n);
    aou_l3_overgrant_seq g = aou_l3_overgrant_seq::type_id::create("g");
    g.cls = c;
    g.n = n;
    g.rp = 2'(r);
    g.start(p_sequencer.l3_sqr);
  endtask

  task starve_one(aou_cred_class_e c, int unsigned sr);
    int unsigned hold = arg_int("hold", 2000);
    int unsigned grant = arg_int("grant", default_grant(c));
    int unsigned wait_max = arg_int("others_max", 50000);
    aou_t1_dir_e dir = dir_for(c);
    aou_t1_traffic_cfg ps = profile_for(c);
    aou_t1_traffic_cfg po = profile_for(c);
    int unsigned n = 0;
    if (cfg.n_rp < 2) `uvm_fatal(get_type_name(), "+starve_rp needs a build with several RPs")
    if (sr >= cfg.n_rp)
      `uvm_fatal(get_type_name(), $sformatf("+starve_rp=%0d, build has %0d RPs", sr, cfg.n_rp))
    ps.rp_mask = 4'(1 << sr);
    po.rp_mask = 4'((1 << cfg.n_rp) - 1) & ~ps.rp_mask;
    `uvm_info(get_type_name(), $sformatf("RP%0d has no %s credit, %s traffic on every RP",
                                         sr, aou_cc_name(c), dir.name()), UVM_LOW)
    link_up();
    cfg.l3_cfg.rx_starve[sr][c] = 1'b1;
    env.l3.model.crd.reset_link();
    sw_activate();
    others_done = 1'b0;
    traffic_nb(dir, num_txns, ps);
    fork
      begin
        traffic(dir, num_txns, po);
        others_done = 1'b1;
      end
    join_none
    while (!others_done && n < wait_max) begin
      wait_cycles(1);
      n++;
    end
    wait_cycles(hold);
    if (!others_done)
      `uvm_info(get_type_name(), $sformatf("RPs %4b did not complete in %0d cycles", po.rp_mask,
                                           wait_max), UVM_LOW)
    if (n_traffic == 0)
      `uvm_error(get_type_name(), $sformatf("T1-L11: RP%0d traffic completed with no %s credit",
                                            sr, aou_cc_name(c)))
    if (env.l3.model.crd.rx_outstanding[sr][c] != 0)
      `uvm_error(get_type_name(), $sformatf(
          "T1-L12: %0d %s credits outstanding on RP%0d, none granted",
          env.l3.model.crd.rx_outstanding[sr][c], aou_cc_name(c), sr))
    cfg.l3_cfg.rx_starve[sr][c] = 1'b0;
    grant_rp(c, sr, grant);
    wait_traffic();
    wait (others_done);
    drain();
    sw_deactivate();
  endtask

  task credit_limit(aou_cred_class_e c, int unsigned k);
    int unsigned hold = arg_int("hold", 3000);
    int unsigned admit_timeout = arg_int("admit_timeout", 50000);
    aou_t1_traffic_cfg p = profile_for(c);
    aou_cred_ret_e ret = cfg.l3_cfg.ret_policy[c];
    bit same_flit = 1'(arg_int("same_flit", 0));
    int unsigned grant_granules = k * REQ_GRANULES;
    int unsigned usable_granules;
    int unsigned expected_starts[AOU_RP_MAX];
    bit oversupplied;
    int unsigned starts_before[AOU_RP_MAX];
    int unsigned initial_granules[AOU_RP_MAX];
    int unsigned same_flit_before;
    int unsigned n = num_txns;
    if (!(c inside {AOU_CC_WREQ, AOU_CC_RREQ}))
      `uvm_fatal(get_type_name(), "+limit needs +credit=wreq or +credit=rreq")
    if (k == 0 || k > (32'hffff_ffff / REQ_GRANULES))
      `uvm_fatal(get_type_name(), "+limit must be nonzero and fit the granule counter")
    for (int unsigned r = 0; r < cfg.n_rp; r++) begin
      int unsigned wire_rp = env.crd_chk.wire_of(r);
      if (wire_rp >= cfg.l3_cfg.rp_count)
        `uvm_fatal(get_type_name(), $sformatf(
            "RP%0d maps to unavailable wire RP%0d", r, wire_rp))
      for (int unsigned s = r + 1; s < cfg.n_rp; s++)
        if (wire_rp == env.crd_chk.wire_of(s))
          `uvm_fatal(get_type_name(), $sformatf(
              "finite credit needs unique DEST_RP: RP%0d and RP%0d map to RP%0d",
              r, s, wire_rp))
    end
    if (same_flit) begin
      if (c != AOU_CC_WREQ || k < 2)
        `uvm_fatal(get_type_name(), "+same_flit requires +credit=wreq and +limit>=2")
      // Leave two WREQ granules after the largest CrdtGrant field (64) and
      // smallest legal MsgCredit field (4): 68 total, 22 whole requests.
      grant_granules = k * REQ_GRANULES - 1;
    end
    same_flit_before = env.exact_chk.same_flit[c];
    // Every RP must queue more requests than its credit covers.
    if (n < k + 4) n = k + 4;
    // num_slots is the count of pages in the bounded address window, not the
    // transaction count. Keep the profile's valid page pool for large limits.
    if (n < p.num_slots) p.num_slots = n;
    p.max_len = 0;
    for (int unsigned r=0;r<cfg.n_rp;r++) begin
      int unsigned cap=env.exact_chk.credit_max[env.crd_chk.wire_of(r)][c];
      usable_granules=(grant_granules<cap)?grant_granules:cap;
      expected_starts[r]=usable_granules/REQ_GRANULES;
      if (grant_granules>cap) oversupplied=1'b1;
    end
    `uvm_info(get_type_name(), $sformatf("%s credit for %0d requests per RP, %0d queued per RP",
                                         aou_cc_name(c), k, n), UVM_LOW)
    link_up();
    if (oversupplied) begin
      // Complete mandatory activation/bootstrap exchange first. Then withhold
      // returns and inject only the additional over-grant for the test.
      sw_activate();
      cfg.l3_cfg.ret_policy[c] = AOU_RET_WITHHELD;
      foreach (starts_before[r]) begin
        starts_before[r] = env.crd_chk.dut_msg_starts[r][c];
        initial_granules[r] = env.l3.model.crd.rx_outstanding[env.crd_chk.wire_of(r)][c];
      end
      for (int unsigned r = 0; r < cfg.n_rp; r++) begin
        int unsigned wire_rp = env.crd_chk.wire_of(r);
        int unsigned additional = grant_granules > initial_granules[r] ?
                                  grant_granules - initial_granules[r] : 0;
        grant_rp(c, wire_rp, additional);
      end
    end else begin
      // Establish the finite budget before activation, from a clean ledger.
      cfg.l3_cfg.rx_depth[c] = grant_granules;
      cfg.l3_cfg.ret_policy[c] = AOU_RET_WITHHELD;
      env.l3.model.crd.reset_link();
      sw_activate();
      foreach (starts_before[r]) starts_before[r] = env.crd_chk.dut_msg_starts[r][c];
    end
    // Credit-only returns must reach the DUT before demand is presented.
    begin
      bit pending;
      for (int unsigned t = 0; t < 4000; t++) begin
        pending = 1'b0;
        for (int unsigned r = 0; r < cfg.n_rp; r++)
          if (env.l3.model.crd.rx_pending[env.crd_chk.wire_of(r)][c] != 0) pending = 1'b1;
        if (!pending) break;
        wait_cycles(1);
      end
      pending = 1'b0;
      for (int unsigned r = 0; r < cfg.n_rp; r++)
        if (env.l3.model.crd.rx_pending[env.crd_chk.wire_of(r)][c] != 0) pending = 1'b1;
      if (pending) begin
        aou_rule_log::fire("T1-C43", get_type_name());
        `uvm_error(get_type_name(), $sformatf("T1-C43: %s grant setup did not drain",
                                              aou_cc_name(c)))
      end
    end
    wait_cycles(256);
    if (same_flit && env.exact_chk.same_flit[c] == same_flit_before) begin
      `uvm_info(get_type_name(),
                "C1C coverage shortfall: WREQ MsgCredit/CrdtGrant same-flit event not observed",
                UVM_LOW)
    end
    if (arg_int("split_grant",0)!=0) begin
      aou_msg_crdtgrant g=aou_msg_crdtgrant::type_id::create("split_grant");
      int old_start=cfg.l3_cfg.pol.start_granule;
      int unsigned before_split=env.exact_chk.split_grants;
      // G11 spans wire bytes 57..70, crossing a 64-byte RX chunk. Build a
      // legal grant through the existing credit manager and message packer.
      for(int unsigned r=0;r<cfg.n_rp;r++)
        env.l3.model.crd.inject_overgrant(env.crd_chk.wire_of(r),c,4);
      if(!env.l3.model.crd.take_grant(g))
        `uvm_fatal(get_type_name(),"split-grant stimulus could not encode credit")
      cfg.l3_cfg.pol.start_granule=11;
      env.l3.send(g);
      for(int unsigned t=0;t<1000;t++) begin
        if(env.exact_chk.split_grants>before_split) break;
        wait_cycles(1);
      end
      cfg.l3_cfg.pol.start_granule=old_start;
      grant_granules+=4;
      for(int unsigned r=0;r<cfg.n_rp;r++) begin
        int unsigned cap=env.exact_chk.credit_max[env.crd_chk.wire_of(r)][c];
        expected_starts[r]=((grant_granules<cap)?grant_granules:cap)/REQ_GRANULES;
      end
      if(env.exact_chk.split_grants==before_split)
        `uvm_info(get_type_name(),"C1C coverage shortfall: no split CrdtGrant observed",UVM_LOW)
    end
    traffic_nb(AOU_T1_L2R, n, p);
    begin
      bit reached;
      for (int unsigned t = 0; t < admit_timeout; t++) begin
        bit all_reached = 1'b1;
        for (int unsigned r = 0; r < cfg.n_rp; r++) begin
          int unsigned seen = env.crd_chk.dut_msg_starts[r][c] - starts_before[r];
          if (seen < expected_starts[r]) all_reached = 1'b0;
        end
        if (all_reached) begin
          reached = 1'b1;
          break;
        end
        wait_cycles(1);
      end
      if (!reached) begin
        aou_rule_log::fire("T1-C43", get_type_name());
        `uvm_error(get_type_name(), $sformatf(
            "T1-C43: expected admitted-message boundary not reached within %0d cycles",
            admit_timeout))
      end
    end
    wait_cycles(hold);
    begin
      bit exact_on_every_rp = 1'b1;
      for (int unsigned r = 0; r < cfg.n_rp; r++) begin
        int unsigned wire_rp = env.crd_chk.wire_of(r);
        int unsigned left = env.l3.model.crd.rx_outstanding[wire_rp][c];
        int unsigned seen = env.crd_chk.dut_msg_starts[r][c] - starts_before[r];
        `uvm_info(get_type_name(), $sformatf(
            "RP%0d: %0d of %0d %s messages started on credit, %0d credits left",
            r, seen, expected_starts[r], aou_cc_name(c), left), UVM_LOW)
        if (!env.crd_chk.check_exact_budget_count(
                r, c, seen, expected_starts[r], "before credit release")) begin
          exact_on_every_rp = 1'b0;
        end
      end
      if (exact_on_every_rp) env.crd_chk.sample_exact_finite_budget(c);
    end
    if (n_traffic == 0)
      `uvm_error(get_type_name(), $sformatf(
          "T1-C43: queued demand completed before credit release (%0d %s credits)",
          grant_granules, aou_cc_name(c)))
    cfg.l3_cfg.ret_policy[c] = ret;
    env.l3.model.release_withheld();
    wait_traffic();
    for (int unsigned r = 0; r < cfg.n_rp; r++) begin
      int unsigned seen = env.crd_chk.dut_msg_starts[r][c] - starts_before[r];
      void'(env.crd_chk.check_exact_budget_count(
          r, c, seen, n, "after credit release"));
    end
    drain();
    sw_deactivate();
  endtask

  task zero_all(aou_cred_class_e c);
    int unsigned depth0;
    int unsigned hold = arg_int("hold", 2000);
    int unsigned grant = arg_int("grant", default_grant(c));
    aou_t1_dir_e dir = dir_for(c);
    aou_t1_traffic_cfg p = profile_for(c);
    `uvm_info(get_type_name(), $sformatf("zero %s credit, %s traffic, grant %0d after %0d cycles",
                                         aou_cc_name(c), dir.name(), grant, hold), UVM_LOW)
    link_up();
    // The modelled RX buffer of class c is empty of credit from the start.
    depth0 = cfg.l3_cfg.rx_depth[c];
    cfg.l3_cfg.rx_depth[c] = 0;
    env.l3.model.crd.reset_link();
    sw_activate();
    traffic_nb(dir, num_txns, p);
    wait_cycles(hold);
    if (n_traffic == 0)
      `uvm_error(get_type_name(), $sformatf("T1-L11: traffic completed with no %s credit",
                                            aou_cc_name(c)))
    if (env.l3.model.crd.rx_outstanding[0][c] != 0)
      `uvm_error(get_type_name(), $sformatf("T1-L12: %0d %s credits outstanding, none granted",
                                            env.l3.model.crd.rx_outstanding[0][c],
                                            aou_cc_name(c)))
    if (arg_int("deact", 0) != 0) begin
      deact_pending(c, grant, depth0);
      return;
    end
    for (int unsigned r = 0; r < cfg.n_rp; r++) grant_rp(c, r, grant);
    wait_traffic();
    drain();
    sw_deactivate();
  endtask

  task deact_pending(aou_cred_class_e c, int unsigned grant, int unsigned depth0);
    int unsigned dhold = arg_int("deact_hold", 2000);
    int cm = arg_int("credit_manage", 0);
    deact_done = 1'b0;
    `uvm_info(get_type_name(), $sformatf("DEACTIVATE_START with %s traffic waiting for credit",
                                         aou_cc_name(c)), UVM_LOW)
    fork
      begin
        deactivate(AOU_T1_BY_APB, 1'b0, cm);
        deact_done = 1'b1;
      end
    join_none
    wait_cycles(dhold);
    `uvm_info(get_type_name(), $sformatf("%0d cycles after DEACTIVATE_START: DeactivateReq %0s",
                                         dhold, env.l3.model.lnk.dreq_rcvd || deact_done ?
                                         "received" : "not received"), UVM_LOW)
    // Later epochs (software activates again for what it still has to send)
    // get the credit back.
    cfg.l3_cfg.rx_depth[c] = depth0;
    for (int unsigned r = 0; r < cfg.n_rp; r++) grant_rp(c, r, grant);
    wait_traffic();
    wait (deact_done);
    drain();
  endtask
endclass
