// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Deterministic v0.7.1 activation-credit packing for the RX Misc candidate
// truncation regression. The accepted wire is independently checked by
// aou_t1_rx_align_chk (T1-C43); this sequence does not infer decoder results.
class aou_rx_misc_credit_loss_vseq extends aou_link_base_vseq;
  `uvm_object_utils(aou_rx_misc_credit_loss_vseq)

  function new(string name = "aou_rx_misc_credit_loss_vseq");
    super.new(name);
  endfunction

  task body();
    link_up();
    // RP0 RDATA=192 needs two encodable grants (128 then 64); the other
    // classes fit one. After ActivateAck at G0, the grants start at G1/G3.
    env.l3.model.crd.reset_link();
    activate(AOU_T1_BY_APB, AOU_T1_DUT_FIRST);
    wait_cycles(32);
  endtask
endclass
