// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

typedef struct packed {
  logic [31:0] epoch;
  logic [31:0] sequence_id;
  logic [1:0] source_rp;
  logic [1:0] wire_rp;
  logic [9:0] bid;
  logic [1:0] bresp;
} aou_b_identity_record_t;

typedef struct packed {
  logic [1:0] wire_rp;
  logic [9:0] bid;
  logic [1:0] bresp;
} aou_b_identity_wire_t;

typedef enum int {
  AOU_B_ID_MATCH,
  AOU_B_ID_UNEXPECTED,
  AOU_B_ID_MISMATCH,
  AOU_B_ID_PENDING
} aou_b_identity_result_e;

function automatic bit aou_b_identity_tuple_matches(
    input aou_b_identity_record_t expected,
    input aou_b_identity_wire_t actual);
  return {expected.wire_rp, expected.bid, expected.bresp} ===
         {actual.wire_rp, actual.bid, actual.bresp};
endfunction

// Small pure model shared by the real decoded-message checker and its
// isolated negative-control test. Expected records are ordered producer events.
class aou_b_identity_matcher;
  aou_b_identity_record_t expected[$];
  int unsigned next_sequence;

  function void reset();
    expected.delete();
    next_sequence = 0;
  endfunction

  // Start a new reset/link-loss epoch without restarting the interface-wide
  // producer sequence. Any expected records at the boundary are interrupted,
  // not delivered, and must be reported by the caller before they are cleared.
  function int unsigned begin_epoch();
    int unsigned pending = expected.size();
    expected.delete();
    return pending;
  endfunction

  function void push(input aou_b_identity_record_t record);
    expected.push_back(record);
  endfunction

  function aou_b_identity_result_e observe(input aou_b_identity_wire_t actual,
                                            output aou_b_identity_record_t matched);
    bit sequence_matches;
    matched = '0;
    if (expected.size() == 0) return AOU_B_ID_UNEXPECTED;
    matched = expected.pop_front();
    sequence_matches = matched.sequence_id == next_sequence;
    next_sequence++;
    if (!sequence_matches || !aou_b_identity_tuple_matches(matched, actual))
      return AOU_B_ID_MISMATCH;
    return AOU_B_ID_MATCH;
  endfunction

  function aou_b_identity_result_e finish();
    return expected.size() == 0 ? AOU_B_ID_MATCH : AOU_B_ID_PENDING;
  endfunction
endclass

