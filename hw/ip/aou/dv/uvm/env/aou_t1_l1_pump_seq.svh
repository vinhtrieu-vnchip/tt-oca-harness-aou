// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// L3 -> L1: runs on the L1 sequencer for the whole test, pulling each flit L3
// builds (tx_flit_export, blocks until L3 has one) and driving it with a
// random cancel plan, gaps and bubbles. L1 drives only while L2 reports
// Active. A flit L3 built before a reset (flush(), from the env's
// reset_flush) is dropped rather than sent after the link recovers: it holds
// stale credits and messages.
class aou_t1_l1_pump_seq extends uvm_sequence #(aou_flit_item);
  `uvm_object_utils(aou_t1_l1_pump_seq)

  aou_l3_agent  l3;
  aou_fdi_agent fdi;
  aou_t1_env_cfg cfg;
  int unsigned  n_dropped;
  protected int unsigned flush_gen;
  int unsigned cancel_pct = 10;
  int unsigned gap_pct = 10;
  int unsigned bubble_pct = 10;
  bit          cancel_mix = 1'b0;  // cancel plans over every shape (aou_flit_item::mix_cancel_plan)
  int unsigned n_flits;

  protected function bit is_semantic_target(aou_l3_flit_item lit);
    aou_msg_req req;
    bit [9:0] target_id;
    bit [63:0] target_addr;
    if (cfg.cancel_sem_mode == 0 || lit.flit == null) return 1'b0;
    target_id = cfg.cancel_sem_mode == 4 ? cfg.cancel_sem_poison_id : cfg.cancel_sem_original_id;
    target_addr = cfg.cancel_sem_mode == 4 ? cfg.cancel_sem_poison_addr :
                                             cfg.cancel_sem_original_addr;
    foreach (lit.flit.msgs[i]) begin
      if ($cast(req, lit.flit.msgs[i]) && req.msg_type == AOU_MT_RREQ &&
          req.id == target_id && req.addr == target_addr) return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function void make_semantic_poison(aou_flit_item it, int unsigned start_g);
    aou_flit f = aou_flit::type_id::create("semantic_poison_flit");
    aou_msg_rreq req = aou_msg_rreq::type_id::create("semantic_poison_read");
    aou_granule_t granules[$];
    bit [7:0] bytes[AOU_FLIT_BYTES];
    req.rp = 0;
    req.id = cfg.cancel_sem_poison_id;
    req.addr = cfg.cancel_sem_poison_addr;
    req.size = 3'd3;
    req.len = 0;
    req.prot = 0;
    req.cache = 0;
    req.qos = 0;
    req.lock = 0;
    req.rsvd = 0;
    req.to_granules(granules);
    if (granules.size() != 3 || start_g + granules.size() > AOU_GRANULES)
      `uvm_fatal(get_type_name(), "semantic poison request does not fit in flit")
    f.msg_start[start_g] = 1'b1;
    foreach (granules[i]) f.g[start_g+i] = granules[i];
    f.to_bytes(bytes);
    foreach (granules[i]) begin
      int unsigned byte0 = aou_granule_byte(start_g + i);
      for (int unsigned b = 0; b < 5; b++) it.cancel_payload[byte0+b] = bytes[byte0+b];
    end
    it.cancel_payload_valid = 1'b1;
  endfunction

  function new(string name = "aou_t1_l1_pump_seq");
    super.new(name);
  endfunction

  function void flush();
    flush_gen++;
  endfunction

  task body();
    if (l3 == null || fdi == null) `uvm_fatal(get_type_name(), "l3 or fdi not set")
    forever begin
      aou_l3_flit_item lit;
      aou_flit_item it;
      bit cancel;
      bit gap;
      bit semantic_target;
      int unsigned gen;
      l3.tx_flit_export.get(lit);
      gen = flush_gen;   // L3 built the flit in this time step
      // Hand the flit to L1 only once the link is Active, so a reset while it
      // waits can still cancel it.
      while (!fdi.cfg.gate.open && gen == flush_gen) @(fdi.vif.mon_cb);
      if (gen != flush_gen) begin
        n_dropped++;
        `uvm_info(get_type_name(), "flit built before a reset dropped", UVM_MEDIUM)
        continue;
      end
      it = aou_flit_item::type_id::create("it");
      semantic_target = is_semantic_target(lit);
      cancel = (cfg.cancel_sem_mode inside {1, 2, 3} && semantic_target) ||
               $urandom_range(99) < cancel_pct;
      gap = $urandom_range(99) < gap_pct;
      start_item(it);
      `AOU_RANDOMIZE_WITH(it, {
        if (!cancel) { cancel_h0 == AOU_CANCEL_NONE; cancel_h1 == AOU_CANCEL_NONE; }
        else { cancel_h0 != AOU_CANCEL_NONE || cancel_h1 != AOU_CANCEL_NONE; }
        if (!gap) pre_gap == 0; else pre_gap inside {[1:6]};
        beat_gap_pct == bubble_pct;
      })
      if (cancel && cancel_mix) it.mix_cancel_plan();
      foreach (it.data[i]) it.data[i] = lit.bytes[i];
      it.clear_adapter_bytes();
      if (it.data[0][7:6] == 2'b00) it.data[0][7:6] = 2'b11;
      if (cfg.cancel_sem_mode inside {1, 2, 3} && semantic_target) begin
        int unsigned start_g = 0;
        aou_msg_req req;
        foreach (lit.flit.msgs[i]) begin
          if ($cast(req, lit.flit.msgs[i]) && req.msg_type == AOU_MT_RREQ &&
              req.id == cfg.cancel_sem_original_id && req.addr == cfg.cancel_sem_original_addr)
            start_g = req.start_granule;
        end
        if ((cfg.cancel_sem_mode == 3 && start_g < 24) ||
            (cfg.cancel_sem_mode inside {1, 2} && start_g >= 24) ||
            (start_g % 24 > 21)) begin
          `uvm_error(get_type_name(),
                     $sformatf("T1-L48: target ReadReq G%0d is outside the requested half",
                               start_g))
        end
        it.cancel_h0 = AOU_CANCEL_NONE;
        it.cancel_h1 = AOU_CANCEL_NONE;
        case (cfg.cancel_sem_mode)
          1: it.cancel_h0 = AOU_CANCEL_IDLE;
          2: it.cancel_h0 = AOU_CANCEL_VALID;
          3: it.cancel_h1 = AOU_CANCEL_IDLE;
          default: `uvm_fatal(get_type_name(), "invalid semantic cancel mode")
        endcase
        it.cancel_repeat = 1;
        it.h1_replay_resend_h0 = 1'b0;
        make_semantic_poison(it, start_g);
      end
      finish_item(it);
      n_flits++;
    end
  endtask
endclass
