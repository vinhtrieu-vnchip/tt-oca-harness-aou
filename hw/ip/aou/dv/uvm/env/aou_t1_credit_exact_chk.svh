// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

`uvm_analysis_imp_decl(_credit_grant)
`uvm_analysis_imp_decl(_credit_admit)

// Independent wire-RP/class ledger at the accepted, cancel-resolved FDI flit
// boundary. Never fund this ledger from ap_tx_flit (packer intent). Credits
// become available at the RX half cancellation-resolution edge; admissions
// use the actual accepted TX beat containing the message start. Independent
// TX watermarks order deferred decoding without arbitrary timing slack.
// A separate registered-counter prediction checks saturation and reservations;
// cumulative wire observations independently conserve parsed grants and debits.
class aou_t1_credit_exact_chk extends uvm_component;
  `uvm_component_utils(aou_t1_credit_exact_chk)
  uvm_analysis_imp_credit_grant #(aou_flit_item, aou_t1_credit_exact_chk) grant_imp;
  uvm_analysis_imp_credit_admit #(aou_flit_item, aou_t1_credit_exact_chk) admit_imp;
  aou_t1_env_cfg cfg;
  aou_l3_model model;
  int unsigned last_link_epoch;
  int unsigned aborted_events;
  virtual aou_rst_if rst_vif;
  aou_fdi_monitor wire_mon;
  int unsigned credit_max[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned epoch;
  int unsigned balance[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned granted[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned consumed[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned discarded[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned admitted[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned same_flit[AOU_CC_NUM];
  bit same_seen[AOU_CC_NUM];
  int unsigned total_granted[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned total_consumed[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned total_discarded[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned counter_pred[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned parsed_granted[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned reserved[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned wire_cost[AOU_RP_MAX][AOU_CC_NUM];
  int unsigned aborted_cost[AOU_RP_MAX][AOU_CC_NUM];
  bit cg_seen[AOU_RP_MAX][AOU_CC_NUM];
  bit have_counter_pred, previous_disabled;
  int unsigned split_grants;
  int unsigned failures;
  bit injected;
  string negative;
  typedef struct {
    time stamp;
    bit [1:0] grant;  // 0: wire admission, 1: wire grant, 2: parsed grant
    int unsigned rp;
    aou_cred_class_e cls;
    int unsigned amount;
    aou_granule_t raw;
    bit same;
  } credit_event_t;
  credit_event_t events[$];
  aou_granule_t grant_carry[$];
  time grant_carry_commit;
  bit in_reset;
  aou_fc_group fc;
  int unsigned s_class, s_rp, s_event;
  covergroup cg_credit_exact;
    cp_class: coverpoint s_class {
      `AOU_T1_CRD_FC_CLS(AOU_FC_CG)
    }
    cp_rp: coverpoint s_rp {
      `AOU_T1_EXACT_FC_RP(AOU_FC_CG)
    }
    cp_event: coverpoint s_event {
      `AOU_T1_EXACT_FC_EV(AOU_FC_CG)
    }
    x_class_rp_event: cross cp_class, cp_rp, cp_event;
  endgroup

  function new(string name, uvm_component parent);
    aou_fc_db db;
    aou_fc_point p;
    bit fresh;
    super.new(name, parent);
    cg_credit_exact = new();
    grant_imp = new("grant_imp", this);
    admit_imp = new("admit_imp", this);
    db = aou_fc_db::get();
    fc = db.group("env.cg_credit_exact", fresh);
    if (fresh) begin
      p = fc.cp("cp_class");
      `AOU_T1_CRD_FC_CLS(AOU_FC_REG)
      p = fc.cp("cp_rp");
      `AOU_T1_EXACT_FC_RP(AOU_FC_REG)
      p = fc.cp("cp_event");
      `AOU_T1_EXACT_FC_EV(AOU_FC_REG)
      void'(fc.add_cross("x_class_rp_event", "cp_class cp_rp cp_event"));
    end
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    foreach (credit_max[r, c])
    if (!uvm_config_db#(int unsigned)::get(
            null, "*", $sformatf("credit_max_%0d_%0d", r, c), credit_max[r][c]
        ) || credit_max[r][c] == 0)
      `uvm_fatal(get_type_name(), "missing compiled TX credit capacity")
    void'($value$plusargs("credit_exact_negative=%s", negative));
    if (negative != "" && !(negative inside {"over", "rp", "class", "duplicate", "same"}))
      `uvm_fatal(get_type_name(), "unknown credit_exact_negative mode")
  endfunction

  function void fail(string text);
    failures++;
    aou_rule_log::fire("T1-C43", get_type_name());
    `uvm_error(get_type_name(), {"T1-C43: ", text})
  endfunction

  function void sample (int unsigned r, int unsigned c, int unsigned ev);
    s_class = c;
    s_rp = r;
    s_event = ev;
    cg_credit_exact.sample();
    fc.sample(int'(c), int'(r), int'(ev));
  endfunction

  function int event_order(credit_event_t e);
    return e.grant == 1 ? 0 : e.grant == 2 ? 1 : 2;
  endfunction
  function void queue_event(credit_event_t e);
    int i = 0;
    while(i<events.size() && (events[i].stamp<e.stamp ||
          (events[i].stamp==e.stamp && event_order(
        events[i]
    ) <= event_order(
        e
    ))))
    i++;
    events.insert(i, e);
  endfunction

  function void queue_cg(aou_msg_crdtgrant cg, time stamp, int unsigned hr,
                         input int unsigned hn[AOU_CC_NUM]);
    for (int r = 0; r < cfg.l3_cfg.eff_rp_count(); r++)
    for (int c = 0; c < AOU_CC_NUM; c++) begin
      int unsigned n = cg.get_cred(r, aou_cred_class_e'(c));
      bit both = (r == hr && hn[c] != 0 && n != 0);
      if (n != 0) queue_event('{stamp, 1'b1, r, aou_cred_class_e'(c), n, 40'b0, both});
      if (n != 0) cg_seen[r][c] = 1'b1;
    end
  endfunction

  // Called immediately for each uncancelled 128-byte RX half, not when
  // a future second half completes. A split grant waits for its second granule.
  function void write_credit_grant(aou_flit_item it);
    aou_flit f = new("accepted_grants");
    int unsigned h = it.observed_half;
    int unsigned first = h * AOU_HALF_G;
    int unsigned last = first + AOU_HALF_G;
    int unsigned hr, hn[AOU_CC_NUM];
    aou_msg m;
    aou_msg_crdtgrant cg;
    time stamp = it.committed_half[h];
    f.from_bytes(it.data);
    foreach (hn[c]) hn[c] = 0;
    if (h == 0) foreach (cg_seen[r, c]) cg_seen[r][c] = 1'b0;
    else aou_credit_mgr::hdr_decode(f.msg_credit, hr, hn);
    if (stamp == 0) begin
      fail("RX half lacks cancellation-resolution timestamp");
      return;
    end
    if (grant_carry.size() != 0) begin
      grant_carry.push_back(f.g[first]);
      m = aou_msg_codec::decode(grant_carry, cfg.l3_cfg.spec_rev);
      if (!$cast(cg, m)) fail("split CrdtGrant did not reconstruct");
      else queue_cg(cg, stamp, hr, hn);
      grant_carry.delete();
      split_grants++;
      for (int r = 0; r < cfg.l3_cfg.eff_rp_count(); r++)
      for (int c = 0; c < AOU_CC_NUM; c++) if (cg_seen[r][c]) sample (r, c, 5);
    end
    for (int g = int'(first); g < int'(last); g++) begin
      if (!f.msg_start[g] || f.g[g][39:33] != {AOU_MT_MISC, AOU_MISCOP_CRDT}) continue;
      if (g + 1 == int'(last)) begin
        grant_carry.push_back(f.g[g]);
        continue;
      end
      begin
        aou_granule_t mg[$];
        mg.push_back(f.g[g]);
        mg.push_back(f.g[g+1]);
        m = aou_msg_codec::decode(mg, cfg.l3_cfg.spec_rev);
        if (!$cast(cg, m)) begin
          fail("CrdtGrant type mismatch");
          continue;
        end
        if (aou_granule_byte(
                g
            ) / cfg.fdi_cfg[it.phy].beat_bytes != (aou_granule_byte(
                g + 1
            ) + 4) / cfg.fdi_cfg[it.phy].beat_bytes) begin
          split_grants++;
          for (int r = 0; r < cfg.l3_cfg.eff_rp_count(); r++)
          for (int c = 0; c < AOU_CC_NUM; c++)
          if (cg.get_cred(r, aou_cred_class_e'(c)) != 0) sample (r, c, 5);
        end
        queue_cg(cg, stamp, hr, hn);
      end
    end
    if (h == 1 && hr < cfg.l3_cfg.eff_rp_count())
      for (int c = 0; c < AOU_CC_NUM; c++) begin
        bit both = hn[c] != 0 && cg_seen[hr][c];
        if (hn[c] != 0) queue_event('{stamp, 2'd1, hr, aou_cred_class_e'(c), hn[c], 40'b0, both});
        if (both) begin
          same_flit[c]++;
          sample (hr, c, 4);
        end
      end
  endfunction

  function void write_credit_admit(aou_flit_item it);
    aou_flit f = new("accepted_admissions");
    f.from_bytes(it.data);
    for (int g = 0; g < AOU_GRANULES; g++)
    if (f.msg_start[g]) begin
      aou_cred_class_e c = aou_cred_class_of(f.g[g][39:36]);
      int unsigned r = int'(f.g[g][35:34]);
      int unsigned n = aou_msg_len(f.g[g], cfg.l3_cfg.spec_rev);
      time stamp = it.accepted_beat[aou_granule_byte(g)/cfg.fdi_cfg[it.phy].beat_bytes];
      if (c == AOU_CC_NONE) continue;
      if (stamp == 0) begin
        fail("TX admission lacks accepted-beat timestamp");
        continue;
      end
      if (r < AOU_RP_MAX) wire_cost[r][c] += n;
      queue_event('{stamp, 1'b0, r, c, n, f.g[g], 1'b0});
    end
  endfunction

  // Wire accounting remains cumulative. Usable credit resets are checked
  // separately at the actual counter boundary; expired credit is never reused
  // by that prediction. Known complete observations are retained across epochs.
  function void reset_epoch();
    epoch++;
    aborted_events += grant_carry.size();
    grant_carry.delete();
  endfunction

  function void audit(int unsigned r, int unsigned c);
    aou_rule_log::check("T1-C43", get_type_name());
    if (granted[r][c] != balance[r][c] + consumed[r][c])
      fail($sformatf(
           "RP%0d class%0d wire ledger balance=%0d grant=%0d used=%0d",
           r,
           c,
           balance[r][c],
           granted[r][c],
           consumed[r][c]
           ));
  endfunction

  function void add_grant(int unsigned r, int unsigned c, int unsigned n);
    if (n == 0) return;
    granted[r][c] += n;
    total_granted[r][c] += n;
    balance[r][c] += n;
    sample (r, c, 0);
    audit(r, c);
  endfunction

  function bit check_reservation(int unsigned r, int unsigned c, int unsigned old,
                                 int unsigned gain, int unsigned debit);
    aou_rule_log::check("T1-C43", get_type_name());
    if (debit <= old + gain) return 1'b1;
    fail($sformatf(
         "reservation over-admission RP%0d class%0d old=%0d grant=%0d debit=%0d",
         r,
         c,
         old,
         gain,
         debit
         ));
    return 1'b0;
  endfunction

  // One sampled registered-state transition. Debit is an accepted TX-buffer
  // commitment, including WriteReq's first-WriteData coupling, not eligibility.
  // Independent wire conservation below validates those observed debit costs.
  function void observe_counter();
    foreach (counter_pred[r, c]) begin
      int unsigned g = rst_vif.mon_cb.credit_grant[r][c];
      int unsigned d = rst_vif.mon_cb.credit_debit[r][c];
      int unsigned next_value;
      if (have_counter_pred && rst_vif.mon_cb.credit_state[r][c] !== counter_pred[r][c])
        fail($sformatf(
             "counter RP%0d class%0d actual=%0d expected=%0d",
             r,
             c,
             rst_vif.mon_cb.credit_state[r][c],
             counter_pred[r][c]
             ));
      if (g != 0) queue_event('{$time, 2'd2, r, aou_cred_class_e'(c), g, 40'b0, 1'b0});
      if (rst_vif.mon_cb.credit_count_en) begin
        reserved[r][c] += d;
        if (!injected && negative == "over" && d != 0) begin
          void'(check_reservation(r, c, counter_pred[r][c], g, counter_pred[r][c] + g + 1));
          injected = 1'b1;
          `uvm_info(get_type_name(), "C1C_INJECTED=over", UVM_LOW)
        end
      end
      if (rst_vif.mon_cb.credit_disabled && !previous_disabled) counter_pred[r][c] = 0;
      else if (rst_vif.mon_cb.credit_count_en) begin
        if (!check_reservation(r, c, counter_pred[r][c], g, d)) next_value = 0;
        else next_value = counter_pred[r][c] + g - d;
        if (next_value > credit_max[r][c]) begin
          total_discarded[r][c] += next_value - credit_max[r][c];
          next_value = credit_max[r][c];
          sample (r, c, 3);
        end
        counter_pred[r][c] = next_value;
        if (next_value == 0 && d != 0) sample (r, c, 2);
      end
    end
    previous_disabled = rst_vif.mon_cb.credit_disabled;
    have_counter_pred = 1'b1;
  endfunction

  function void check_attribution(aou_granule_t raw, int unsigned r, aou_cred_class_e c);
    aou_rule_log::check("T1-C43", get_type_name());
    if (r != int'(raw[35:34]) || c != aou_cred_class_of(raw[39:36]))
      fail($sformatf(
           "decoded RP/class attribution differs from accepted header: raw=%h RP%0d %s",
           raw,
           r,
           aou_cc_name(
               c
           )
           ));
  endfunction

  function bit check_admission(int unsigned r, aou_cred_class_e c, int unsigned n);
    aou_rule_log::check("T1-C43", get_type_name());
    if (balance[r][c] >= n) return 1'b1;
    fail($sformatf(
         "over-admission epoch%0d wire-RP%0d %s needs%0d has%0d",
         epoch,
         r,
         aou_cc_name(
             c
         ),
         n,
         balance[r][c]
         ));
    return 1'b0;
  endfunction

  function void apply_event(credit_event_t e);
    int unsigned r = e.rp;
    aou_cred_class_e c = e.cls;
    if (r >= cfg.l3_cfg.eff_rp_count()) begin
      fail("admission names unavailable wire RP");
      return;
    end
    if (e.grant == 2) begin
      parsed_granted[r][c] += e.amount;
      aou_rule_log::check("T1-C43", get_type_name());
      if (parsed_granted[r][c] > granted[r][c])
        fail($sformatf(
             "early/unearned parsed grant RP%0d class%0d parsed=%0d wire=%0d",
             r,
             c,
             parsed_granted[r][c],
             granted[r][c]
             ));
    end else if (e.grant == 1) begin
      if (!injected && ((negative == "duplicate") || (negative == "same" && e.same))) begin
        balance[r][c]++;
        audit(r, c);
        balance[r][c]--;
        injected = 1'b1;
        `uvm_info(get_type_name(), {"C1C_INJECTED=", negative}, UVM_LOW)
      end
      add_grant(r, c, e.amount);
    end else begin
      int unsigned observed_r = r;
      aou_cred_class_e observed_c = c;
      if (!injected && negative inside {"rp", "class"}) begin
        if (negative == "rp") observed_r = (r + 1) % AOU_RP_MAX;
        else observed_c = aou_cred_class_e'((int'(c) + 1) % AOU_CC_NUM);
        injected = 1'b1;
        `uvm_info(get_type_name(), {"C1C_INJECTED=", negative}, UVM_LOW)
      end
      check_attribution(e.raw, observed_r, observed_c);
      total_consumed[r][c] += (balance[r][c] < e.amount) ? balance[r][c] : e.amount;
      if (!check_admission(r, c, e.amount)) begin
        consumed[r][c] += balance[r][c];
        balance[r][c] = 0;
      end else begin
        consumed[r][c] += e.amount;
        balance[r][c] -= e.amount;
      end
      admitted[r][c]++;
      sample (r, c, 1);
      if (balance[r][c] == 0) sample (r, c, 2);
      audit(r, c);
    end
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(rst_vif.mon_cb);
      if (rst_vif.mon_cb.rst_n !== 1'b1 || rst_vif.mon_cb.core_rst_n !== 1'b1) begin
        if (!in_reset) begin
          reset_epoch();
          foreach (reserved[r, c])
          if (reserved[r][c] > wire_cost[r][c] + aborted_cost[r][c])
            aborted_cost[r][c] = reserved[r][c] - wire_cost[r][c];
        end
        foreach (counter_pred[r, c]) counter_pred[r][c] = 0;
        previous_disabled = 1'b0;
        have_counter_pred = 1'b1;
        in_reset = 1'b1;
        continue;
      end
      in_reset = 1'b0;
      observe_counter();
      if (model.lnk.epoch != last_link_epoch) begin
        reset_epoch();
        last_link_epoch = model.lnk.epoch;
      end
      begin
        time watermark = wire_mon.pending_tx_start();
        if (watermark == 0 || watermark > $time) watermark = $time;
        while (events.size() != 0 && events[0].stamp < watermark) begin
          credit_event_t e = events.pop_front();
          apply_event(e);
        end
      end
    end
  endtask

  function int unsigned outstanding();
    int unsigned n = events.size() + grant_carry.size();
    foreach (reserved[r, c]) begin
      if (reserved[r][c] > wire_cost[r][c] + aborted_cost[r][c]) n++;
      if (granted[r][c] > parsed_granted[r][c]) n++;
    end
    return n;
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (events.size() != 0 || grant_carry.size() != 0)
      fail("unprocessed physical credit/admission observations at final drain");
    foreach (reserved[r, c]) begin
      if (reserved[r][c] != wire_cost[r][c] + aborted_cost[r][c])
        fail($sformatf(
             "reservation/wire conservation RP%0d class%0d reserve=%0d wire=%0d aborted=%0d",
             r,
             c,
             reserved[r][c],
             wire_cost[r][c],
             aborted_cost[r][c]
             ));
      if (granted[r][c] != parsed_granted[r][c])
        fail($sformatf(
             "grant conservation RP%0d class%0d wire=%0d parsed=%0d",
             r,
             c,
             granted[r][c],
             parsed_granted[r][c]
             ));
    end
    if (negative != "" && !injected) fail({"negative control did not activate: ", negative});
  endfunction
  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info(get_type_name(), $sformatf(
              {
                "C1C_COUNTER predicted=%p reserved=%p wire_cost=%p ", "aborted=%p parsed_grants=%p"
              },
              counter_pred,
              reserved,
              wire_cost,
              aborted_cost,
              parsed_granted
              ), UVM_LOW)
    `uvm_info(get_type_name(), $sformatf(
              {
                "C1C epoch=%0d grants=%p consumed=%p wire_upper=%p admitted=%p ",
                "discarded=%p same=%p split=%0d failures=%0d"
              },
              epoch,
              total_granted,
              total_consumed,
              balance,
              admitted,
              total_discarded,
              same_flit,
              split_grants,
              failures
              ), UVM_LOW)
  endfunction
endclass
