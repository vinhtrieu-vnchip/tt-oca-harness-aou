// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Focused, observe-only B-response combiner qualification. The passive identity
// subscriber itself is installed by aou_t1_env for every T1 scenario.
class aou_b_combiner_test extends aou_mrp_test;
  `uvm_component_utils(aou_b_combiner_test)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void set_knobs();
    k.dir = AOU_T1_BOTH_DIRS;
    k.wr_pct = 100;
    k.n = 16;
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    env.identity_chk.check_qualification_final();
  endfunction
endclass
