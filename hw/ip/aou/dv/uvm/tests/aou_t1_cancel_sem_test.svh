// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

class aou_t1_cancel_sem_test extends aou_base_test;
  `uvm_component_utils(aou_t1_cancel_sem_test)

  function new(string name = "aou_t1_cancel_sem_test", uvm_component parent = null);
    super.new(name, parent);
    vseq_type = "aou_t1_cancel_sem_seq";
  endfunction

  function void configure();
    int unsigned mode;
    if (!$value$plusargs("cancel_sem_mode=%d", mode) || !(mode inside {[1:4]}))
      `uvm_fatal(get_type_name(), "use +cancel_sem_mode=1|2|3|4")
    cfg.cancel_sem_mode = mode;
    cfg.l1_cancel_pct = 0;
    cfg.l1_cancel_mix = 0;
    min_l2r = 0;
    min_r2l = 0;
  endfunction
endclass
