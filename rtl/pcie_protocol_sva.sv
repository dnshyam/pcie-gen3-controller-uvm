//=============================================================================
// File: pcie_protocol_sva.sv
// Description: Protocol SystemVerilog Assertions (SVA) for PCIe Gen 3 Controller
// Standard: PCI Express Base Specification Revision 3.0
//=============================================================================

`ifndef PCIE_PROTOCOL_SVA_SV
`define PCIE_PROTOCOL_SVA_SV

`include "pcie_pkg.sv"

module pcie_protocol_sva #(
  parameter int MAX_PAYLOAD_BYTES  = 128,
  parameter int MAX_PAYLOAD_DW     = MAX_PAYLOAD_BYTES / 4, // 32 DWs
  parameter int REPLAY_TIMEOUT_CYC = 25000
)(
  input logic clk,
  input logic rst_n,

  // Link Status & State
  input logic                      link_active,
  input pcie_pkg::dl_state_e       dl_state,
  input logic                      fc_init_done,

  // Credit Signals
  input logic [7:0]                rem_p_hdr,
  input logic [11:0]               rem_p_data,
  input logic [7:0]                rem_np_hdr,
  input logic [11:0]               rem_np_data,
  input logic [7:0]                rem_cpl_hdr,
  input logic [11:0]               rem_cpl_data,

  input logic [7:0]                ph_consumed,
  input logic [11:0]               pd_consumed,
  input logic [7:0]                nph_consumed,
  input logic [11:0]               npd_consumed,
  input logic [7:0]                cplh_consumed,
  input logic [11:0]               cpld_consumed,

  // TLP Engine <-> Replay Buffer
  input logic                      tlp_to_replay_val,
  input pcie_pkg::tlp_unpacked_s   tlp_to_replay_data,
  input logic                      tlp_to_replay_rdy,

  // Replay Buffer Status & Counters
  input logic                      buffer_full,
  input logic                      replay_in_progress,
  input logic                      replay_rollover_err,
  input logic [11:0]               next_trans_seq,
  input logic [11:0]               ackd_seq,
  input logic [31:0]               replay_timer,
  input logic [6:0]                replay_occupancy,

  // Feedback to Replay Buffer
  input logic                      ack_rcvd,
  input logic [11:0]               ack_seq,
  input logic                      nak_rcvd,
  input logic [11:0]               nak_seq,

  // DLLP Engine Candidate & CRC Status
  input logic                      dllp_tx_crc_val,
  input logic                      replay_to_arb_val,

  // Subsystem Outbound Frame
  input logic                      out_frame_val,
  input logic                      out_frame_is_dllp,
  input logic [47:0]               out_dllp_data,
  input pcie_pkg::tlp_unpacked_s   out_tlp_data,
  input logic                      out_tlp_is_replay,
  input logic                      out_frame_rdy
);
  import pcie_pkg::*;

  /* verilator lint_off SYNCASYNCNET */
  // Default Clocking for Concurrent SVA
  default clocking cb_sva @(posedge clk); endclocking
`ifndef VERILATOR
  default disable iff (!rst_n);
