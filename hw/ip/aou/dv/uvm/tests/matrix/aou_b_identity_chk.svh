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

  function new(string name, uvm_component parent);
    super.new(name, parent);
    matcher = new();
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
    if (have_epoch && epoch != qualification_epoch)
      `uvm_error(get_type_name(), $sformatf(
          "DG04-ID01: delivery crossed epoch %0d -> %0d with qualification active",
          qualification_epoch, epoch))
    if (!have_epoch) begin
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

  function void check_final();
    if (matcher.finish() != AOU_B_ID_MATCH)
      `uvm_error(get_type_name(), $sformatf("DG04-ID01: %0d expected record(s) were not decoded",
                                            matcher.expected.size()))
    if (decoded_count == 0 || decoded_count != bci.identity_producer_count ||
        bci.identity_pending_count() != 0 || distinct_count < 2)
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
    if ($countones(source_rp_mask) < 2)
      `uvm_error(get_type_name(), $sformatf("DG04-ID01: fewer than two source RPs mask=%b",
                                            source_rp_mask))
    if (bci.identity_reset_with_pending != 0 || bci.identity_link_loss_with_pending != 0)
      `uvm_error(get_type_name(), "DG04-ID01: reset/link-loss interrupted qualified delivery")
    `uvm_info(get_type_name(), $sformatf(
        "DG04-ID01: final producer=%0d decoded=%0d unique=%0d rp-mask=%b pending=%0d epoch=%0d",
        bci.identity_producer_count, decoded_count, distinct_count, source_rp_mask,
        bci.identity_pending_count(), qualification_epoch), UVM_LOW)
  endfunction
endclass

// Standalone checker-model controls. These mutations never enter the DUT or
// production scenario and PASS only when each invalid trace is rejected.
class aou_b_identity_negative_test extends uvm_test;
  `uvm_component_utils(aou_b_identity_negative_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function aou_b_identity_record_t rec(input int unsigned seq,
                                        input logic [1:0] rp,
                                        input logic [9:0] bid,
                                        input logic [1:0] resp);
    return '{32'd1, 32'(seq), 2'(rp), 2'(rp), bid, resp};
  endfunction

  function aou_b_identity_wire_t wire_rec(input logic [1:0] rp,
                                           input logic [9:0] bid,
                                           input logic [1:0] resp);
    return '{rp, bid, resp};
  endfunction

  task run_phase(uvm_phase phase);
    aou_b_identity_matcher m;
    aou_b_identity_record_t matched;
    aou_b_identity_result_e got;
    aou_b_identity_result_e want;
    aou_b_identity_record_t a;
    aou_b_identity_record_t b;
    phase.raise_objection(this);

    a = rec(0, 0, 10'h101, 2'b00);
    // Each payload field corruption is rejected by the shared production tuple matcher.
    if (aou_b_identity_tuple_matches(a, wire_rec(1, a.bid, a.bresp)))
      `uvm_error(get_type_name(), "DG04-ID01 negative RP corruption was accepted")
    else `uvm_info(get_type_name(), "DG04-ID01 negative RP corruption detected", UVM_LOW)
    if (aou_b_identity_tuple_matches(a, wire_rec(a.wire_rp, a.bid ^ 10'h001, a.bresp)))
      `uvm_error(get_type_name(), "DG04-ID01 negative BID corruption was accepted")
    else `uvm_info(get_type_name(), "DG04-ID01 negative BID corruption detected", UVM_LOW)
    if (aou_b_identity_tuple_matches(a, wire_rec(a.wire_rp, a.bid, 2'b10)))
      `uvm_error(get_type_name(), "DG04-ID01 negative BRESP corruption was accepted")
    else `uvm_info(get_type_name(), "DG04-ID01 negative BRESP corruption detected", UVM_LOW)

    m = new();
    m.reset(); m.push(a); got = m.finish(); want = AOU_B_ID_PENDING;
    if (got != want)
      `uvm_error(get_type_name(), "DG04-ID01 missing-delivery control was not detected")
    else `uvm_info(get_type_name(), "DG04-ID01 negative missing delivery detected", UVM_LOW)

    m.reset(); m.push(a);
    got = m.observe(wire_rec(a.wire_rp, a.bid, a.bresp), matched);
    if (got != AOU_B_ID_MATCH) `uvm_error(get_type_name(), "DG04-ID01 duplicate setup failed")
    got = m.observe(wire_rec(a.wire_rp, a.bid, a.bresp), matched); want = AOU_B_ID_UNEXPECTED;
    if (got != want)
      `uvm_error(get_type_name(), "DG04-ID01 duplicate-delivery control was not detected")
    else `uvm_info(get_type_name(), "DG04-ID01 negative duplicate delivery detected", UVM_LOW)

    m.reset(); a = rec(0, 0, 10'h101, 0); b = rec(1, 1, 10'h201, 2'b10);
    m.push(a); m.push(b);
    got = m.observe(wire_rec(b.wire_rp, b.bid, b.bresp), matched); want = AOU_B_ID_MISMATCH;
    if (got != want)
      `uvm_error(get_type_name(), "DG04-ID01 reorder control was not detected")
    else `uvm_info(get_type_name(), "DG04-ID01 negative reordered delivery detected", UVM_LOW)

    // Identical wire tuples can represent distinct ordered transactions after
    // a legal BID reuse. They must both match; an additional delivery is still
    // unexpected once the producer queue has drained.
    m.reset(); a = rec(0, 0, 10'h101, 0); b = rec(1, 0, 10'h101, 0);
    m.push(a); m.push(b);
    got = m.observe(wire_rec(a.wire_rp, a.bid, a.bresp), matched);
    if (got != AOU_B_ID_MATCH)
      `uvm_error(get_type_name(), "DG04-ID01 repeated-tuple first producer did not match")
    got = m.observe(wire_rec(b.wire_rp, b.bid, b.bresp), matched);
    if (got != AOU_B_ID_MATCH || m.finish() != AOU_B_ID_MATCH)
      `uvm_error(get_type_name(), "DG04-ID01 repeated-tuple ordered producers did not drain")
    if (m.observe(wire_rec(b.wire_rp, b.bid, b.bresp), matched) != AOU_B_ID_UNEXPECTED)
      `uvm_error(get_type_name(), "DG04-ID01 repeated-tuple extra delivery was accepted")
    else `uvm_info(get_type_name(),
                   "DG04-ID01 repeated tuple matched in order; extra delivery rejected", UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
