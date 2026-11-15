// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Asymmetric RP mapping (MAS 3.10), in every T1 test, from the register mirror
// (ASYMMETRIC_RP_PROC_CON, DEST_RP), the S-port pins and the DUT's messages.
//
// Local subordinate port x sends its requests on TX lane lane(x):
// RPx_TX_RP_SEL while ASYMMETRIC_RP_EN is set, x otherwise; lane l's messages
// carry the wire RP DEST_RP.RPl_DEST (MAS 3.10.1). Ports on one lane form a
// merge group: their requests go out as {remapped ID, source port} (the port
// index in the low 1 bit with 2 RPs, 2 bits with 3 or 4), and a port's
// requests of one ID share one remapped ID while any of them is outstanding
// (3.10.5). A port alone on its lane keeps its ID (3.10.4). The mapping is on
// the subordinate ports only: the responses of the DUT's manager ports keep
// their own lane (taken from the RTL; 3.10.4 places AOU_ASYMMETRIC_RP_PROC
// between the subordinate ports and the TX core and says nothing of them).
// The remote die answers on the lane it received the request on, and the DUT
// returns the response to the port the source tag names.
//
// Other checkers translate through this one: req_wire()/rsp_wire() give the
// wire RP of a port's requests and of its manager port's responses,
// req_port()/rsp_port() the port a wire request or a returning response
// belongs to, orig_id() the port's own ID behind a wire ID.
//
// Checks, on every WriteReq and ReadReq the DUT sends:
//   FEAT-R29: it is on the wire RP of a lane some port selects; on a merged
//             lane its low ID bits name a port of that lane; and that port has
//             a request of the direction accepted at its pins and not yet sent
//             whose bytes hold the message's address (and, alone on its lane,
//             whose ID the message carries).
//   FEAT-R30: on a merged lane a port's requests of one ID outstanding share
//             one wire ID, and requests of different IDs do not: otherwise the
//             responses could not find their requester (3.10.5). A wire ID is
//             outstanding from its request until the remote die's WriteResp
//             or last ReadData for it (the remapper's own lifetime).
// Requests a port's pins accepted leave the pending list when their message
// is matched, when the port's response arrives first with no early write
// response possible (a request the DUT answered itself), or on a reset.
//
// On a merge group (MAS 3.10.4), from the same accepted handshakes:
//   FEAT-R31: its writes are serialised: while a port's AW is the group's
//             owner and its W beats have not reached WLAST, no other AW of the
//             group is accepted.
//   FEAT-R32: W beats of the group come only from the AW owner; a beat with no
//             owner is accepted by no port that was granted an AW.
//   FEAT-R33: the owner's ownership ends exactly on its WLAST, on the beat
//             AWLEN+1 of its AW, not early or late.
//   FEAT-R34: ARB_MODE 0 or 3 (round-robin): a port is not granted twice in a
//             row while another port of the group presents the same channel
//             (MAS 3.2.1 Figure 5, the scheme 3.10.4 reuses).
//   FEAT-R36: ARB_MODE 1 (Port QoS): while the granted port has waited less
//             than the starvation timer's threshold, no port of the group with
//             a strictly lower tier is granted on a channel a higher tier
//             presents (MAS 3.2.1's High -> Normal -> Low order, reused by
//             3.10.4). The rule is disabled once the granted port has waited
//             long enough to have been promoted.
// No latency or service interval is checked: 3.2.1 bounds a wait only through
// PRIOR_TIMER, whose promotion also depends on the implementation's prescaler
// phase. Which of several same-tier ports wins, and whether AW or AR goes
// first, are left open.
//
// Coverage: cg_rp_map_req per request, cg_rp_map_cfg per mapping that carried
// traffic, cg_rp_map_arb per merge-group grant, cg_rp_map_owner per change of
// write owner (aou_t1_rp_map_fc_bins.svh).
`uvm_analysis_imp_decl(_rpm_dut)

class aou_t1_rp_map_chk extends uvm_component;
  `uvm_component_utils(aou_t1_rp_map_chk)

  uvm_analysis_imp_rpm_dut #(aou_msg, aou_t1_rp_map_chk) dut_msg_imp;   // L3 ap_rx_msg
  uvm_analysis_imp #(aou_msg, aou_t1_rp_map_chk)         rem_msg_imp;   // L3 ap_tx_msg

  aou_core       rm;
  aou_axi_vif_t  s_vif[];
  aou_l3_model   model;            // link epoch, for cg_rp_map_cfg
  int unsigned   n_rp = 1;
  int unsigned   peer_rp = 1;      // the remote die's RP count
  int unsigned   rp_bytes[4] = '{default: 64};

  typedef struct {
    bit [9:0]  id;
    bit [63:0] lo;      // size-aligned first byte
    bit [64:0] hi;      // one past the last byte (65 bits: the map's top)
  } req_t;
  protected req_t pend[AOU_RP_MAX][2][$];          // [port][rd] accepted, not yet sent
  // Wire ID -> the port's own ID, and the requests outstanding on it.
  protected bit [9:0]    w_orig[AOU_RP_MAX][2][int];
  protected int unsigned w_cnt[AOU_RP_MAX][2][int];
  // Requests sent and not yet answered at the port, per own ID.
  protected int unsigned sent[AOU_RP_MAX][2][int];

  // The mirror, decoded when it changes.
  protected uvm_reg_data_t map_raw = '1;
  protected uvm_reg_data_t dest_raw = '1;
  protected bit            en;
  protected int unsigned   lane_q[AOU_RP_MAX];
  protected int unsigned   dest_q[AOU_RP_MAX];
  protected int unsigned   on_lane[AOU_RP_MAX];   // ports on each lane

  // resolve() result of the last message, which two subscribers may ask for.
  protected aou_msg      last_m;
  protected int          last_x;
  protected bit [9:0]    last_orig;

  int unsigned n_req[2];
  int unsigned n_merged[2];
  int unsigned n_bad;

  // Merge-group arbitration and write serialization (MAS 3.10.4).
  protected int            arb_owner[AOU_RP_MAX];    // write owner per lane, -1 none
  protected int unsigned   arb_left[AOU_RP_MAX];     // beats still owed by the owner
  protected int unsigned   arb_total[AOU_RP_MAX];    // beats of the owner's AW
  protected int unsigned   arb_last[AOU_RP_MAX][2];  // last granted port per lane, channel
  protected int            arb_prev[AOU_RP_MAX];     // port of the last completed write
  protected int unsigned   arb_mode;
  protected int unsigned   arb_prior[AOU_RP_MAX];     // Port QoS tier per port, 3 high
  protected int unsigned   arb_wait[AOU_RP_MAX][2];   // cycles presented, not granted
  protected longint unsigned arb_lim;                 // cycles before promotion is possible
  // Negative control (plan 12.22): the selftest replaces the pin sample with a
  // mask, so the arbitration rules can be driven with illegal sequences while
  // no DUT is involved.
  protected bit                  neg_mode;
  protected bit [AOU_RP_MAX-1:0] neg_present[2];
  int unsigned n_arb_g[2];
  int unsigned n_arb_merged;
  int unsigned n_arb_cont;
  int unsigned n_serials;
  int unsigned n_whs;
  bit require_merge_observation = 1'b0;
  protected bit seen_arb_source[AOU_RP_MAX];
  protected bit seen_write_source[AOU_RP_MAX];

  protected int cv_dir;
  protected int cv_port;
  protected int cv_lane;
  protected int cv_route;
  protected int cv_shape;
  protected int cv_pair;
  protected int cv_merge;
  protected int cv_width;
  protected int cv_wide;
  protected uvm_reg_data_t cov_map = '1;
  protected uvm_reg_data_t cov_dest = '1;
  protected int unsigned   cov_epoch = '1;
  protected int cv_arb_mode;
  protected int cv_arb_ports;
  protected int cv_arb_cont;
  protected int cv_arb_port;
  protected int cv_arb_owner;
  protected int cv_arb_next;

  covergroup cg_rp_map_req;
    cp_dir: coverpoint cv_dir {
      `AOU_T1_RPMAP_FC_DIR(AOU_FC_CG)
    }
    cp_port: coverpoint cv_port {
      `AOU_T1_RPMAP_FC_PORT(AOU_FC_CG)
    }
    cp_lane: coverpoint cv_lane {
      `AOU_T1_RPMAP_FC_LANE(AOU_FC_CG)
    }
    cp_route: coverpoint cv_route {
      `AOU_T1_RPMAP_FC_ROUTE(AOU_FC_CG)
    }
    x_target: cross cp_port, cp_lane;
    x_route_dir: cross cp_route, cp_dir;
  endgroup
  aou_fc_group fc_req;

  covergroup cg_rp_map_cfg;
    cp_shape: coverpoint cv_shape {
      `AOU_T1_RPMAP_FC_SHAPE(AOU_FC_CG)
    }
    cp_pair: coverpoint cv_pair {
      `AOU_T1_RPMAP_FC_PAIR(AOU_FC_CG)
    }
    cp_merge: coverpoint cv_merge {
      `AOU_T1_RPMAP_FC_MERGE(AOU_FC_CG)
    }
    cp_width: coverpoint cv_width {
      `AOU_T1_RPMAP_FC_WIDTH(AOU_FC_CG)
    }
    cp_wide: coverpoint cv_wide {
      `AOU_T1_RPMAP_FC_WIDE(AOU_FC_CG)
    }
    x_pair_merge: cross cp_pair, cp_merge;
  endgroup
  aou_fc_group fc_cfg;

  covergroup cg_rp_map_arb;
    cp_mode: coverpoint cv_arb_mode {
      `AOU_T1_RPMAP_FC_ARB_MODE(AOU_FC_CG)
    }
    cp_ports: coverpoint cv_arb_ports {
      `AOU_T1_RPMAP_FC_ARB_PORTS(AOU_FC_CG)
    }
    cp_contend: coverpoint cv_arb_cont {
      `AOU_T1_RPMAP_FC_ARB_CONT(AOU_FC_CG)
    }
    cp_winner: coverpoint cv_arb_port {
      `AOU_T1_RPMAP_FC_ARB_PORT(AOU_FC_CG)
    }
    x_mode_winner: cross cp_mode, cp_winner;
  endgroup
  aou_fc_group fc_arb;

  covergroup cg_rp_map_owner;
    cp_owner: coverpoint cv_arb_owner {
      `AOU_T1_RPMAP_FC_ARB_PORT(AOU_FC_CG)
    }
    cp_next: coverpoint cv_arb_next {
      `AOU_T1_RPMAP_FC_ARB_PORT(AOU_FC_CG)
    }
    x_owner_next: cross cp_owner, cp_next;
  endgroup
  aou_fc_group fc_owner;

  function new(string name, uvm_component parent);
    aou_fc_db db;
    aou_fc_point p;
    bit fresh;
    super.new(name, parent);
    dut_msg_imp = new("dut_msg_imp", this);
    rem_msg_imp = new("rem_msg_imp", this);
    cg_rp_map_req = new();
    cg_rp_map_cfg = new();
    cg_rp_map_arb = new();
    cg_rp_map_owner = new();
    foreach (arb_owner[l]) begin
      arb_owner[l] = -1;
      arb_prev[l] = -1;
    end
    foreach (arb_last[l, d]) arb_last[l][d] = '1;
    db = aou_fc_db::get();
    fc_req = db.group("env.cg_rp_map_req", fresh);
    if (fresh) begin
      p = fc_req.cp("cp_dir"); `AOU_T1_RPMAP_FC_DIR(AOU_FC_REG)
      p = fc_req.cp("cp_port"); `AOU_T1_RPMAP_FC_PORT(AOU_FC_REG)
      p = fc_req.cp("cp_lane"); `AOU_T1_RPMAP_FC_LANE(AOU_FC_REG)
      p = fc_req.cp("cp_route"); `AOU_T1_RPMAP_FC_ROUTE(AOU_FC_REG)
      void'(fc_req.add_cross("x_target", "cp_port cp_lane"));
      void'(fc_req.add_cross("x_route_dir", "cp_route cp_dir"));
    end
    fc_cfg = db.group("env.cg_rp_map_cfg", fresh);
    if (fresh) begin
      p = fc_cfg.cp("cp_shape"); `AOU_T1_RPMAP_FC_SHAPE(AOU_FC_REG)
      p = fc_cfg.cp("cp_pair"); `AOU_T1_RPMAP_FC_PAIR(AOU_FC_REG)
      p = fc_cfg.cp("cp_merge"); `AOU_T1_RPMAP_FC_MERGE(AOU_FC_REG)
      p = fc_cfg.cp("cp_width"); `AOU_T1_RPMAP_FC_WIDTH(AOU_FC_REG)
      p = fc_cfg.cp("cp_wide"); `AOU_T1_RPMAP_FC_WIDE(AOU_FC_REG)
      void'(fc_cfg.add_cross("x_pair_merge", "cp_pair cp_merge"));
    end
    fc_arb = db.group("env.cg_rp_map_arb", fresh);
    if (fresh) begin
      p = fc_arb.cp("cp_mode"); `AOU_T1_RPMAP_FC_ARB_MODE(AOU_FC_REG)
      p = fc_arb.cp("cp_ports"); `AOU_T1_RPMAP_FC_ARB_PORTS(AOU_FC_REG)
      p = fc_arb.cp("cp_contend"); `AOU_T1_RPMAP_FC_ARB_CONT(AOU_FC_REG)
      p = fc_arb.cp("cp_winner"); `AOU_T1_RPMAP_FC_ARB_PORT(AOU_FC_REG)
      void'(fc_arb.add_cross("x_mode_winner", "cp_mode cp_winner"));
      fc_arb.plan("12.22", "cp_ports", "three");
      fc_arb.plan("12.22", "cp_contend", "two|more");
      fc_arb.plan("12.22", "cp_winner", "port[0]|port[1]|port[2]");
      fc_arb.plan("12.22", "cp_mode", "rr");
    end
    fc_owner = db.group("env.cg_rp_map_owner", fresh);
    if (fresh) begin
      p = fc_owner.cp("cp_owner"); `AOU_T1_RPMAP_FC_ARB_PORT(AOU_FC_REG)
      p = fc_owner.cp("cp_next"); `AOU_T1_RPMAP_FC_ARB_PORT(AOU_FC_REG)
      void'(fc_owner.add_cross("x_owner_next", "cp_owner cp_next"));
      fc_owner.plan("12.22", "x_owner_next", "port[0],port[1]");
    end
  endfunction

  // ---- The mapping, from the mirror -------------------------------------
  protected function void decode();
    uvm_reg_data_t m;
    uvm_reg_data_t d;
    if (rm == null) begin
      foreach (lane_q[x]) begin
        lane_q[x] = x;
        dest_q[x] = x;
        on_lane[x] = (x < n_rp) ? 1 : 0;
      end
      return;
    end
    m = rm.asymmetric_rp_proc_con.get_mirrored_value();
    d = rm.dest_rp.get_mirrored_value();
    if (m != map_raw || d != dest_raw) begin
      map_raw = m;
      dest_raw = d;
      en = m[0] && n_rp >= 2;
      foreach (lane_q[x]) begin
        lane_q[x] = en ? int'(m[1 + 2 * x +: 2]) : x;
        dest_q[x] = int'(d[4 * x +: 2]);
        on_lane[x] = 0;
      end
      for (int unsigned x = 0; x < n_rp; x++) on_lane[lane_q[x]]++;
    end
    decode_arb();
  endfunction

  // PRIOR_RP_AXI selects the merge group's arbitration scheme (MAS 3.10.4
  // uses the TX core's fields for its first stage): round-robin (FEAT-R34)
  // and Port QoS (FEAT-R36). The tier of a port is RPn_PRIOR, where 0 reads
  // as 1 (Low). PRIOR_TIMER bounds how long a request waits before promotion,
  // so a strict-tier grant is only a violation while the granted port has
  // waited less than THRESHOLD x (RESOLUTION + 1) cycles.
  protected function void decode_arb();
    uvm_reg_data_t pv;
    uvm_reg_data_t t;
    int unsigned   pri;
    if (rm == null) return;
    pv = rm.prior_rp_axi.get_mirrored_value();
    arb_mode = int'(pv[1:0]);
    foreach (arb_prior[r]) begin
      if (r >= n_rp) begin
        arb_prior[r] = 0;
        continue;
      end
      pri = int'(pv[4 + 4 * r +: 2]);
      arb_prior[r] = (pri == 0) ? 1 : pri;
    end
    t = rm.prior_timer.get_mirrored_value();
    arb_lim = (t[15:0] == 16'h0) ? 0 :
              longint'(t[15:0]) * (longint'(t[31:16]) + 1);
  endfunction

  function bit enabled();
    decode();
    return en;
  endfunction

  function int unsigned lane(int unsigned x);
    decode();
    return lane_q[x];
  endfunction

  // Port x shares its lane with another port.
  function bit merged(int unsigned x);
    decode();
    return x < n_rp && on_lane[lane_q[x]] > 1;
  endfunction

  // Wire RP of port x's requests, and of its manager port's responses.
  function int unsigned req_wire(int unsigned x);
    decode();
    return dest_q[lane_q[x]];
  endfunction

  function int unsigned rsp_wire(int unsigned x);
    decode();
    return dest_q[x];
  endfunction

  // The port of lane l a message with wire ID wid belongs to; -1: no port
  // selects l, or the source tag names a port that is not on it.
  function int rsp_port(int unsigned l, bit [9:0] wid);
    int unsigned t;
    decode();
    if (l >= AOU_RP_MAX || on_lane[l] == 0) return -1;
    if (on_lane[l] == 1) begin
      for (int unsigned x = 0; x < n_rp; x++) if (lane_q[x] == l) return x;
      return -1;
    end
    t = (n_rp == 2) ? int'(wid[0]) : int'(wid[1:0]);
    return (t < n_rp && lane_q[t] == l) ? int'(t) : -1;
  endfunction

  // The lane in use whose DEST_RP is wire RP w; -1 when none is.
  function int lane_of_wire(int unsigned w);
    decode();
    for (int unsigned l = 0; l < AOU_RP_MAX; l++)
      if (on_lane[l] != 0 && dest_q[l] == w) return l;
    return -1;
  endfunction

  function int req_port(int unsigned w, bit [9:0] wid);
    int l = lane_of_wire(w);
    return (l < 0) ? -1 : rsp_port(l, wid);
  endfunction

  // Port x's own ID behind wire ID wid (the same ID unless x is merged).
  function bit [9:0] orig_id(int unsigned x, bit rd, bit [9:0] wid);
    if (!merged(x) || !w_orig[x][rd].exists(int'(wid))) return wid;
    return w_orig[x][rd][int'(wid)];
  endfunction

  // ---- Requests ---------------------------------------------------------
  // The port and own ID of DUT request m (x = -1: none found, reported once).
  function void resolve(aou_msg m, output int x, output bit [9:0] orig);
    if (m == last_m) begin
      x = last_x;
      orig = last_orig;
      return;
    end
    last_m = m;
    take_req(m, x, orig);
    last_x = x;
    last_orig = orig;
  endfunction

  function void write_rpm_dut(aou_msg m);
    int x;
    bit [9:0] orig;
    if (m.msg_type inside {AOU_MT_WREQ, AOU_MT_RREQ}) resolve(m, x, orig);
  endfunction

  // ---- Negative control (plan 12.22) -----------------------------------
  protected function void neg_reset();
    foreach (arb_owner[i]) begin
      arb_owner[i] = -1;
      arb_left[i] = 0;
      arb_total[i] = 0;
      arb_prev[i] = -1;
    end
    for (int unsigned i = 0; i < AOU_RP_MAX; i++) begin
      for (int unsigned d = 0; d < 2; d++) begin
        arb_last[i][d] = '1;
        arb_wait[i][d] = 0;
      end
      neg_present[0][i] = 1'b0;
      neg_present[1][i] = 1'b0;
    end
  endfunction

  // Feeds the arbitration state machine the sequence each rule forbids, one
  // case per rule, so a rule that can no longer fire is visible. Only checker
  // state is used: no DUT, no port sample, no RTL. Each case reports once
  // through bad(), and a caller that expects exactly one report per rule turns
  // a silent rule into a failed selftest.
  function void neg_selftest();
    int unsigned      l;
    int unsigned      a;
    int unsigned      b;
    int unsigned      mode_save;
    longint unsigned  lim_save;
    int unsigned      pri_save[AOU_RP_MAX];
    if (!en || n_rp < 3) begin
      `uvm_info(get_type_name(), "negative control needs an enabled merge group", UVM_LOW)
      return;
    end
    l = lane_q[0];
    a = 0;
    b = 1;
    for (int unsigned x = 1; x < n_rp; x++)
      if (on_lane[lane_q[x]] >= 2) begin
        l = lane_q[x];
        a = x;
        break;
      end
    for (int unsigned x = a + 1; x < n_rp; x++) if (lane_q[x] == l) b = x;
    if (on_lane[l] < 2 || lane_q[b] != l || a == b) begin
      `uvm_info(get_type_name(), "negative control found no merged pair", UVM_LOW)
      return;
    end
    mode_save = arb_mode;
    lim_save = arb_lim;
    foreach (arb_prior[i]) pri_save[i] = arb_prior[i];
    neg_mode = 1'b1;
    // FEAT-R31: another port's AW while the owner's write is not finished.
    neg_reset();
    neg_present[0][b] = 1'b1;
    arb_aw(a, 8'd1);
    arb_aw(b, 8'd1);
    // FEAT-R32: a W beat from a port that was not granted the AW.
    neg_reset();
    arb_aw(a, 8'd1);
    arb_w(b, 1'b0);
    // FEAT-R33: WLAST while the AW still owes beats (an AWLEN of 2 covers 3).
    neg_reset();
    arb_aw(a, 8'd2);
    arb_w(a, 1'b0);
    arb_w(a, 1'b1);
    // FEAT-R34: the same port granted twice while another presents.
    neg_reset();
    arb_mode = 0;
    neg_present[0][a] = 1'b1;
    neg_present[0][b] = 1'b1;
    arb_last[l][0] = int'(b);
    arb_grant(b, 1'b0);
    // FEAT-R36: a lower tier granted while a higher tier presents, with the
    // promotion timer unable to have promoted it.
    neg_reset();
    arb_mode = 1;
    arb_lim = 1000;
    arb_prior[a] = 3;
    arb_prior[b] = 1;
    neg_present[0][a] = 1'b1;
    arb_wait[b][0] = 0;
    arb_grant(b, 1'b0);
    neg_mode = 1'b0;
    arb_mode = mode_save;
    arb_lim = lim_save;
    foreach (arb_prior[i]) arb_prior[i] = pri_save[i];
    neg_reset();
  endfunction

  protected function void bad(string rule, string msg);
    n_bad++;
    aou_rule_log::fire(rule, get_type_name());
    `uvm_error(get_type_name(), $sformatf("%s: %s (ASYMMETRIC_RP_PROC_CON %0h, DEST_RP %0h)", rule,
                                          msg, map_raw, dest_raw))
  endfunction

  protected function void take_req(aou_msg m, output int x, output bit [9:0] orig);
    aou_msg_req q;
    bit rd = m.msg_type == AOU_MT_RREQ;
    int l;
    int hit = -1;
    string what;
    x = -1;
    orig = '0;
    if (!$cast(q, m)) return;
    orig = q.id;
    what = $sformatf("%s on wire RP%0d ID %0h addr %0h", rd ? "ReadReq" : "WriteReq", m.rp, q.id,
                     q.addr);
    aou_rule_log::check("FEAT-R29", get_type_name());
    l = lane_of_wire(int'(m.rp));
    if (l < 0) begin
      bad("FEAT-R29", {what, ": no port's lane sends to that RP"});
      return;
    end
    x = rsp_port(l, q.id);
    if (x < 0) begin
      bad("FEAT-R29", $sformatf("%s: lane %0d is merged and the ID's source tag names %s", what,
                                l, "no port of it"));
      return;
    end
    foreach (pend[x][rd][i]) begin
      if (q.addr < pend[x][rd][i].lo || 65'(q.addr) >= pend[x][rd][i].hi) continue;
      if (on_lane[l] == 1 && pend[x][rd][i].id != q.id) continue;
      if (on_lane[l] > 1 && !id_free(x, rd, q.id, pend[x][rd][i].id)) continue;
      hit = i;
      break;
    end
    if (hit < 0) begin
      bad("FEAT-R29", $sformatf("%s: port %0d (lane %0d) has no such %s pending (%0d pending)",
                                what, x, l, rd ? "read" : "write", pend[x][rd].size()));
      x = -1;
      return;
    end
    orig = pend[x][rd][hit].id;
    pend[x][rd].delete(hit);
    if (!sent[x][rd].exists(int'(orig))) sent[x][rd][int'(orig)] = 0;
    sent[x][rd][int'(orig)]++;
    n_req[rd]++;
    if (on_lane[l] > 1) begin
      n_merged[rd]++;
      bind_wid(x, rd, q.id, orig, what);
    end
    sample_req(x, rd);
  endfunction

  // Wire ID wid may carry port x's ID o: wid is free or bound to o.
  protected function bit id_free(int unsigned x, bit rd, bit [9:0] wid, bit [9:0] o);
    return !w_cnt[x][rd].exists(int'(wid)) || w_cnt[x][rd][int'(wid)] == 0 ||
           w_orig[x][rd][int'(wid)] == o;
  endfunction

  // FEAT-R30: a port's ID o maps to one wire ID while outstanding.
  protected function void bind_wid(int unsigned x, bit rd, bit [9:0] wid, bit [9:0] o, string what);
    aou_rule_log::check("FEAT-R30", get_type_name());
    foreach (w_cnt[x][rd][k]) begin
      if (w_cnt[x][rd][k] != 0 && k != int'(wid) && w_orig[x][rd][k] == o)
        bad("FEAT-R30", $sformatf("%s: port %0d's ID %0h is outstanding as wire ID %0h too", what,
                                  x, o, k));
    end
    if (!w_cnt[x][rd].exists(int'(wid))) w_cnt[x][rd][int'(wid)] = 0;
    w_orig[x][rd][int'(wid)] = o;
    w_cnt[x][rd][int'(wid)]++;
  endfunction

  // The remote die's WriteResp or last ReadData ends one request of its wire ID.
  function void write(aou_msg m);
    aou_msg_wresp b;
    aou_msg_rdata d;
    int x;
    bit rd;
    bit [9:0] wid;
    if ($cast(b, m)) begin
      rd = 1'b0;
      wid = b.id;
    end else if ($cast(d, m) && d.last) begin
      rd = 1'b1;
      wid = d.id;
    end else begin
      return;
    end
    x = rsp_port(int'(m.rp), wid);
    if (x < 0 || !w_cnt[x][rd].exists(int'(wid))) return;
    if (w_cnt[x][rd][int'(wid)] > 0) w_cnt[x][rd][int'(wid)]--;
  endfunction

  protected function bit early_en(int unsigned x);
    uvm_reg rg;
    if (rm == null) return 1'b0;
    rg = rm.get_reg_by_name($sformatf("write_early_response_rp%0d", x));
    return rg != null && rg.get_field_by_name("early_bresp_en").get_mirrored_value() != 0;
  endfunction

  // The response to port x's oldest request of the ID: one already sent, or
  // else one the DUT answered itself, which will not be sent. An early write
  // response (EARLY_BRESP_EN) may come before the write is sent: then the
  // write stays pending.
  protected function void answered(int unsigned x, bit rd, bit [9:0] id);
    if (sent[x][rd].exists(int'(id)) && sent[x][rd][int'(id)] > 0) begin
      sent[x][rd][int'(id)]--;
      return;
    end
    if (!rd && early_en(x)) return;
    foreach (pend[x][rd][i]) begin
      if (pend[x][rd][i].id == id) begin
        pend[x][rd].delete(i);
        return;
      end
    end
  endfunction

  protected function req_t req_of(bit [9:0] id, bit [63:0] addr, bit [7:0] len, bit [2:0] size);
    req_t r;
    r.id = id;
    r.lo = addr & ~((64'd1 << size) - 64'd1);
    r.hi = 65'(r.lo) + ((65'(len) + 65'd1) << size);
    return r;
  endfunction

  // One sample per core cycle for every port: the merge-group checks compare
  // the ports of one lane in the same cycle.
  task run_phase(uvm_phase phase);
    if (s_vif.size() == 0) return;
    forever begin
      @(s_vif[0].mon_cb);
      decode();
      for (int unsigned x = 0; x < s_vif.size() && x < AOU_RP_MAX; x++) watch(x);
    end
  endtask

  protected function void watch(int unsigned x);
    bit g_aw;
    bit g_ar;
    if (s_vif[x].mon_cb.resetn !== 1'b1) begin
      flush_port(x);
      for (int d = 0; d < 2; d++) arb_wait[x][d] = 0;
      return;
    end
    g_aw = (s_vif[x].mon_cb.awvalid === 1'b1 && s_vif[x].mon_cb.awready === 1'b1);
    g_ar = (s_vif[x].mon_cb.arvalid === 1'b1 && s_vif[x].mon_cb.arready === 1'b1);
    if (g_aw) begin
      pend[x][0].push_back(req_of(s_vif[x].mon_cb.awid, s_vif[x].mon_cb.awaddr,
                                  s_vif[x].mon_cb.awlen, s_vif[x].mon_cb.awsize));
      arb_aw(x, s_vif[x].mon_cb.awlen);
    end
    if (g_ar) begin
      pend[x][1].push_back(req_of(s_vif[x].mon_cb.arid, s_vif[x].mon_cb.araddr,
                                  s_vif[x].mon_cb.arlen, s_vif[x].mon_cb.arsize));
      arb_grant(x, 1'b1);
    end
    if (s_vif[x].mon_cb.wvalid === 1'b1 && s_vif[x].mon_cb.wready === 1'b1)
      arb_w(x, s_vif[x].mon_cb.wlast === 1'b1);
    if (s_vif[x].mon_cb.bvalid === 1'b1 && s_vif[x].mon_cb.bready === 1'b1)
      answered(x, 1'b0, s_vif[x].mon_cb.bid);
    if (s_vif[x].mon_cb.rvalid === 1'b1 && s_vif[x].mon_cb.rready === 1'b1 &&
        s_vif[x].mon_cb.rlast === 1'b1)
      answered(x, 1'b1, s_vif[x].mon_cb.rid);
    // Port QoS waits: how long each channel's request has been presented
    // without being granted. FEAT-R36 disables itself once this reaches the
    // promotion threshold, so the count only has to be right below it.
    for (int d = 0; d < 2; d++) begin
      if (d == 0 ? g_aw : g_ar) arb_wait[x][d] = 0;
      else if ((d == 0 ? s_vif[x].mon_cb.awvalid : s_vif[x].mon_cb.arvalid) === 1'b1 &&
               arb_wait[x][d] < '1) arb_wait[x][d]++;
    end
  endfunction

  // ---- Merge-group arbitration and write serialization (MAS 3.10.4) -----
  // AW accepted at port x: it takes the lane's write ownership unless the
  // previous owner has not reached WLAST (FEAT-R31), then competes for the
  // channel (FEAT-R34).
  protected function void arb_aw(int unsigned x, bit [7:0] len);
    int unsigned l;
    if (!en || x >= n_rp) return;
    l = lane_q[x];
    if (on_lane[l] < 2) return;
    n_arb_merged++;
    aou_rule_log::check("FEAT-R31", get_type_name());
    aou_rule_log::check("FEAT-R33", get_type_name());
    if (arb_owner[l] >= 0)
      bad("FEAT-R31", $sformatf({"port %0d's AW accepted on lane %0d while port %0d's write ",
                                 "still owes %0d of %0d W beats"}, x, l, arb_owner[l], arb_left[l],
                                arb_total[l]));
    // A violation cannot be repaired; taking the new AW keeps one report per
    // violation instead of one per following beat.
    arb_owner[l] = int'(x);
    arb_left[l] = int'(len) + 1;
    arb_total[l] = int'(len) + 1;
    arb_grant(x, 1'b0);
  endfunction

  // One W beat at port x on its lane.
  protected function void arb_w(int unsigned x, bit last);
    int unsigned l;
    if (!en || x >= n_rp) return;
    l = lane_q[x];
    if (on_lane[l] < 2) return;
    n_whs++;
    aou_rule_log::check("FEAT-R32", get_type_name());
    aou_rule_log::check("FEAT-R33", get_type_name());
    if (arb_owner[l] < 0) begin
      bad("FEAT-R32", $sformatf("W beat from port %0d on lane %0d with no AW owner", x, l));
      return;
    end
    if (arb_owner[l] != int'(x)) begin
      bad("FEAT-R32", $sformatf("W beat from port %0d on lane %0d, whose AW owner is port %0d",
                                x, l, arb_owner[l]));
      return;
    end
    if (arb_left[l] == 0) begin
      bad("FEAT-R33", $sformatf("W beat from port %0d on lane %0d after all %0d beats", x, l,
                                arb_total[l]));
      arb_owner[l] = -1;
      return;
    end
    arb_left[l]--;
    if (arb_left[l] == 0 && !last) begin
      bad("FEAT-R33", $sformatf({"port %0d's AW on lane %0d covers %0d beats but WLAST was not ",
                                 "on the last"}, x, l, arb_total[l]));
      arb_owner[l] = -1;
      return;
    end
    if (arb_left[l] != 0 && last) begin
      bad("FEAT-R33", $sformatf("WLAST from port %0d on lane %0d after %0d of %0d beats", x, l,
                                arb_total[l] - arb_left[l], arb_total[l]));
      arb_owner[l] = -1;
      return;
    end
    if (last) begin
      arb_owner[l] = -1;
      arb_prev[l] = int'(x);
      n_serials++;
      seen_write_source[x] = 1'b1;
    end
  endfunction

  // Whether port y presents channel rd. The selftest supplies the answer
  // instead of sampling the port pins.
  protected function bit port_presents(int unsigned y, bit rd);
    if (neg_mode) return (y < AOU_RP_MAX) && (neg_present[rd][y] === 1'b1);
    if (y >= s_vif.size()) return 1'b0;
    return (rd ? s_vif[y].mon_cb.arvalid : s_vif[y].mon_cb.awvalid) === 1'b1;
  endfunction

  // Ports of lane l presenting the channel this cycle.
  protected function int unsigned presenting(int unsigned l, bit rd);
    int n = 0;
    for (int unsigned x = 0; x < n_rp && x < AOU_RP_MAX; x++) begin
      if (lane_q[x] != l) continue;
      if (port_presents(x, rd)) n++;
    end
    return n;
  endfunction

  // A grant of the channel to port x on its lane (FEAT-R34).
  protected function void arb_grant(int unsigned x, bit rd);
    int unsigned l = lane_q[x];
    int unsigned cont;
    if (on_lane[l] < 2) return;
    n_arb_g[rd]++;
    seen_arb_source[x] = 1'b1;
    cont = presenting(l, rd);
    if (cont > 1) n_arb_cont++;
    if (arb_mode == 0 || arb_mode == 3) begin
      aou_rule_log::check("FEAT-R34", get_type_name());
      if (arb_last[l][rd] == x && cont > 1)
        bad("FEAT-R34", $sformatf(
            {"port %0d granted twice in a row on lane %0d's %s while %0d ports of the lane ",
             "present a request (ARB_MODE %0d)"}, x, l, rd ? "AR" : "AW", cont, arb_mode));
    end
    if (arb_mode == 1 && arb_lim > 0) begin
      aou_rule_log::check("FEAT-R36", get_type_name());
      if (longint'(arb_wait[x][rd]) < arb_lim)
        for (int unsigned y = 0; y < n_rp; y++) begin
          if (y == x || lane_q[y] != l) continue;
          if (!port_presents(int'(y), rd)) continue;
          if (arb_prior[y] <= arb_prior[x]) continue;
          bad("FEAT-R36", $sformatf(
              {"port %0d (tier %0d) granted on lane %0d's %s while port %0d (tier %0d) ",
               "presents and the promotion timer cannot have promoted it (wait %0d < %0d)"},
              x, arb_prior[x], l, rd ? "AR" : "AW", y, arb_prior[y], arb_wait[x][rd], arb_lim));
        end
    end
    arb_last[l][rd] = x;
    sample_arb(x, l, rd, cont);
  endfunction

  protected function void sample_arb(int unsigned x, int unsigned l, bit rd, int unsigned cont);
    if (neg_mode) return;   // the selftest's synthetic grants are not coverage
    cv_arb_mode = int'(arb_mode);
    cv_arb_ports = int'(on_lane[l]);
    cv_arb_cont = int'(cont);
    cv_arb_port = int'(x);
    cg_rp_map_arb.sample();
    fc_arb.sample(cv_arb_mode, cv_arb_ports, cv_arb_cont, cv_arb_port);
    if (rd || arb_prev[l] < 0) return;
    cv_arb_owner = arb_prev[l];
    cv_arb_next = int'(x);
    arb_prev[l] = -1;
    cg_rp_map_owner.sample();
    fc_owner.sample(cv_arb_owner, cv_arb_next);
  endfunction

  protected function void flush_port(int unsigned x);
    foreach (pend[x][rd]) begin
      pend[x][rd].delete();
      w_cnt[x][rd].delete();
      w_orig[x][rd].delete();
      sent[x][rd].delete();
    end
    if (x >= AOU_RP_MAX) return;
    if (en) begin
      int unsigned l = lane_q[x];
      // All S-port resetn pins share the core reset. Flush the lane's shared
      // state so a pre-reset owner/grant cannot constrain post-reset checks.
      arb_owner[l] = -1;
      arb_left[l] = 0;
      arb_total[l] = 0;
      arb_last[l][0] = '1;
      arb_last[l][1] = '1;
      arb_prev[l] = -1;
    end
  endfunction

  // Reset contract: every transaction is gone and the remap tables empty.
  function void reset_flush();
    for (int unsigned x = 0; x < AOU_RP_MAX; x++) flush_port(x);
    last_m = null;
  endfunction

  // ---- Coverage ---------------------------------------------------------
  protected function void sample_req(int unsigned x, bit rd);
    cv_dir = int'(rd);
    cv_port = x;
    cv_lane = lane_q[x];
    cv_route = !en ? 0 : merged(x) ? 3 : (lane_q[x] == x) ? 1 : 2;
    cg_rp_map_req.sample();
    fc_req.sample(cv_dir, cv_port, cv_lane, cv_route);
    if (map_raw == cov_map && dest_raw == cov_dest && (model == null ||
        model.lnk.epoch == cov_epoch)) return;
    cov_map = map_raw;
    cov_dest = dest_raw;
    if (model != null) cov_epoch = model.lnk.epoch;
    sample_cfg();
  endfunction

  protected function void sample_cfg();
    int unsigned groups = 0;
    int unsigned big = 0;
    bit moved = 1'b0;
    bit mixed = 1'b0;
    cv_wide = 0;
    for (int unsigned l = 0; l < AOU_RP_MAX; l++) begin
      if (on_lane[l] > 1) groups++;
      if (on_lane[l] > big) big = on_lane[l];
    end
    for (int unsigned x = 0; x < n_rp; x++) begin
      if (lane_q[x] != x) moved = 1'b1;
      if (en && lane_q[x] < n_rp && rp_bytes[x] > rp_bytes[lane_q[x]]) cv_wide = 1;
      for (int unsigned y = 0; y < n_rp; y++)
        if (y != x && lane_q[y] == lane_q[x] && rp_bytes[y] != rp_bytes[x]) mixed = 1'b1;
    end
    if (!en) cv_shape = (map_raw[8:1] == 8'he4) ? 0 : 1;
    else if (groups == 2) cv_shape = 7;
    else if (groups == 1) cv_shape = 2 + big;
    else cv_shape = moved ? 3 : 2;
    cv_pair = 10 * int'(n_rp) + int'(peer_rp);
    cv_merge = int'(groups != 0);
    cv_width = (groups == 0) ? 0 : mixed ? 2 : 1;
    cg_rp_map_cfg.sample();
    fc_cfg.sample(cv_shape, cv_pair, cv_merge, cv_width, cv_wide);
  endfunction

  function void report_phase(uvm_phase phase);
    decode();
    `uvm_info(get_type_name(), $sformatf(
              {"mapping %s (ASYMMETRIC_RP_PROC_CON %0h, DEST_RP %0h): %0d WriteReq (%0d merged), ",
               "%0d ReadReq (%0d merged) matched to their ports, %0d errors"},
              en ? "enabled" : "disabled", map_raw, dest_raw, n_req[0], n_merged[0], n_req[1],
              n_merged[1], n_bad), UVM_LOW)
    `uvm_info(get_type_name(), $sformatf(
              {"merge groups: %0d AW and %0d AR grants (%0d merged, %0d contended), %0d W beats, ",
              "%0d completed writes, ARB_MODE %0d"},
              n_arb_g[0], n_arb_g[1], n_arb_merged, n_arb_cont, n_whs, n_serials, arb_mode),
              UVM_LOW)
  endfunction

  // A deterministic +rp_map scenario declares that a merge group, contested
  // grants, multiple winners and writes from multiple source ports are part of
  // the test intent. Keep this assertion conditional: the randomized mapping
  // used by other tests is allowed to produce only singletons.
  function void check_phase(uvm_phase phase);
    int unsigned n_winners = 0;
    int unsigned n_writers = 0;
    super.check_phase(phase);
    if (!require_merge_observation) return;
    foreach (seen_arb_source[x]) if (seen_arb_source[x]) n_winners++;
    foreach (seen_write_source[x]) if (seen_write_source[x]) n_writers++;
    aou_rule_log::check("FEAT-R35", get_type_name());
    if (n_arb_merged == 0 || n_arb_cont == 0 || n_serials == 0 ||
        n_winners < 2 || n_writers < 2) begin
      aou_rule_log::fire("FEAT-R35", get_type_name());
      `uvm_error(get_type_name(), $sformatf(
          {"FEAT-R35: deterministic merge scenario not exercised: merged %0d, contended %0d, ",
           "writes %0d, arbitration sources %0d, write sources %0d"},
          n_arb_merged, n_arb_cont, n_serials, n_winners, n_writers))
    end
  endfunction
endclass
