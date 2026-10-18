// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// DUT-visible semantic oracle for a cancelled remote ReadReq. It observes only
// completed M-port AXI reads and receive-side FDI cancel metadata.
class aou_t1_cancel_sem_chk extends uvm_component;
  `uvm_component_utils(aou_t1_cancel_sem_chk)

  uvm_analysis_imp_cancel_mport #(aou_axi_txn, aou_t1_cancel_sem_chk) mport_imp;
  uvm_analysis_imp_cancel_rxflit #(aou_flit_item, aou_t1_cancel_sem_chk) rxflit_imp;
  aou_t1_env_cfg cfg;

  int unsigned poison_consumed;
  int unsigned poison_id_mismatch;
  int unsigned original_completed;
  int unsigned cancelled_h0;
  int unsigned cancelled_h1;
  int unsigned valid_cancel;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    mport_imp = new("mport_imp", this);
    rxflit_imp = new("rxflit_imp", this);
  endfunction

  function void write_cancel_mport(aou_axi_txn t);
    if (t.dir != AOU_AXI_RD) return;
    if (t.addr == cfg.cancel_sem_poison_addr) begin
      poison_consumed++;
      if (t.id != cfg.cancel_sem_poison_id) poison_id_mismatch++;
    end
    if (t.id == cfg.cancel_sem_original_id && t.addr == cfg.cancel_sem_original_addr)
      original_completed++;
  endfunction

  function void write_cancel_rxflit(aou_flit_item it);
    cancelled_h0 += it.n_cancel_h0;
    cancelled_h1 += it.n_cancel_h1;
    valid_cancel += it.n_cancel_valid;
  endfunction

  protected function void fail(string msg);
    aou_rule_pkg::aou_rule_log::fire("T1-L48", get_type_name());
    `uvm_error(get_type_name(), {"T1-L48: ", msg})
  endfunction

  function void check_phase(uvm_phase phase);
    bit good;
    super.check_phase(phase);
    if (cfg.cancel_sem_mode == 0) return;
    aou_rule_pkg::aou_rule_log::check("T1-L48", get_type_name());
    if (cfg.cancel_sem_mode == 4) begin
      good = poison_consumed == 1 && poison_id_mismatch == 0;
      if (!good) fail("delivered poison control was not observed exactly once at the DUT M port");
    end else begin
      good = original_completed == 1 && poison_consumed == 0;
      if (cfg.cancel_sem_mode == 1) good &= cancelled_h0 > 0;
      if (cfg.cancel_sem_mode == 2) good &= cancelled_h0 > 0 && valid_cancel > 0;
      if (cfg.cancel_sem_mode == 3) good &= cancelled_h1 > 0;
      if (!good)
        fail($sformatf("mode=%0d original=%0d poison=%0d id_mismatch=%0d H0=%0d H1=%0d VALID=%0d",
                       cfg.cancel_sem_mode, original_completed, poison_consumed,
                       poison_id_mismatch, cancelled_h0, cancelled_h1, valid_cancel));
    end
    `uvm_info(get_type_name(), $sformatf({"mode=%0d original_completed=%0d poison_consumed=%0d ",
              "poison_id_mismatch=%0d cancel_H0=%0d cancel_H1=%0d valid_cancel=%0d"},
              cfg.cancel_sem_mode, original_completed, poison_consumed, poison_id_mismatch,
              cancelled_h0, cancelled_h1, valid_cancel), UVM_LOW)
  endfunction
endclass
