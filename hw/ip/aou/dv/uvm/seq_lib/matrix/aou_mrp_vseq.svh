// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

class aou_b_combiner_fill_seq extends aou_axi_base_seq;
  `uvm_object_utils(aou_b_combiner_fill_seq)

  int unsigned rp = 0;
  int unsigned read_count = 2;
  int unsigned write_count = 16;
  bit [63:0] base = '0;

  function new(string name = "aou_b_combiner_fill_seq");
    super.new(name);
  endfunction

  task body();
    for (int unsigned i = 0; i < read_count; i++) begin
      aou_axi_txn t = new_txn($sformatf("dg04_fill_read_%0d", i));
      t.dir = AOU_AXI_RD;
      t.id = 10'(rp * 64 + i);
      t.addr = base + 64'(i) * 64'h1000;
      t.len = 8'd15;
      t.size = 3'($clog2(t.data_bytes));
      t.burst = AOU_AXI_INCR;
      send(t);
    end
    for (int unsigned i = 0; i < write_count; i++) begin
      aou_axi_txn t = new_txn($sformatf("dg04_fill_write_%0d", i));
      t.dir = AOU_AXI_WR;
      t.id = 10'(rp * 64 + 32 + i);
      t.addr = base + 64'h0010_0000 + 64'(i) * 64'h1000;
      t.len = 8'd0;
      t.size = 3'($clog2(t.data_bytes));
      t.burst = AOU_AXI_INCR;
      t.fill_wdata(AOU_AXI_STRB_FULL);
      send(t);
    end
    wait_all();
  endtask
endclass

// Multi-RP scenarios (plan 2.12) over the RPs in +mrp_rps (default: all),
// both directions, data-checked by the scoreboard. +mrp_scn:
//   solo       traffic on the listed RPs only, the others idle (12.1-12.4)
//   seq        one RP after another, in list order (12.5, 12.7)
//   interleave every listed RP at once, back to back, with an arbitration
//              window on aou_mrp_chk (12.6, 12.8)
//   indep      +mrp_slow (default: last listed) gets slow local agents while the
//              others run at full rate (independence window); then all at once
//   crd_rr     +mrp_loops rounds: with the DUT's TX held, remote-die requests
//              on a random subset of the listed RPs (all of them in round 0)
//              leave the DUT owing each of them credit; on release
//              a window opened on the env's aou_t1_crd_rr_chk has it check the
//              MsgCredit order (round robin, 3.19)
class aou_mrp_vseq extends aou_dp_vseq;
  `uvm_object_utils(aou_mrp_vseq)

  aou_mrp_chk  chk;
  string       scn = "interleave";
  int unsigned rps[$];
  int unsigned slow = 0;
  virtual aou_b_combiner_if bci;

  function new(string name = "aou_mrp_vseq");
    super.new(name);
  endfunction

  task pre_body();
    string s;
    super.pre_body();
    if (!uvm_config_db#(aou_mrp_chk)::get(null, "*", "mrp_chk", chk))
      `uvm_fatal(get_type_name(), "no mrp_chk in config_db")
    void'($value$plusargs("mrp_scn=%s", scn));
    if ($value$plusargs("mrp_rps=%s", s)) void'(aou_dp_knobs::parse_list(s, rps));
    if (rps.size() == 0) for (int unsigned r = 0; r < cfg.n_rp; r++) rps.push_back(r);
    if (scn == "b_combiner") begin
      if (cfg.n_rp < 2) `uvm_fatal(get_type_name(), "b_combiner needs at least two RPs")
      if (!uvm_config_db#(virtual aou_b_combiner_if)::get(null, "*", "b_combiner", bci))
        `uvm_fatal(get_type_name(), "no b_combiner observer interface in config_db")
    end
    foreach (rps[i])
      if (rps[i] >= cfg.n_rp)
        `uvm_fatal(get_type_name(), $sformatf("+mrp_rps lists RP%0d, build has %0d RPs", rps[i],
                                              cfg.n_rp))
    slow = rps[rps.size() - 1];
    void'($value$plusargs("mrp_slow=%d", slow));
  endtask

  function bit [3:0] mask_of(int unsigned q[$]);
    bit [3:0] m = '0;
    foreach (q[i]) m[q[i]] = 1'b1;
    return m;
  endfunction

  function aou_t1_traffic_cfg prof(bit [3:0] m);
    aou_t1_traffic_cfg p = make_profile();
    p.rp_mask = m;
    return p;
  endfunction

  // Local agents with no added delay on the listed RPs, remote model too.
  function void full_rate();
    foreach (rps[i]) begin
      cfg.s_mgr_cfg[rps[i]].timing.apply(AOU_AXI_TIMING_ZERO);
      cfg.m_sub_cfg[rps[i]].timing.apply(AOU_AXI_TIMING_ZERO);
    end
    cfg.remote_cfg.timing.b_lat.set_zero();
    cfg.remote_cfg.timing.r_lat.set_zero();
  endfunction

  // A local side that answers slowly: the M-port subordinate holds ready low
  // and responds late, the S-port manager takes its responses late.
  function void slow_down(int unsigned r);
    cfg.m_sub_cfg[r].timing.aw_ready.set_range(300, 600);
    cfg.m_sub_cfg[r].timing.w_ready.set_range(20, 60);
    cfg.m_sub_cfg[r].timing.ar_ready.set_range(300, 600);
    cfg.m_sub_cfg[r].timing.b_lat.set_range(300, 600);
    cfg.m_sub_cfg[r].timing.r_lat.set_range(300, 600);
    cfg.s_mgr_cfg[r].timing.b_ready.set_range(300, 600);
    cfg.s_mgr_cfg[r].timing.r_ready.set_range(20, 60);
  endfunction

  virtual task scenario();
    `uvm_info(get_type_name(), $sformatf("scenario %s on RPs %p", scn, rps), UVM_LOW)
    case (scn)
      "solo": traffic(k.dir, num_txns, prof(mask_of(rps)));
      "seq": foreach (rps[i]) traffic(k.dir, num_txns, prof(4'(1 << rps[i])));
      "interleave": begin
        full_rate();
        chk.arb_start();
        traffic(k.dir, num_txns, prof(mask_of(rps)));
        chk.arb_stop();
      end
      "indep": begin
        int unsigned others[$];
        foreach (rps[i]) if (rps[i] != slow) others.push_back(rps[i]);
        if (others.size() == 0) `uvm_fatal(get_type_name(), "indep needs two RPs")
        full_rate();
        slow_down(slow);
        chk.ind_start(slow);
        traffic_nb(k.dir, num_txns, prof(4'(1 << slow)));
        // The others start once the slow RP is backed up.
        wait_cycles(400);
        traffic_nb(k.dir, num_txns, prof(mask_of(others)));
        wait_traffic();
        chk.ind_stop();
        full_rate();
        traffic(k.dir, num_txns, prof(mask_of(rps)));
      end
      "crd_rr": crd_rr();
      "b_combiner": b_combiner_scn();
      default: `uvm_fatal(get_type_name(), {"unknown +mrp_scn=", scn})
    endcase
  endtask

  task b_combiner_scn();
    if (rps.size() < 2) `uvm_fatal(get_type_name(), "b_combiner needs at least two selected RPs")
    full_rate();
    bci.arm();

    // First qualify clean-credit B responses with simultaneous RP contenders
    // while TX is available. Per-RP IDs are disjoint.
    launch_b_combiner_bursts(AOU_T1_R2L, 16, 0);
    wait fork;

    // Hold the active TX PHY before launching legal R2L traffic. Long reads
    // fill the TX ring; matched writes create the B responses observed at its
    // full boundary. Both classes share each RP's real AXI manager interface.
    cfg.drain_timeout = 100000;
    hold_tx();
    `uvm_info(get_type_name(), $sformatf("DG04 TX hold=%0b PL_TRDY=%0b",
                                         cfg.fdi_cfg[cfg.lsm_cfg.active_phy].tx_hold,
                                         env.fdi[cfg.lsm_cfg.active_phy].vif.mon_cb.pl_trdy),
               UVM_LOW)
    launch_b_combiner_fill_and_responses();
    bci.wait_b_stall(30000);
    // Keep the same output response stalled for additional sampled edges so
    // the observer can compare payload identity throughout the hold.
    wait_cycles(2);
    release_tx();
    wait fork;
    // Keep the maintained production scoreboard's local-to-remote path
    // non-vacuous; this traffic runs only after the B stall has released.
    traffic(AOU_T1_L2R, 1, prof(mask_of(rps)));
  endtask

  task launch_b_combiner_fill_and_responses();
    foreach (rps[i]) begin
      automatic int unsigned rp = rps[i];
      fork
        begin
          aou_b_combiner_fill_seq s = aou_b_combiner_fill_seq::type_id::create(
              $sformatf("dg04_fill_rp%0d", rp));
          s.rp = rp;
          s.base = 64'h1_0000_0000 + 64'(rp) * 64'h0100_0000;
          s.start(p_sequencer.r_mgr_sqr[rp]);
        end
      join_none
    end
  endtask

  // Use the repository's directed AXI burst sequence so each B probe has a
  // deterministic, legal address/length and an ID range disjoint by RP.
  task launch_b_combiner_bursts(aou_t1_dir_e dir, int unsigned n, bit [7:0] len);
    foreach (rps[i]) begin
      automatic int unsigned rp = rps[i];
      fork
        begin
          aou_burst_seq s = aou_burst_seq::type_id::create($sformatf("dg04_rp%0d", rp));
          aou_axi_sequencer sqr;
          s.n = n;
          s.dir = AOU_AXI_WR;
          s.base = 64'h1_0000_0000 + 64'(rp) * 64'h0100_0000;
          s.len = len;
          s.id = 10'(rp * 32);
          sqr = (dir == AOU_T1_R2L) ? p_sequencer.r_mgr_sqr[rp] : p_sequencer.s_mgr_sqr[rp];
          s.start(sqr);
        end
      join_none
    end
  endtask

  task body();
    super.body();
    if (scn == "b_combiner") begin
      bci.check_final();
      `uvm_info(get_type_name(), $sformatf(
                {"DG04 counters: contention_cycles=%0d contention_decisions=%0d ",
                 "RP_pop=%p RP_push=%p stalls=%0d releases=%0d ring_full=%0d ",
                 "global_enq=%0d global_deq=%0d ring_B_enq=%0d errors=%0d"},
                bci.contention_cycles, bci.contention_decisions, bci.source_pops,
                bci.source_pushes, bci.global_stall_cycles, bci.global_stall_releases,
                bci.ring_full_samples, bci.global_enqueues, bci.global_dequeues,
                bci.ring_b_enqueues, bci.errors), UVM_LOW)
    end
  endtask

  task crd_rr();
    int unsigned loops = 4;
    int unsigned win = 4000;
    if (rps.size() < 2) `uvm_fatal(get_type_name(), "crd_rr needs two RPs")
    void'($value$plusargs("mrp_loops=%d", loops));
    full_rate();
    for (int unsigned i = 0; i < loops; i++) begin
      int unsigned sub[$];
      int unsigned waited = 0;
      foreach (rps[j]) if (i == 0 || $urandom_range(1) == 1) sub.push_back(rps[j]);
      while (sub.size() < 2) begin
        int unsigned r = rps[$urandom_range(rps.size() - 1)];
        bit dup = 1'b0;
        foreach (sub[j]) if (sub[j] == r) dup = 1'b1;
        if (!dup) sub.push_back(r);
      end
      hold_tx();
      traffic_nb(AOU_T1_R2L, num_txns, prof(mask_of(sub)));
      // Long enough for the DUT to dequeue every request it received.
      wait_cycles(2000);
      void'(env.crd_rr.window_start());
      release_tx();
      while (!env.crd_rr.window_done() && waited < win) begin
        wait_cycles(1);
        waited++;
      end
      wait_traffic();
      drain();
    end
  endtask
endclass