// Compares accepted global-B/ring insertion identities against decoded L3
// WriteResp messages. The interface queue is FIFO ordered; ap_rx_msg is emitted
// only after the downstream FDI flit is transferred and decoded.
class aou_b_identity_chk extends uvm_subscriber #(aou_msg);
  `uvm_component_utils(aou_b_identity_chk)

  virtual aou_b_combiner_if bci;
  int unsigned decoded_count;
  int unsigned distinct_count;
  bit [3:0] source_rp_mask;
  aou_b_identity_record_t observed[$];
  aou_b_identity_matcher matcher;
  bit have_epoch;
  logic [31:0] qualification_epoch;
  int unsigned s_dg04_event;
  int unsigned s_dg04_rp;
  aou_fc_group fc_dg04;

  covergroup cg_dg04;
    cp_event: coverpoint s_dg04_event {
      `AOU_T1_DG04_FC_EVENT(AOU_FC_CG)
    }
    cp_source_rp: coverpoint s_dg04_rp {
      `AOU_T1_DG04_FC_RP(AOU_FC_CG)
    }
    x_event_source_rp: cross cp_event, cp_source_rp;
  endgroup

  function new(string name, uvm_component parent);
    aou_fc_db db;
    aou_fc_point p;
    bit fresh;
    super.new(name, parent);
    matcher = new();
    cg_dg04 = new();
    db = aou_fc_db::get();
    fc_dg04 = db.group("env.cg_dg04_b_identity", fresh);
    if (fresh) begin
      p = fc_dg04.cp("cp_event"); `AOU_T1_DG04_FC_EVENT(AOU_FC_REG)
      p = fc_dg04.cp("cp_source_rp"); `AOU_T1_DG04_FC_RP(AOU_FC_REG)
      void'(fc_dg04.add_cross("x_event_source_rp", "cp_event cp_source_rp"));
    end
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db#(virtual aou_b_combiner_if)::get(null, "*", "b_combiner", bci))
      `uvm_fatal(get_type_name(), "DG04-ID01: missing b_combiner observer")
  endfunction

  virtual function void write(aou_msg msg);
    aou_msg_wresp wresp;
    aou_b_identity_record_t expected;
    aou_b_identity_record_t checked;
    aou_b_identity_wire_t actual;
    logic [31:0] epoch;
    logic [31:0] sequence_id;
    logic [1:0] source_rp;
    logic [1:0] wire_rp;
    logic [9:0] bid;
    logic [1:0] bresp;
    int unsigned found;
    aou_b_identity_result_e result;

    if (msg.msg_type != AOU_MT_WRESP) return;
    if (!$cast(wresp, msg)) begin
      `uvm_error(get_type_name(), "DG04-ID01: WRESP type did not cast to aou_msg_wresp")
      return;
    end
    found = bci.pop_identity(epoch, sequence_id, source_rp, wire_rp, bid, bresp);
    if (found == 0) begin
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: unexpected WriteResp RP=%0d BID=%0h BRESP=%0d (no producer)",
          wresp.rp, wresp.id, wresp.resp))
      return;
    end
    expected = '{epoch, sequence_id, source_rp, wire_rp, bid, bresp};
    actual = '{wresp.rp, wresp.id, wresp.resp};
    if (!bci.identity_source_map_matches(source_rp, wire_rp)) begin
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: source/wire RP map mismatch seq=%0d source=%0d mapped=%0d recorded=%0d",
          sequence_id, source_rp, bci.identity_dest_rp(source_rp), wire_rp))
    end
    if (have_epoch && epoch != qualification_epoch && bci.armed)
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: delivery crossed epoch %0d -> %0d with qualification active",
          qualification_epoch, epoch))
    if (!have_epoch || epoch != qualification_epoch) begin
      if (have_epoch) begin
        int unsigned interrupted = matcher.begin_epoch();
        if (interrupted != 0)
          `uvm_error(get_type_name(), $sformatf(
              "DG04-ID01: epoch %0d interrupted %0d decoded reference record(s)",
              qualification_epoch, interrupted))
      end
      have_epoch = 1'b1;
      qualification_epoch = epoch;
    end
    matcher.push(expected);
    result = matcher.observe(actual, checked);
    if (result != AOU_B_ID_MATCH) begin
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: order/tuple mismatch seq=%0d exp=(%0d,%0h,%0d) got=(%0d,%0h,%0d) code=%0d",
          sequence_id, wire_rp, bid, bresp, wresp.rp, wresp.id, wresp.resp, result))
    end
    // Reuse of an AXI ID is legal. Count unique wire tuples for non-vacuity,
    // but do not reject a repeated tuple when it has its own ordered producer.
    begin
      bit is_distinct = 1'b1;
      foreach (observed[i]) begin
        if ({observed[i].wire_rp, observed[i].bid, observed[i].bresp} ===
            {wire_rp, bid, bresp}) is_distinct = 1'b0;
      end
      if (is_distinct) distinct_count++;
    end
    observed.push_back(expected);
    decoded_count++;
    if (3'(source_rp) < bci.active_rp_count) source_rp_mask[source_rp] = 1'b1;
    `uvm_info(get_type_name(), $sformatf(
        "DG04-ID01: decoded seq=%0d epoch=%0d source-RP=%0d wire-RP=%0d BID=%0h BRESP=%0d",
        sequence_id, epoch, source_rp, wire_rp, bid, bresp), UVM_MEDIUM)
  endfunction

  protected function void sample_qualification_coverage();
    s_dg04_rp = 4;
    if (bci.contention_cycles != 0) begin
      s_dg04_event = 0;
      cg_dg04.sample();
      fc_dg04.sample(int'(s_dg04_event), int'(s_dg04_rp));
    end
    for (int unsigned r = 0; r < 4; r++) begin
      if (bci.source_served_under_contention[r] != 0) begin
        s_dg04_event = 1;
        s_dg04_rp = r;
        cg_dg04.sample();
        fc_dg04.sample(int'(s_dg04_event), int'(s_dg04_rp));
      end
    end
    if (bci.global_stall_episodes != 0) begin
      s_dg04_event = 2;
      s_dg04_rp = 4;
      cg_dg04.sample();
      fc_dg04.sample(int'(s_dg04_event), int'(s_dg04_rp));
    end
    if (bci.global_stall_cycles > bci.global_stall_episodes) begin
      s_dg04_event = 3;
      cg_dg04.sample();
      fc_dg04.sample(int'(s_dg04_event), int'(s_dg04_rp));
    end
    if (bci.global_stall_releases != 0) begin
      s_dg04_event = 4;
      s_dg04_rp = 4;
      cg_dg04.sample();
      fc_dg04.sample(int'(s_dg04_event), int'(s_dg04_rp));
    end
    if (bci.global_stall_cycles != 0) begin
      s_dg04_event = 5;
      s_dg04_rp = 4;
      cg_dg04.sample();
      fc_dg04.sample(int'(s_dg04_event), int'(s_dg04_rp));
    end
  endfunction

  function void check_qualification_final();
    bit source_service_missing = 1'b0;
    sample_qualification_coverage();
    for (int unsigned r = 0; r < bci.active_rp_count; r++)
      if (bci.source_served_under_contention[r] == 0) source_service_missing = 1'b1;
    if (matcher.finish() != AOU_B_ID_MATCH)
      `uvm_error(get_type_name(), $sformatf("DG04-ID01: %0d expected record(s) were not decoded",
                                            matcher.expected.size()))
    if ((bci.identity_producer_count != decoded_count) || bci.identity_pending_count() != 0)
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: final count producer=%0d decoded=%0d distinct=%0d pending=%0d",
          bci.identity_producer_count, decoded_count, distinct_count,
          bci.identity_pending_count()))
    // Interface assertions use $error because they observe pins. Verilator
    // terminates without a UVM summary, which the production grader fails
    // closed. This UVM report also makes the retained count visible when a
    // simulator continues after $error and reaches check_phase.
    if (bci.errors != 0)
      `uvm_error(get_type_name(), $sformatf(
          "DG04: interface observer recorded %0d error(s)", bci.errors))
    if (bci.identity_reset_with_pending != 0 || bci.identity_link_loss_with_pending != 0)
      `uvm_error(get_type_name(), "DG04-ID01: reset/link-loss interrupted qualified delivery")
    `uvm_info(get_type_name(), $sformatf(
        "DG04-ID01: final producer=%0d decoded=%0d unique=%0d rp-mask=%b pending=%0d epoch=%0d",
        bci.identity_producer_count, decoded_count, distinct_count, source_rp_mask,
        bci.identity_pending_count(), qualification_epoch), UVM_LOW)
    if (bci.simultaneous_valid_cycles == 0 || bci.contention_cycles == 0 ||
        bci.contention_decisions == 0 || source_service_missing ||
        $countones(source_rp_mask) < 2 || distinct_count < 2 ||
        bci.global_stall_episodes == 0 ||
        bci.global_stall_cycles <= bci.global_stall_episodes ||
        bci.global_stall_releases == 0 ||
        bci.downstream_gate_stall_cycles == 0 || bci.final_consumer_stall_cycles == 0 ||
        bci.b_stall_wait_timeouts != 0)
      `uvm_info(get_type_name(), $sformatf(
          {"DG04 stimulus coverage incomplete (not a DUT error): eligible-contention=%0d ",
          "decisions=%0d source-mask=%b unique=%0d B-stall-entry/cycles/release=%0d/%0d/%0d ",
           "downstream-gate-stall=%0d FDI-stall=%0d"},
          bci.contention_cycles, bci.contention_decisions, source_rp_mask, distinct_count,
          bci.global_stall_episodes, bci.global_stall_cycles, bci.global_stall_releases,
          bci.downstream_gate_stall_cycles, bci.final_consumer_stall_cycles), UVM_LOW)
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (bci.identity_observer_errors != 0)
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: passive producer observer recorded %0d error(s)",
          bci.identity_observer_errors))
    if (!bci.armed && (bci.identity_observer_fifo_count != 0 ||
        bci.identity_queue_count != 0 ||
        bci.identity_observer_producers != bci.identity_observer_consumers))
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: passive final drain producer=%0d decoded=%0d staging=%0d pending=%0d",
          bci.identity_observer_producers, bci.identity_observer_consumers,
          bci.identity_observer_fifo_count, bci.identity_queue_count))
    if (bci.identity_observer_reset_aborts != 0)
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: reset interrupted %0d passive producer record(s); not delivered",
          bci.identity_observer_reset_aborts))
    if (bci.identity_observer_link_loss_pending_epochs != 0)
      `uvm_info(get_type_name(), $sformatf(
          {"DG04-ID01: %0d passive link-down epoch(s) had queued identities; ",
           "records were retained and remain subject to decoded matching/final drain"},
          bci.identity_observer_link_loss_pending_epochs), UVM_LOW)
  endfunction
endclass
