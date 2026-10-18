// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// AXI-originated legal reads used by the semantic cancel virtual sequence.
class aou_t1_cancel_sem_axi_seq extends aou_axi_base_seq;
  `uvm_object_utils(aou_t1_cancel_sem_axi_seq)

  aou_l3_agent l3;
  int unsigned count = 1;
  bit [9:0] target_id = '0;
  bit [63:0] target_addr = '0;

  function new(string name = "aou_t1_cancel_sem_axi_seq");
    super.new(name);
  endfunction

  task body();
    if (l3 == null) `uvm_fatal(get_type_name(), "L3 handle is not set")
    // Hold eligible requests until all are queued so target G24 is deterministic.
    l3.model.pk.cfg.pol.hold_credited = 1'b1;
    for (int unsigned i = 0; i < count; i++) begin
      aou_axi_txn t = new_txn($sformatf("cancel_sem_axi%0d", i));
      t.dir = AOU_AXI_RD;
      t.id = i == count - 1 ? target_id : 10'(10'h100 + i);
      t.addr = i == count - 1 ? target_addr : 64'h0000_0000_1000_0000 + 64'(i) * 64'h1000;
      t.size = 3'd3;
      t.len = 0;
      t.burst = AOU_AXI_INCR;
      t.lock = 0;
      send(t);
    end
    l3.model.pk.cfg.pol.hold_credited = 1'b0;
    l3.model.kick();
    wait_all();
  endtask
endclass

// Directed cancel semantics through the native AXI manager and L3 packer.
// Eight legal ReadReqs fill H0 so mode 3 places the target at H1's first granule.
class aou_t1_cancel_sem_seq extends aou_base_test_seq;
  `uvm_object_utils(aou_t1_cancel_sem_seq)

  function new(string name = "aou_t1_cancel_sem_seq");
    super.new(name);
  endfunction

  task body();
    int unsigned target_idx;
    link_up();
    activate(AOU_T1_BY_APB, AOU_T1_ORDER_RANDOM);
    target_idx = cfg.cancel_sem_mode == 3 ? 9 : 1;
    begin
      aou_t1_cancel_sem_axi_seq s =
          aou_t1_cancel_sem_axi_seq::type_id::create("cancel_sem_axi_seq");
      s.l3 = env.l3;
      s.count = target_idx;
      s.target_id = cfg.cancel_sem_mode == 4 ? cfg.cancel_sem_poison_id :
                                               cfg.cancel_sem_original_id;
      s.target_addr = cfg.cancel_sem_mode == 4 ? cfg.cancel_sem_poison_addr :
                                                 cfg.cancel_sem_original_addr;
      s.start(p_sequencer.r_mgr_sqr[0]);
    end
    drain();
  endtask
endclass
