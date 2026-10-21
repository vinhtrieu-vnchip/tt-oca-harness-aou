// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

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

    // Reset/link-loss epoch boundaries clear only epoch-local pending work;
    // producer sequence numbers remain monotonic across the boundary.
    m.reset();
    a = rec(0, 0, 10'h111, 0);
    b = rec(1, 1, 10'h211, 2'b10);
    m.push(a);
    if (m.observe(wire_rec(a.wire_rp, a.bid, a.bresp), matched) != AOU_B_ID_MATCH)
      `uvm_error(get_type_name(), "DG04-ID01 epoch sequence setup did not match")
    if (m.begin_epoch() != 0)
      `uvm_error(get_type_name(), "DG04-ID01 drained epoch retained pending records")
    m.push(b);
    if (m.observe(wire_rec(b.wire_rp, b.bid, b.bresp), matched) != AOU_B_ID_MATCH)
      `uvm_error(get_type_name(), "DG04-ID01 producer sequence did not continue across epoch")
    else `uvm_info(get_type_name(),
                   "DG04-ID01 producer sequence remains monotonic across epoch", UVM_LOW)

    phase.drop_objection(this);
  endtask
endclass