`endif
  /* verilator lint_on SYNCASYNCNET */

  //---------------------------------------------------------------------------
  // 1. TLP Framing Assertions
  //---------------------------------------------------------------------------

  // Assert no outbound TLP payload exceeds the 128-byte (32 DW) ceiling
  property p_tlp_out_max_payload;
    out_frame_val && !out_frame_is_dllp |-> (out_tlp_data.length <= 10'(MAX_PAYLOAD_DW));
  endproperty
  assert_tlp_out_max_payload: assert property (p_tlp_out_max_payload)
    else $error("[SVA_ERROR] Outbound TLP length (%0d DWs) exceeds 128B ceiling (%0d DWs)!",
                out_tlp_data.length, MAX_PAYLOAD_DW);

  // Assert TLP handed to Replay Buffer adheres to 128B ceiling
  property p_tlp_to_replay_max_payload;
    tlp_to_replay_val |-> (tlp_to_replay_data.length <= 10'(MAX_PAYLOAD_DW));
  endproperty
  assert_tlp_to_replay_max_payload: assert property (p_tlp_to_replay_max_payload)
    else $error("[SVA_ERROR] TLP to replay buffer length (%0d DWs) exceeds 128B ceiling!",
                tlp_to_replay_data.length);

  // Assert TLPs are never transmitted prior to Flow Control initialization
  property p_no_tlp_before_fc_active;
    out_frame_val && !out_frame_is_dllp |-> fc_init_done;
  endproperty
  assert_no_tlp_before_fc_active: assert property (p_no_tlp_before_fc_active)
    else $error("[SVA_ERROR] TLP transmitted before Flow Control initialization was ACTIVE!");

  //---------------------------------------------------------------------------
  // 2. Credit Invariant Assertions (Underflow Prevention)
  //---------------------------------------------------------------------------

  // Helper wires: Modulo credit difference (Limit - Consumed)
  wire [7:0]  avail_ph_diff   = rem_p_hdr   - ph_consumed;
  wire [11:0] avail_pd_diff   = rem_p_data  - pd_consumed;
  wire [7:0]  avail_nph_diff  = rem_np_hdr  - nph_consumed;
  wire [7:0]  avail_cplh_diff = rem_cpl_hdr - cplh_consumed;
  wire [11:0] avail_cpld_diff = rem_cpl_data- cpld_consumed;

  // Assert available credit count never rolls under into upper modulo hemisphere
  property p_posted_hdr_credit_no_underflow;
    fc_init_done |-> (avail_ph_diff <= 8'd128);
  endproperty
  assert_posted_hdr_credit_no_underflow: assert property (p_posted_hdr_credit_no_underflow)
    else $error("[SVA_ERROR] Posted Header credit underflow detected! (Limit=%0d, Consumed=%0d)",
                rem_p_hdr, ph_consumed);

  property p_posted_data_credit_no_underflow;
    fc_init_done |-> (avail_pd_diff <= 12'd2048);
  endproperty
  assert_posted_data_credit_no_underflow: assert property (p_posted_data_credit_no_underflow)
    else $error("[SVA_ERROR] Posted Data credit underflow detected! (Limit=%0d, Consumed=%0d)",
                rem_p_data, pd_consumed);

  property p_non_posted_hdr_credit_no_underflow;
    fc_init_done |-> (avail_nph_diff <= 8'd128);
  endproperty
  assert_non_posted_hdr_credit_no_underflow: assert property (p_non_posted_hdr_credit_no_underflow)
    else $error("[SVA_ERROR] Non-Posted Header credit underflow detected! (Limit=%0d, Consumed=%0d)",
                rem_np_hdr, nph_consumed);

  // Assert Posted write transmission only occurs when sufficient credits exist (no underflow)
  property p_posted_write_has_credits;
    tlp_to_replay_val && ((tlp_to_replay_data.pkt_type == TLP_MWR32) || (tlp_to_replay_data.pkt_type == TLP_MWR64))
      |-> (avail_ph_diff <= 8'd128);
  endproperty
  assert_posted_write_has_credits: assert property (p_posted_write_has_credits)
    else $error("[SVA_ERROR] Posted Memory Write dispatched with credit underflow!");

  //---------------------------------------------------------------------------
  // 3. Replay Timer & Retransmission Invariant
  //---------------------------------------------------------------------------

  // Assert that replay timer expiration with pending packets triggers replay state
  property p_replay_timer_triggers_replay;
    rst_n && $past(rst_n) && (link_active && (replay_occupancy > 0) && (replay_timer >= 32'(REPLAY_TIMEOUT_CYC)))
      |=> (!rst_n || replay_in_progress || replay_rollover_err);
  endproperty
  assert_replay_timer_triggers_replay: assert property (p_replay_timer_triggers_replay)
    else $error("[SVA_ERROR] Replay timer expired with pending packets, but replay did not trigger!");

  // Assert that receiving a NAK when packets are pending enters replay state
  property p_nak_triggers_replay;
    rst_n && $past(rst_n) && (link_active && (replay_occupancy > 0) && nak_rcvd)
      |=> (!rst_n || replay_in_progress || replay_rollover_err);
  endproperty
  assert_nak_triggers_replay: assert property (p_nak_triggers_replay)
    else $error("[SVA_ERROR] NAK received with pending packets, but replay did not trigger!");

  //---------------------------------------------------------------------------
  // 4. Sequence Number Monotonicity (Modulo 4096)
  //---------------------------------------------------------------------------

  // Assert sequence number increments strictly by 1 mod 4096 on fresh packet acceptance
  property p_seq_num_increments_mod4096;
    rst_n && $past(rst_n) && (tlp_to_replay_val && tlp_to_replay_rdy)
      |=> (!rst_n || (next_trans_seq == (($past(next_trans_seq) + 12'd1) & 12'hFFF)));
  endproperty
  assert_seq_num_increments_mod4096: assert property (p_seq_num_increments_mod4096)
    else $error("[SVA_ERROR] Sequence number failed strict +1 mod 4096 step! (Was=%0d, Now=%0d)",
                $past(next_trans_seq), next_trans_seq);

  // Assert sequence number remains stable when no new packet is committed
  property p_seq_num_stable_when_idle;
    rst_n && $past(rst_n) && !(tlp_to_replay_val && tlp_to_replay_rdy)
      |=> (!rst_n || (next_trans_seq == $past(next_trans_seq)));
  endproperty
  assert_seq_num_stable_when_idle: assert property (p_seq_num_stable_when_idle)
    else $error("[SVA_ERROR] Sequence number mutated without packet transmission!");

  //---------------------------------------------------------------------------
  // 5. DLLP vs TLP Arbitration Priority
  //---------------------------------------------------------------------------

  // Assert DLLP takes strict priority over TLPs on outbound link
  property p_dllp_strict_priority;
    dllp_tx_crc_val && out_frame_val |-> out_frame_is_dllp;
  endproperty
  assert_dllp_strict_priority: assert property (p_dllp_strict_priority)
    else $error("[SVA_ERROR] Arbitration error! TLP transmitted while DLLP was pending!");

  //---------------------------------------------------------------------------
  // 6. Cover Properties (Functional Coverage of Corner Cases)
  //---------------------------------------------------------------------------

  // Cover: Maximum payload size (128 Bytes = 32 DWs) transmitted
  c_max_payload_tlp: cover property (
    out_frame_val && !out_frame_is_dllp && (out_tlp_data.length == 10'(MAX_PAYLOAD_DW))
  );

`ifndef VERILATOR
  // Cover: 12-bit Sequence Number rollover from 4095 (0xFFF) to 0
  c_seq_num_rollover: cover property (
    (next_trans_seq == 12'hFFF) && tlp_to_replay_val && tlp_to_replay_rdy
    ##1 (next_trans_seq == 12'h000)
  );
`else
  // Cover: 12-bit Sequence Number rollover from 4095 (0xFFF) to 0
  c_seq_num_rollover: cover property (
    (next_trans_seq == 12'hFFF) && tlp_to_replay_val && tlp_to_replay_rdy
  );
`endif

  // Cover: Successful Flow Control Initialization to ACTIVE state
  c_fc_init_done: cover property (
    $rose(fc_init_done)
  );

  // Cover: Replay sequence triggered
  c_replay_event: cover property (
    $rose(replay_in_progress)
  );

  // Cover: Simultaneous DLLP and TLP arbitration conflict resolved in favor of DLLP
  c_arbitration_dllp_over_tlp: cover property (
    dllp_tx_crc_val && replay_to_arb_val && out_frame_val && out_frame_is_dllp
  );

  // Cover: Buffer full condition reached
  c_replay_buffer_full: cover property (
    $rose(buffer_full)
  );

  // Cover: Credit return pulse generated
  c_credit_return_pulse: cover property (
    tlp_to_replay_val && ack_rcvd
  );

endmodule : pcie_protocol_sva

//-----------------------------------------------------------------------------
// Direct Bind Statement to pcie_controller_top
//-----------------------------------------------------------------------------
bind pcie_controller_top pcie_protocol_sva #(
  .MAX_PAYLOAD_BYTES  (MAX_PAYLOAD_BYTES),
  .REPLAY_TIMEOUT_CYC (25000)
) u_pcie_protocol_sva (
  .clk                 (clk),
  .rst_n               (rst_n),
  .link_active         (link_active),
  .dl_state            (dl_state),
  .fc_init_done        (fc_init_done),
  .rem_p_hdr           (rem_p_hdr),
  .rem_p_data          (rem_p_data),
  .rem_np_hdr          (rem_np_hdr),
  .rem_np_data         (rem_np_data),
  .rem_cpl_hdr         (rem_cpl_hdr),
  .rem_cpl_data        (rem_cpl_data),
  .ph_consumed         (u_tlp_engine.ph_consumed_q),
  .pd_consumed         (u_tlp_engine.pd_consumed_q),
  .nph_consumed        (u_tlp_engine.nph_consumed_q),
  .npd_consumed        (u_tlp_engine.npd_consumed_q),
  .cplh_consumed       (u_tlp_engine.cplh_consumed_q),
  .cpld_consumed       (u_tlp_engine.cpld_consumed_q),
  .tlp_to_replay_val   (tlp_to_replay_val),
  .tlp_to_replay_data  (tlp_to_replay_data),
  .tlp_to_replay_rdy   (tlp_to_replay_rdy),
  .buffer_full         (buffer_full),
  .replay_in_progress  (replay_in_progress),
  .replay_rollover_err (replay_rollover_err),
  .next_trans_seq      (next_trans_seq),
  .ackd_seq            (ackd_seq),
  .replay_timer        (u_replay_buffer.replay_timer_q),
  .replay_occupancy    (u_replay_buffer.occupancy_q),
  .ack_rcvd            (ack_rcvd),
  .ack_seq             (ack_seq),
  .nak_rcvd            (nak_rcvd),
  .nak_seq             (nak_seq),
  .dllp_tx_crc_val     (u_dllp_engine.tx_crc_val_o),
  .replay_to_arb_val   (replay_to_arb_val),
  .out_frame_val       (out_frame_val),
  .out_frame_is_dllp   (out_frame_is_dllp),
  .out_dllp_data       (out_dllp_data),
  .out_tlp_data        (out_tlp_data),
  .out_tlp_is_replay   (out_tlp_is_replay),
  .out_frame_rdy       (out_frame_rdy)
);

`endif // PCIE_PROTOCOL_SVA_SV
