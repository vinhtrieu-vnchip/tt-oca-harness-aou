// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Focused, observe-only B-response combiner qualification. This test inherits
// aou_mrp_test's DUT-to-remote response accounting and is intentionally kept
// out of the aggregate PASS-only lists until independently qualified.
// Test-only adapter for the production-subscriber negative control. It sits
// on the real decoded L3 analysis path and corrupts exactly one WriteResp.
class aou_b_identity_corruptor extends uvm_subscriber #(aou_msg);
  `uvm_component_utils(aou_b_identity_corruptor)

  uvm_analysis_port #(aou_msg) ap_out;
  bit corrupted;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    ap_out = new("ap_out", this);
  endfunction

  virtual function void write(aou_msg msg);
    aou_msg forwarded;
    aou_msg_wresp wresp;
    if (!corrupted && msg.msg_type == AOU_MT_WRESP) begin
      if (!$cast(forwarded, msg.clone()) || !$cast(wresp, forwarded)) begin
        `uvm_fatal(get_type_name(), "DG04-ID01 negative control could not clone WriteResp")
      end
      wresp.id ^= 10'h001;
      corrupted = 1'b1;
      `uvm_info(get_type_name(),
                "DG04-ID01 injected one corrupted decoded WriteResp before production subscriber",
                UVM_LOW)
      ap_out.write(forwarded);
    end else begin
      ap_out.write(msg);
    end
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (!corrupted)
      `uvm_error(get_type_name(), "DG04-ID01 corruption control observed no decoded WriteResp")
  endfunction
endclass

class aou_b_combiner_test extends aou_mrp_test;
  `uvm_component_utils(aou_b_combiner_test)

  aou_b_identity_chk identity_chk;
  aou_b_identity_corruptor identity_corruptor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void set_knobs();
    k.dir = AOU_T1_BOTH_DIRS;
    k.wr_pct = 100;
    k.n = 16;
  endfunction

  function void build_phase(uvm_phase phase);
    int corrupt_wresp;
    super.build_phase(phase);
    identity_chk = aou_b_identity_chk::type_id::create("identity_chk", this);
    if ($value$plusargs("dg04_corrupt_wresp=%d", corrupt_wresp) && corrupt_wresp != 0)
      identity_corruptor = aou_b_identity_corruptor::type_id::create("identity_corruptor", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (identity_corruptor == null) begin
      env.l3.ap_rx_msg.connect(identity_chk.analysis_export);
    end else begin
      env.l3.ap_rx_msg.connect(identity_corruptor.analysis_export);
      identity_corruptor.ap_out.connect(identity_chk.analysis_export);
    end
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    identity_chk.check_final();
  endfunction
endclass
