// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Observe-only checks for the TX B-response combiner and its two response
// FIFOs. The interface is wired to internal DUT signals in tb_top; it never
// drives a DUT signal.
interface aou_b_combiner_if (
    input logic [2:0] active_rp_count,
    input logic clk,
    input logic rst_n,
    input logic [3:0] src_valid,
    input logic [3:0] src_ready,
    input logic [3:0] src_credit_valid,
    input logic [3:0][1:0] src_dest_rp,
    input logic [3:0][9:0] src_bid,
    input logic [3:0][1:0] src_bresp,
    input logic [3:0] src_push_valid,
    input logic [3:0] src_push_ready,
    input logic [3:0] arb_grant,
    input logic global_in_valid,
    input logic global_in_ready,
    input logic [1:0] global_in_rp,
    input logic [9:0] global_in_bid,
    input logic [1:0] global_in_bresp,
    input logic global_out_valid,
    input logic global_out_ready,
    input logic [1:0] global_out_rp,
    input logic [9:0] global_out_bid,
    input logic [1:0] global_out_bresp,
    input logic [7:0] ring_write_ptr,
    input logic [7:0] ring_read_ptr,
    input logic ring_ready,
    input logic [7:0] ring_used,
    input logic tx_pop_ok,
    input logic tx_rsp_credit_ready,
    input logic tx_misc_activation_valid,
    input logic ring_flit_valid,
    input logic ring_flit_ready,
    input logic fdi_tx_valid,
    input logic fdi_tx_irdy,
    input logic fdi_tx_ready,
    input logic tx_link_active
);

  typedef struct packed {
    logic [1:0] rp;
    logic [9:0] bid;
    logic [1:0] bresp;
  } b_item_t;

  typedef struct packed {
    logic [1:0] rp;
    logic [9:0] bid;
    logic [1:0] bresp;
    logic [1:0] source_rp;
  } expected_item_t;

  typedef struct packed {
    logic [31:0] epoch;
    logic [31:0] sequence_id;
    logic [1:0] source_rp;
    logic [1:0] wire_rp;
    logic [9:0] bid;
    logic [1:0] bresp;
  } identity_record_t;

  localparam int unsigned IDENTITY_QUEUE_DEPTH = 1024;

  bit armed = 1'b0;
  int unsigned errors;
  int unsigned source_pushes[4];
  int unsigned source_pops[4];
  int unsigned source_occ[4];
  int unsigned source_served_under_contention[4];
  bit source_contended_seen[4];
  b_item_t source_contended_first[4];
  int unsigned global_enqueues;
  int unsigned global_dequeues;
  int unsigned ring_b_enqueues;
  int unsigned contention_cycles;
  int unsigned contention_decisions;
  int unsigned simultaneous_valid_cycles;
  int unsigned raw_grant_onehot_violations;
  int unsigned effective_select_onehot_violations;
  int unsigned source_stall_cycles;
  int unsigned global_stall_cycles;
  int unsigned global_stall_episodes;
  int unsigned global_stall_releases;
  int unsigned downstream_gate_stall_cycles;
  int unsigned ring_full_samples;
  int unsigned ring_granule_writes;
  int unsigned ring_granule_reads;
  int unsigned ring_flit_transfers;
  int unsigned final_consumer_transfers;
  int unsigned final_consumer_stall_cycles;
  logic [7:0] prev_ring_write_ptr;
  logic [7:0] prev_ring_read_ptr;
  int unsigned global_occ;
  expected_item_t expected_fifo[2];
  int unsigned expected_count;
  int unsigned expected_head;
  int unsigned expected_tail;
  identity_record_t identity_pending[IDENTITY_QUEUE_DEPTH];
  bit [31:0] identity_queue_head;
  bit [31:0] identity_queue_tail;
  bit [31:0] identity_queue_count;
  bit [31:0] identity_epoch;
  bit [31:0] identity_next_sequence;
  bit [31:0] identity_producer_count;
  bit [31:0] identity_consumer_count;
  int unsigned identity_reset_with_pending;
  int unsigned identity_link_loss_with_pending;
  bit identity_reset_seen;
  bit prev_tx_link_active;
  bit stalled_last;
  b_item_t stalled_item;
  bit stall_unreleased;

  function automatic int unsigned bit_count(input logic [3:0] value);
    int unsigned n = 0;
    for (int unsigned i = 0; i < 4; i++) n += value[i] ? 1 : 0;
    return n;
  endfunction

  function automatic bit dest_rp_map_injective();
    for (int unsigned i = 0; i < active_rp_count; i++) begin
      for (int unsigned j = i + 1; j < active_rp_count; j++) begin
        if (src_dest_rp[i] == src_dest_rp[j]) return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  function automatic int unsigned identity_pending_count();
    return identity_queue_count;
  endfunction

  function automatic logic [1:0] identity_dest_rp(input logic [1:0] source_rp);
    if (3'(source_rp) >= active_rp_count) return 'x;
    return src_dest_rp[source_rp];
  endfunction

  function automatic bit identity_source_map_matches(input logic [1:0] source_rp,
                                                       input logic [1:0] wire_rp);
    if (3'(source_rp) >= active_rp_count) return 1'b0;
    return src_dest_rp[source_rp] === wire_rp;
  endfunction

  function automatic int unsigned pop_identity(output logic [31:0] epoch,
                                                output logic [31:0] sequence_id,
                                                output logic [1:0] source_rp,
                                                output logic [1:0] wire_rp,
                                                output logic [9:0] bid,
                                                output logic [1:0] bresp);
    identity_record_t record;
    if (identity_queue_count == 0) return 0;
    record = identity_pending[identity_queue_head];
    identity_queue_head = (identity_queue_head + 1) % IDENTITY_QUEUE_DEPTH;
    identity_queue_count--;
    epoch = record.epoch;
    sequence_id = record.sequence_id;
    source_rp = record.source_rp;
    wire_rp = record.wire_rp;
    bid = record.bid;
    bresp = record.bresp;
    identity_consumer_count++;
    return 1;
  endfunction

  task automatic arm();
    if (identity_queue_count != 0) begin
      errors++;
      armed = 1'b0;
      $error("DG04-ID01: cannot re-arm with %0d undelivered identity records",
             identity_queue_count);
      return;
    end
    errors = 0;
    if (!dest_rp_map_injective()) begin
      errors++;
      $error("DG04-ID01: active DEST_RP map is not injective");
    end
    if (!tx_link_active) begin
      errors++;
      $error("DG04-ID01: identity qualification armed while TX link is not active");
    end
    if (global_out_valid || global_occ != 0 || expected_count != 0) begin
      errors++;
      $error("DG04: cannot arm with non-empty global B FIFO model");
    end
    for (int unsigned i = 0; i < 4; i++) begin
      if (src_valid[i] || source_occ[i] != 0) begin
        errors++;
        $error("DG04: cannot arm with non-empty RP%0d source B FIFO model", i);
      end
      source_pushes[i] = 0;
      source_pops[i] = 0;
      source_occ[i] = 0;
      source_served_under_contention[i] = 0;
      source_contended_seen[i] = 1'b0;
      source_contended_first[i] = '0;
    end
    global_enqueues = 0;
    global_dequeues = 0;
    ring_b_enqueues = 0;
    contention_cycles = 0;
    contention_decisions = 0;
    simultaneous_valid_cycles = 0;
    raw_grant_onehot_violations = 0;
    effective_select_onehot_violations = 0;
    source_stall_cycles = 0;
    global_stall_cycles = 0;
    global_stall_episodes = 0;
    global_stall_releases = 0;
    downstream_gate_stall_cycles = 0;
    ring_full_samples = 0;
    ring_granule_writes = 0;
    ring_granule_reads = 0;
    ring_flit_transfers = 0;
    final_consumer_transfers = 0;
    final_consumer_stall_cycles = 0;
    prev_ring_write_ptr = ring_write_ptr;
    prev_ring_read_ptr = ring_read_ptr;
    global_occ = 0;
    expected_count = 0;
    expected_head = 0;
    expected_tail = 0;
    stalled_last = 1'b0;
    stall_unreleased = 1'b0;
    identity_epoch++;
    identity_next_sequence = 0;
    identity_producer_count = 0;
    identity_consumer_count = 0;
    identity_queue_head = 0;
    identity_queue_tail = 0;
    identity_queue_count = 0;
    identity_reset_with_pending = 0;
    identity_link_loss_with_pending = 0;
    identity_reset_seen = 1'b0;
    prev_tx_link_active = tx_link_active;
    armed = 1'b1;
  endtask

  task automatic wait_b_stall(input int unsigned timeout_cycles);
    for (int unsigned n = 0; n < timeout_cycles; n++) begin
      @(negedge clk);
      if (global_out_valid && !global_out_ready && fdi_tx_valid && fdi_tx_irdy &&
          !fdi_tx_ready && tx_rsp_credit_ready && !tx_misc_activation_valid &&
          ring_ready && !tx_pop_ok) return;
    end
    errors++;
    $display("DG04 timeout: B=%b/%b fdi=%b/%b/%b ring=%b/%0d pop=%b credit=%b misc=%b",
             global_out_valid, global_out_ready, fdi_tx_valid, fdi_tx_irdy, fdi_tx_ready,
             ring_ready, ring_used, tx_pop_ok, tx_rsp_credit_ready, tx_misc_activation_valid);
    report_counters("B-stall-timeout");
    $error("DG04: no global B response stalled by the final consumer within %0d cycles",
           timeout_cycles);
  endtask

  task automatic check_final();
    report_counters("final");
    if (simultaneous_valid_cycles == 0 || contention_cycles == 0 ||
        contention_decisions == 0) begin
      errors++;
      $error("DG04: cross-RP B contention was not observed and serviced");
    end
    for (int unsigned i = 0; i < active_rp_count; i++) begin
      if (source_served_under_contention[i] == 0) begin
        errors++;
        $error("DG04: RP%0d had no accepted service while contended", i);
      end
      if (source_pushes[i] != source_pops[i]) begin
        errors++;
        $error("DG04: RP%0d B source conservation push=%0d pop=%0d", i,
               source_pushes[i], source_pops[i]);
      end
      if (source_occ[i] != 0) begin
        errors++;
        $error("DG04: RP%0d B source FIFO remains occupied by %0d", i, source_occ[i]);
      end
    end
    for (int unsigned i = 0; i < active_rp_count; i++) begin
      for (int unsigned j = i + 1; j < active_rp_count; j++) begin
        if (source_contended_seen[i] && source_contended_seen[j] &&
            source_contended_first[i] == source_contended_first[j]) begin
          errors++;
          $error("DG04: contended RPs %0d and %0d produced the same B identity", i, j);
        end
      end
    end
    if (global_enqueues != global_dequeues || global_occ != 0 || expected_count != 0) begin
      errors++;
      $error("DG04: global B FIFO conservation enqueue=%0d dequeue=%0d occ=%0d expected=%0d",
             global_enqueues, global_dequeues, global_occ, expected_count);
    end
    if (ring_b_enqueues != global_dequeues) begin
      errors++;
      $error("DG04: B-message ring enqueue=%0d differs from global B dequeue=%0d",
             ring_b_enqueues,
             global_dequeues);
    end
    if (ring_granule_writes != ring_granule_reads + 32'(ring_used) || ring_used != 0) begin
      errors++;
      $error("DG04: TX ring conservation write=%0d read=%0d used=%0d", ring_granule_writes,
             ring_granule_reads, ring_used);
    end
    if (downstream_gate_stall_cycles == 0 || global_stall_cycles == 0 ||
        global_stall_releases == 0 || global_stall_episodes != global_stall_releases ||
        stall_unreleased || final_consumer_stall_cycles == 0) begin
      errors++;
      $error("DG04: no complete sampled final-consumer B stall/release");
    end
    if (identity_producer_count == 0 || identity_queue_count != 0 ||
        identity_producer_count != identity_consumer_count) begin
      errors++;
      $error("DG04-ID01: identity drain producer=%0d consumer=%0d pending=%0d",
             identity_producer_count, identity_consumer_count, identity_queue_count);
    end
    if (identity_reset_with_pending != 0 || identity_link_loss_with_pending != 0) begin
      errors++;
      $error("DG04-ID01: pending delivery interrupted reset=%0d link=%0d",
             identity_reset_with_pending, identity_link_loss_with_pending);
    end
    if (errors != 0) $error("DG04: final check has %0d error(s)", errors);
  endtask

  task automatic report_counters(input string phase);
    $display("DG04[%s]: valid=%0d eligible=%0d decisions=%0d service=%p",
             phase, simultaneous_valid_cycles, contention_cycles, contention_decisions,
             source_served_under_contention);
    $display("DG04[%s]: onehot=%0d/%0d src-push/pop=%p/%p global=%0d/%0d occ=%0d",
             phase, raw_grant_onehot_violations, effective_select_onehot_violations,
             source_pushes, source_pops, global_enqueues, global_dequeues, global_occ);
    $display("DG04[%s]: B-ring-enq=%0d granule-W/R=%0d/%0d used=%0d", phase,
             ring_b_enqueues, ring_granule_writes, ring_granule_reads, ring_used);
    $display("DG04[%s]: ring-flit=%0d FDI-xfer/stall=%0d/%0d B-stall/release=%0d/%0d gated=%0d",
             phase,
             ring_flit_transfers, final_consumer_transfers, final_consumer_stall_cycles,
             global_stall_cycles, global_stall_releases, downstream_gate_stall_cycles);
    $display("DG04[%s]: identity epoch=%0d producer=%0d consumed=%0d pending=%0d rst/link=%0d/%0d",
             phase, identity_epoch, identity_producer_count, identity_consumer_count,
             identity_queue_count, identity_reset_with_pending, identity_link_loss_with_pending);
  endtask

  // This sampled reference model uses ordered blocking updates so each cycle's
  // conservation checks see the just-computed source and FIFO accounting.
  /* verilator lint_off BLKSEQ */
  always @(posedge clk) begin : p_observe_b_combiner
    logic [3:0] pop_vec;
    int unsigned eligible_count;
    int unsigned pop_count;
    bit enq;
    bit deq;
    bit source_pushed[4];
    b_item_t item;
    expected_item_t expected_item;
    identity_record_t identity_item;
    int unsigned selected_source;

    if (!rst_n) begin
      if (!identity_reset_seen) begin
        if (armed && (identity_queue_count != 0 || global_occ != 0 || expected_count != 0)) begin
          identity_reset_with_pending++;
          errors++;
          $error("DG04-ID01: reset interrupted delivery pending=%0d global=%0d expected=%0d",
                 identity_queue_count, global_occ, expected_count);
        end
        identity_epoch++;
        identity_reset_seen = 1'b1;
      end
      for (int unsigned i = 0; i < 4; i++) begin
        source_occ[i] = 0;
        source_pushes[i] = 0;
        source_pops[i] = 0;
        source_served_under_contention[i] = 0;
        source_contended_seen[i] = 1'b0;
        source_contended_first[i] = '0;
      end
      global_occ = 0;
      expected_count = 0;
      expected_head = 0;
      expected_tail = 0;
      stalled_last = 1'b0;
      stall_unreleased = 1'b0;
    end else if (armed) begin
      identity_reset_seen = 1'b0;
      if (prev_tx_link_active && !tx_link_active &&
          (identity_queue_count != 0 || global_occ != 0 || expected_count != 0)) begin
        identity_link_loss_with_pending++;
        errors++;
        $error("DG04-ID01: TX link loss interrupted delivery pending=%0d global=%0d expected=%0d",
               identity_queue_count, global_occ, expected_count);
      end
      if (prev_tx_link_active && !tx_link_active) identity_epoch++;
      prev_tx_link_active = tx_link_active;
      eligible_count = 0;
      selected_source = 4;
      if (bit_count(src_valid) >= 2) simultaneous_valid_cycles++;
      for (int unsigned i = 0; i < 4; i++) begin
        if (src_valid[i] && src_credit_valid[i]) eligible_count++;
        source_pushed[i] = src_push_valid[i] && src_push_ready[i];
        pop_vec[i] = src_valid[i] && src_ready[i] && src_credit_valid[i];
        if (source_occ[i] > 2) begin
          errors++;
          $error("DG04: RP%0d source occupancy %0d exceeds depth 2", i, source_occ[i]);
        end
        if (src_valid[i] !== (source_occ[i] != 0)) begin
          errors++;
          $error("DG04: RP%0d source FIFO valid=%0b model occupancy=%0d", i, src_valid[i],
                 source_occ[i]);
        end
      end
      pop_count = bit_count(pop_vec);
      if (bit_count(arb_grant) > 1) begin
        raw_grant_onehot_violations++;
        errors++;
        $error("DG04: raw arbiter grant is not one-hot: %b", arb_grant);
      end
      if (pop_count > 1) begin
        effective_select_onehot_violations++;
        errors++;
        $error("DG04: effective source selection is not one-hot: %b", pop_vec);
      end
      if (eligible_count >= 2) contention_cycles++;
      if (pop_count != 0 && eligible_count >= 2) contention_decisions++;
      for (int unsigned i = 0; i < 4; i++) begin
        if (source_pushed[i]) source_pushes[i]++;
        if (pop_vec[i]) begin
          source_pops[i]++;
          if (eligible_count >= 2) begin
            source_served_under_contention[i]++;
            if (!source_contended_seen[i]) begin
              source_contended_first[i] = '{src_dest_rp[i], src_bid[i], src_bresp[i]};
              source_contended_seen[i] = 1'b1;
            end
          end
        end
      end
      if (pop_count != 0) begin
        if (!(global_in_valid && global_in_ready)) begin
          errors++;
          $error("DG04: source B FIFO dequeued without shared B FIFO enqueue");
        end else begin
          for (int unsigned i = 0; i < 4; i++) begin
            if (pop_vec[i]) begin
              selected_source = i;
              if ({global_in_rp, global_in_bid, global_in_bresp} !==
                  {src_dest_rp[i], src_bid[i], src_bresp[i]}) begin
                errors++;
                $error("DG04: selected RP%0d B response provenance mismatch", i);
              end
            end
          end
        end
      end
      enq = global_in_valid && global_in_ready;
      deq = global_out_valid && global_out_ready;
      if (global_out_valid !== (global_occ != 0)) begin
        errors++;
        $error("DG04: global B FIFO valid=%0b model occupancy=%0d", global_out_valid, global_occ);
      end
      if (enq !== (pop_count != 0)) begin
        errors++;
        $error("DG04: global enqueue=%0b differs from effective per-RP dequeue count=%0d", enq,
               pop_count);
      end
      if (deq) begin
        if (expected_count == 0) begin
          errors++;
          $error("DG04: global B FIFO dequeued with no expected response identity");
          expected_item = '{global_out_rp, global_out_bid, global_out_bresp, 2'b11};
        end else begin
          expected_item = expected_fifo[expected_head];
          item = '{expected_item.rp, expected_item.bid, expected_item.bresp};
          expected_head = (expected_head + 1) % 2;
          expected_count--;
          if ({global_out_rp, global_out_bid, global_out_bresp} !== item) begin
            errors++;
            $error("DG04: global B FIFO output provenance mismatch expected=%h actual=%h", item,
                   {global_out_rp, global_out_bid, global_out_bresp});
          end
        end
        identity_item = '{identity_epoch, identity_next_sequence, expected_item.source_rp,
                          global_out_rp, global_out_bid, global_out_bresp};
        if (3'(expected_item.source_rp) >= active_rp_count ||
            src_dest_rp[expected_item.source_rp] !== global_out_rp) begin
          errors++;
          $error("DG04-ID01: source RP %0d does not map to global B wire RP %0d",
                 expected_item.source_rp, global_out_rp);
        end
        if (identity_queue_count >= IDENTITY_QUEUE_DEPTH) begin
          errors++;
          $error("DG04-ID01: identity reference queue overflow depth=%0d",
                 IDENTITY_QUEUE_DEPTH);
        end else begin
          identity_pending[identity_queue_tail] = identity_item;
          identity_queue_tail = (identity_queue_tail + 1) % IDENTITY_QUEUE_DEPTH;
          identity_queue_count++;
        end
        identity_next_sequence++;
        identity_producer_count++;
        global_dequeues++;
        ring_b_enqueues++;
      end
      if (enq) begin
        if (selected_source >= active_rp_count || pop_count != 1) begin
          errors++;
          $error("DG04-ID01: global B enqueue lacks one active source (source=%0d pops=%0d)",
                 selected_source, pop_count);
        end
        expected_item = '{global_in_rp, global_in_bid, global_in_bresp,
                          selected_source < 4 ? 2'(selected_source) : 2'b11};
        if (expected_count >= 2) begin
          errors++;
          $error("DG04: expected global B FIFO model overflow");
        end else begin
          expected_fifo[expected_tail] = expected_item;
          expected_tail = (expected_tail + 1) % 2;
          expected_count++;
          global_enqueues++;
        end
      end
      for (int unsigned i = 0; i < 4; i++) begin
        case ({source_pushed[i], pop_vec[i]})
          2'b10: source_occ[i]++;
          2'b01: if (source_occ[i] != 0) source_occ[i]--;
                 else begin errors++; $error("DG04: RP%0d source underflow", i); end
          default: ;
        endcase
      end
      case ({enq, deq})
        2'b10: global_occ++;
        2'b01: if (global_occ != 0) global_occ--;
               else begin errors++; $error("DG04: global B FIFO model underflow"); end
        default: ;
      endcase
      for (int unsigned i = 0; i < 4; i++) begin
        if (source_pushes[i] - source_pops[i] != source_occ[i]) begin
          errors++;
          $error("DG04: RP%0d B source push/pop/occupancy accounting disagrees", i);
        end
      end
      if (global_enqueues - global_dequeues != global_occ || expected_count != global_occ) begin
        errors++;
        $error("DG04: global B enqueue/dequeue/occupancy accounting disagrees");
      end

      if (global_out_valid && !global_out_ready) begin
        global_stall_cycles++;
        if (fdi_tx_valid && fdi_tx_irdy && !fdi_tx_ready && tx_rsp_credit_ready &&
            !tx_misc_activation_valid && ring_ready && !tx_pop_ok)
          downstream_gate_stall_cycles++;
        if (!stall_unreleased) global_stall_episodes++;
        if (stalled_last &&
            ({global_out_rp, global_out_bid, global_out_bresp} !== stalled_item)) begin
          errors++;
          $error("DG04: global B payload changed during sampled backpressure");
        end
        stalled_item = '{global_out_rp, global_out_bid, global_out_bresp};
        stalled_last = 1'b1;
        stall_unreleased = 1'b1;
      end else if (stall_unreleased) begin
        if (!global_out_valid) begin
          errors++;
          $error("DG04: global BVALID dropped before the stalled response handshook");
        end else if (!global_out_ready) begin
          errors++;
          $error("DG04: invalid stalled response transition");
        end else begin
          if ({global_out_rp, global_out_bid, global_out_bresp} !== stalled_item) begin
            errors++;
            $error("DG04: global B payload changed on stall release");
          end
          global_stall_releases++;
          stall_unreleased = 1'b0;
          stalled_last = 1'b0;
        end
      end else begin
        stalled_last = 1'b0;
      end
      if (!ring_ready) ring_full_samples++;
      if (|(src_valid & ~src_ready)) source_stall_cycles++;

      ring_granule_writes += 32'(ring_write_ptr - prev_ring_write_ptr);
      ring_granule_reads += 32'(ring_read_ptr - prev_ring_read_ptr);
      prev_ring_write_ptr = ring_write_ptr;
      prev_ring_read_ptr = ring_read_ptr;
      if (ring_flit_valid && ring_flit_ready) ring_flit_transfers++;
      if (fdi_tx_valid && fdi_tx_irdy && fdi_tx_ready) final_consumer_transfers++;
      if (fdi_tx_valid && fdi_tx_irdy && !fdi_tx_ready) final_consumer_stall_cycles++;
    end
  end
  /* verilator lint_on BLKSEQ */
endinterface
