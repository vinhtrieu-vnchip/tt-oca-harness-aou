// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: © 2026 Tenstorrent USA Inc

// Bins tables of the env checkers' covergroups (aou_fc_macros.svh).
// aou_t1_crd_flow_chk: an RP held work of a class with no credit for it
// (starved), and an RP with credit and work of the class while another RP was
// starved.
`define AOU_T1_CRD_FC_CLS(B) `B``_VALS(c, 0, 4)
`define AOU_T1_CRD_FC_EV(B) `B``_BIN(starved, 0, 0) `B``_BIN(eligible_beside_starved, 1, 1) \
  `B``_BIN(exact_finite_budget, 2, 2)
// aou_t1_early_tbl_chk: the early table filled (an AW held), and a held AW
// was accepted once an entry was freed.
`define AOU_T1_EARLY_FC_EV(B) `B``_BIN(full_stall, 0, 0) `B``_BIN(stall_resumed, 1, 1)
// DG04 stimulus-quality observations. Reachability is reported as functional
// coverage, not as a protocol or DUT correctness failure.
`define AOU_T1_DG04_FC_EVENT(B) \
  `B``_BIN(contention_eligible, 0, 0) \
  `B``_BIN(service_under_contention, 1, 1) \
  `B``_BIN(global_b_stall_entry, 2, 2) \
  `B``_BIN(global_b_sustained_stall, 3, 3) \
  `B``_BIN(global_b_stall_release, 4, 4) \
  `B``_BIN(stability_check_active, 5, 5)
`define AOU_T1_DG04_FC_RP(B) `B``_VALS(source_rp, 0, 4)
// aou_t1_crd_rr_chk: RPs owed credit when a test opened a round-robin window.
`define AOU_T1_RR_FC_OWED(B) `B``_BIN(under_two, 0, 1) `B``_VALS(rps, 2, 4)

// Accepted physical credit events, independent of eligibility/stimulus intent.
`define AOU_T1_EXACT_FC_RP(B) `B``_VALS(rp, 0, 3)
`define AOU_T1_EXACT_FC_EV(B) \
  `B``_BIN(grant, 0, 0) `B``_BIN(admit, 1, 1) `B``_BIN(exhausted, 2, 2) \
  `B``_BIN(saturated, 3, 3) `B``_BIN(same_flit, 4, 4) `B``_BIN(split_grant, 5, 5)
