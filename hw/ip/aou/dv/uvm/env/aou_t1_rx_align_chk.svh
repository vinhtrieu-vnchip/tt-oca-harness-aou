// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// T1-C42: every accepted RX flit carries one header MsgCredit, which the DUT
// takes exactly once and in order. A flit abandoned on LinkError may be taken;
// pending observations are discarded at link/core reset.
// T1-C43: every accepted wire CrdtGrant must be decoded into an identical
// credit-controller input tuple. The checker is passive and observes the FDI
// monitor's post-cancel flit plus the decoder-to-controller handoff.
class aou_t1_rx_align_chk extends uvm_component;
  `uvm_component_utils(aou_t1_rx_align_chk)

  uvm_analysis_imp #(aou_flit_item, aou_t1_rx_align_chk) rx_flit_imp;

  virtual aou_rst_if                      rst_vif;
  virtual aou_fdi_mb_if #(.DATA_W(BUS_W)) mb_vif;
  aou_l3_cfg                               l3_cfg;
  aou_unpacker                             wire_unp;
  bit                                      dense_misc_cov_en;
  bit                                      ordered_grant_chk_en;
  bit                                      rdata_counter_chk_en;
  longint                                  slack = 16;

  int unsigned n_ok;
  int unsigned n_err;
  int unsigned n_may;

  protected bit [15:0]   exp_mc[$];
  protected longint      exp_cyc[$];
  protected bit [15:0]   got_mc[$];
  protected longint      got_cyc[$];
  protected bit          got_may[$];
  protected logic [59:0] exp_grant[$];
  protected longint      exp_grant_cyc[$];
  protected logic [59:0] got_grant[$];
  protected longint      got_grant_cyc[$];
  protected longint      cyc;
  protected int unsigned wire_flit_seq;
  protected int unsigned n_wire_grants;
  protected int unsigned n_decoded_grants;
  protected int unsigned n_grants_matched;
  protected int unsigned n_dense_misc_chunks;
  protected int unsigned expected_rdata_rp0;
  protected bit          rdata_counter_base_valid;
  protected logic [15:0] rdata_counter_base;
  protected logic [15:0] rdata_counter_last;
  protected int unsigned s_rx_misc_event;
  covergroup cg_rx_misc;
    cp_event: coverpoint s_rx_misc_event {
      `AOU_T1_RX_MISC_FC_EVENT(AOU_FC_CG)
    }
  endgroup
  protected aou_fc_group fc_rx_misc;

  function new(string name, uvm_component parent);
    aou_fc_db db;
    aou_fc_point p;
    bit fresh;
    super.new(name, parent);
    rx_flit_imp = new("rx_flit_imp", this);
    cg_rx_misc = new();
    db = aou_fc_db::get();
    fc_rx_misc = db.group("t1.rx_misc_cg", fresh);
    if (fresh) begin
      p = fc_rx_misc.cp("cp_event"); `AOU_T1_RX_MISC_FC_EVENT(AOU_FC_REG)
    end
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (l3_cfg != null) begin
      wire_unp = aou_unpacker::type_id::create("wire_unp");
      wire_unp.cfg = l3_cfg;
      wire_unp.chk = l3_cfg.chk;
      wire_unp.dir = AOU_L3_TX; // accepted remote-to-DUT wire
    end
  endfunction

  protected function logic [59:0] grant_encoding(aou_msg_crdtgrant g);
    return {
      g.enc[0][AOU_CC_WREQ],  g.enc[1][AOU_CC_WREQ],  g.enc[2][AOU_CC_WREQ],
      g.enc[3][AOU_CC_WREQ],  g.enc[0][AOU_CC_RREQ],  g.enc[1][AOU_CC_RREQ],
      g.enc[2][AOU_CC_RREQ],  g.enc[3][AOU_CC_RREQ],  g.enc[0][AOU_CC_WDATA],
      g.enc[1][AOU_CC_WDATA], g.enc[2][AOU_CC_WDATA], g.enc[3][AOU_CC_WDATA],
      g.enc[0][AOU_CC_RDATA], g.enc[1][AOU_CC_RDATA], g.enc[2][AOU_CC_RDATA],
      g.enc[3][AOU_CC_RDATA], {1'b0, g.enc[0][AOU_CC_WRESP][1:0]},
      {1'b0, g.enc[1][AOU_CC_WRESP][1:0]}, {1'b0, g.enc[2][AOU_CC_WRESP][1:0]},
      {1'b0, g.enc[3][AOU_CC_WRESP][1:0]}};
  endfunction

  protected function void sample_dense_misc();
    s_rx_misc_event = 1;
    cg_rx_misc.sample();
    fc_rx_misc.sample(1);
    n_dense_misc_chunks++;
  endfunction

  protected function void collect_wire_grants(aou_flit_item it);
    aou_flit f = aou_flit::type_id::create("rx_wire_flit");
    aou_msg_crdtgrant grant;
    int unsigned misc_count[4] = '{default: 0};
    aou_msg third_misc[4];
    f.from_bytes(it.data);
    f.seq = wire_flit_seq++;
    f.dir = AOU_L3_TX;
    wire_unp.unpack(f);
    foreach (wire_unp.done[i]) begin
      if ($cast(grant, wire_unp.done[i])) begin
        exp_grant.push_back(grant_encoding(grant));
        exp_grant_cyc.push_back(cyc);
        n_wire_grants++;
        if (rdata_counter_chk_en)
          expected_rdata_rp0 += grant.get_cred(0, AOU_CC_RDATA);
      end
      if (wire_unp.done[i].start_flit == int'(f.seq) && wire_unp.done[i].is_misc()) begin
        int unsigned chunk = wire_unp.done[i].start_granule / 12;
        if (chunk < 4) begin
          misc_count[chunk]++;
          if (misc_count[chunk] == 3) third_misc[chunk] = wire_unp.done[i];
        end
      end
    end
    foreach (misc_count[c]) begin
      if (dense_misc_cov_en && misc_count[c] >= 3 && $cast(grant, third_misc[c]) &&
          grant.get_cred(0, AOU_CC_RDATA) != 0)
        sample_dense_misc();
    end
  endfunction

  function void write(aou_flit_item it);
    exp_mc.push_back({it.data[129], it.data[128]});
    exp_cyc.push_back(cyc);
    if (wire_unp != null) collect_wire_grants(it);
  endfunction

  protected function void fail(string msg);
    n_err++;
    aou_rule_log::fire("T1-C42", get_type_name());
    `uvm_error(get_type_name(), {"T1-C42: ", msg})
  endfunction

  protected function void fail_grant(string msg);
    n_err++;
    aou_rule_log::fire("T1-C43", get_type_name());
    `uvm_error(get_type_name(), {"T1-C43: ", msg})
  endfunction

  protected function void flush();
    exp_mc.delete(); exp_cyc.delete();
    got_mc.delete(); got_cyc.delete(); got_may.delete();
  endfunction

  protected function void flush_grants();
    exp_grant.delete(); exp_grant_cyc.delete();
    got_grant.delete(); got_grant_cyc.delete();
  endfunction

  protected function void match();
    while (exp_mc.size() != 0 && got_mc.size() != 0) begin
      bit [15:0] e = exp_mc.pop_front();
      bit [15:0] g = got_mc.pop_front();
      void'(exp_cyc.pop_front());
      void'(got_cyc.pop_front());
      void'(got_may.pop_front());
      aou_rule_log::check("T1-C42", get_type_name());
      if (e == g) begin
        n_ok++;
      end else begin
        fail($sformatf({"MsgCredit 0x%04h taken for a delivered flit that carries 0x%04h ",
                        "(RX flit framing differs from the Adapter's)"}, g, e));
        flush();
      end
    end
    if (got_mc.size() != 0 && got_may[0]) begin
      n_may++;
      got_mc.delete(); got_cyc.delete(); got_may.delete();
    end
    if (exp_mc.size() != 0 && cyc - exp_cyc[0] > slack) begin
      aou_rule_log::check("T1-C42", get_type_name());
      fail($sformatf("flit delivered %0d cycles ago with MsgCredit 0x%04h, not taken by the DUT",
                     cyc - exp_cyc[0], exp_mc[0]));
      flush();
    end
    if (got_mc.size() != 0 && cyc - got_cyc[0] > slack) begin
      aou_rule_log::check("T1-C42", get_type_name());
      fail($sformatf("MsgCredit 0x%04h taken %0d cycles ago, no delivered flit carries it",
                     got_mc[0], cyc - got_cyc[0]));
      flush();
    end
  endfunction

  protected function void match_grants();
    int unsigned i = 0;
    if (ordered_grant_chk_en) begin
      // The focused 512-bit test has one decoder lane, whose two candidate
      // slots retain source order. Enforce that order in this mode.
      while (exp_grant.size() != 0 && got_grant.size() != 0) begin
        if (exp_grant[0] === got_grant[0]) begin
          aou_rule_log::check("T1-C43", get_type_name());
          n_grants_matched++;
          exp_grant.pop_front();
          exp_grant_cyc.pop_front();
          got_grant.pop_front();
          got_grant_cyc.pop_front();
        end else begin
          if (cyc - exp_grant_cyc[0] > slack || cyc - got_grant_cyc[0] > slack) begin
            fail_grant($sformatf("ordered CrdtGrant mismatch: accepted wire %015h, decoder %015h",
                                 exp_grant[0], got_grant[0]));
            flush_grants();
          end
          return;
        end
      end
      return;
    end
    // Grants add credits; compare exact tuples as a multiset rather than
    // imposing an order across decoder slots or independent messages.
    while (i < exp_grant.size()) begin
      int found = -1;
      for (int unsigned j = 0; j < got_grant.size(); j++) begin
        if (exp_grant[i] === got_grant[j]) begin
          found = int'(j);
          break;
        end
      end
      if (found >= 0) begin
        aou_rule_log::check("T1-C43", get_type_name());
        n_grants_matched++;
        exp_grant.delete(i);
        exp_grant_cyc.delete(i);
        got_grant.delete(found);
        got_grant_cyc.delete(found);
      end else begin
        i++;
      end
    end
    for (int unsigned j = 0; j < exp_grant.size(); j++) begin
      if (cyc - exp_grant_cyc[j] > slack) begin
        fail_grant($sformatf("accepted wire CrdtGrant %015h was not decoded to the credit controller",
                             exp_grant[j]));
        flush_grants();
        return;
      end
    end
    for (int unsigned j = 0; j < got_grant.size(); j++) begin
      if (cyc - got_grant_cyc[j] > slack) begin
        fail_grant($sformatf("decoded CrdtGrant %015h has no accepted wire message",
                             got_grant[j]));
        flush_grants();
        return;
      end
    end
  endfunction

  task run_phase(uvm_phase phase);
    if (rst_vif == null || mb_vif == null) return;
    forever begin
      @(rst_vif.mon_cb);
      cyc++;
      if (rst_vif.mon_cb.rst_n !== 1'b1 || rst_vif.mon_cb.core_rst_n !== 1'b1) begin
        flush();
        flush_grants();
        if (wire_unp != null) wire_unp.reset();
        if (rdata_counter_chk_en) begin
          rdata_counter_base_valid = 1'b0;
          expected_rdata_rp0 = 0;
        end
        continue;
      end
      if (rdata_counter_chk_en) begin
        rdata_counter_last = rst_vif.mon_cb.rx_rdata_credit_rp0;
        if (!rdata_counter_base_valid) begin
          rdata_counter_base = rdata_counter_last;
          rdata_counter_base_valid = 1'b1;
        end
      end
      if (rst_vif.mon_cb.rx_msgcrdt_valid === 1'b1) begin
        logic [3:0] sts = mb_vif.mon_cb.pl_state_sts;
        got_mc.push_back(rst_vif.mon_cb.rx_msgcrdt);
        got_cyc.push_back(cyc);
        got_may.push_back(sts != FDI_STS_ACTIVE && sts != FDI_STS_RESET);
      end
      for (int unsigned slot = 0; slot < 4; slot++) begin
        if (rst_vif.mon_cb.rx_crdtgrant_valid[slot] === 1'b1) begin
          got_grant.push_back(rst_vif.mon_cb.rx_crdtgrant_enc[slot]);
          got_grant_cyc.push_back(cyc);
          n_decoded_grants++;
        end
      end
      // Monitor writes of this edge may land before or after this process.
      match();
      match_grants();
    end
  endtask

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    // The focused diagnostic's qualification depends on reaching the accepted-
    // wire event, not just on the general grant/counter checks below. Keep this
    // requirement opt-in so ordinary tests retain the checker-only contract.
    if (dense_misc_cov_en && n_dense_misc_chunks == 0)
      `uvm_error(get_type_name(),
                 "STIMULUS_NOT_REACHED: no accepted RX chunk had three Misc starts with a nonzero RP0 RDATA grant third")
    if (rdata_counter_chk_en) begin
      // The focused regression explicitly drains beyond `slack`; make its
      // end-of-test closure strict without treating an unrelated test ending
      // less than `slack` cycles after a legal grant as a protocol failure.
      if (exp_grant.size() != 0) begin
        fail_grant($sformatf("%0d accepted wire CrdtGrant message(s) remain unmatched at end of test",
                             exp_grant.size()));
        flush_grants();
      end
      if (got_grant.size() != 0) begin
        fail_grant($sformatf("%0d decoded CrdtGrant slot(s) have no accepted wire message at end of test",
                             got_grant.size()));
        flush_grants();
      end
      if (!rdata_counter_base_valid || $isunknown(rdata_counter_last) ||
          rdata_counter_last < rdata_counter_base ||
          (int'(rdata_counter_last) - int'(rdata_counter_base)) != int'(expected_rdata_rp0)) begin
        fail_grant($sformatf("RP0 RDATA credit counter delta %0d, accepted-wire grant total %0d",
                             (rdata_counter_last >= rdata_counter_base) ?
                               int'(rdata_counter_last) - int'(rdata_counter_base) : -1,
                             expected_rdata_rp0));
      end else begin
        aou_rule_log::check("T1-C43", get_type_name());
      end
    end
  endfunction

  function void report_phase(uvm_phase phase);
    `uvm_info(get_type_name(), $sformatf(
        "%0d delivered flits matched by the DUT's MsgCredit, %0d of abandoned flits taken",
        n_ok, n_may), UVM_LOW)
    if (l3_cfg != null)
      `uvm_info(get_type_name(), $sformatf(
          "T1-C43 accepted CrdtGrant wire=%0d decoded=%0d matched=%0d; dense Misc/RDATA chunks=%0d; RP0 RDATA expected=%0d counter delta=%0d",
          n_wire_grants, n_decoded_grants, n_grants_matched, n_dense_misc_chunks,
          expected_rdata_rp0,
          (rdata_counter_last >= rdata_counter_base) ?
            int'(rdata_counter_last) - int'(rdata_counter_base) : -1), UVM_LOW)
  endfunction
endclass
