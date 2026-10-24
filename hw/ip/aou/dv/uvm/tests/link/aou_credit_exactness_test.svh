// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Real finite-credit traffic uses the production observer throughout. The
// under-admission control changes only its final independently decoded count.
class aou_credit_exactness_test extends aou_zero_credit_test;
  `uvm_component_utils(aou_credit_exactness_test)
  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction
  function void check_phase(uvm_phase phase);
    string negative;
    super.check_phase(phase);
    void'($value$plusargs("credit_budget_negative=%s", negative));
    if (negative == "under") begin
      int unsigned actual = env.crd_chk.dut_msg_starts[0][AOU_CC_WREQ];
      if (actual == 0) `uvm_fatal(get_type_name(), "under-admission control had no real admissions")
      void'(env.crd_chk.check_exact_budget_count(
          0, AOU_CC_WREQ, actual - 1, actual, "injected under-admission after real drain"
      ));
      `uvm_info(get_type_name(), "C1C_INJECTED=under", UVM_LOW)
    end else if (negative != "") `uvm_fatal(get_type_name(), "unknown credit_budget_negative")
  endfunction
endclass
