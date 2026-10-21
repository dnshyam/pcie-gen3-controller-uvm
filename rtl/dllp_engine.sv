//=============================================================================
// File: dllp_engine.sv
// Description: PCIe Gen 3 Flow Control Initialization & DLLP Engine with Arbitration
// Standard: PCI Express Base Specification Revision 3.0 Section 3.4 & 3.6
//=============================================================================

`ifndef DLLP_ENGINE_SV
`define DLLP_ENGINE_SV

`include "pcie_pkg.sv"
`include "dllp_crc16.sv"

module dllp_engine #(
  parameter int UPDATE_FC_INTERVAL = 1000 // Clock cycles between periodic UpdateFC DLLPs
)(
  input  logic clk,
  input  logic rst_n,

  // Link Status (from PHY / LTSSM)
  input  logic link_up_i,

  // Local Initial Credits (to advertise during FC_INIT1/2)
  input  logic [7:0]  local_p_hdr_init_i,
  input  logic [11:0] local_p_data_init_i,
  input  logic [7:0]  local_np_hdr_init_i,
  input  logic [11:0] local_np_data_init_i,
  input  logic [7:0]  local_cpl_hdr_init_i,
  input  logic [11:0] local_cpl_data_init_i,

  // Local Current Credits (to advertise during ACTIVE UpdateFC)
  input  logic [7:0]  local_p_hdr_curr_i,
  input  logic [11:0] local_p_data_curr_i,
  input  logic [7:0]  local_np_hdr_curr_i,
  input  logic [11:0] local_np_data_curr_i,
  input  logic [7:0]  local_cpl_hdr_curr_i,
  input  logic [11:0] local_cpl_data_curr_i,

  // Partner Advertised Credits (output to Transaction Layer)
  output logic [7:0]  remote_p_hdr_credits_o,
  output logic [11:0] remote_p_data_credits_o,
  output logic [7:0]  remote_np_hdr_credits_o,
  output logic [11:0] remote_np_data_credits_o,
  output logic [7:0]  remote_cpl_hdr_credits_o,
  output logic [11:0] remote_cpl_data_credits_o,

  // Data Link Layer & Flow Control State
  output pcie_pkg::dl_state_e dl_state_o,
  output logic                fc_init_done_o,

  // Inbound DLLP Stream (from PHY / Rx Checker)
  input  logic        rx_dllp_val_i,
  input  logic [47:0] rx_dllp_data_i,

  // DLLP Rx Feedback (to Replay Buffer)
  output logic        ack_rcvd_o,
  output logic [11:0] ack_seq_o,
  output logic        nak_rcvd_o,
  output logic [11:0] nak_seq_o,

  // Immediate DLLP Tx Requests (from Rx TLP Checker)
  input  logic        send_ack_req_i,
  input  logic [11:0] send_ack_seq_i,
  input  logic        send_nak_req_i,
  input  logic [11:0] send_nak_seq_i,

  // Outbound TLP Stream (from Transaction Layer / Replay Buffer)
  input  logic                     in_tlp_val_i,
  input  pcie_pkg::tlp_unpacked_s  in_tlp_i,
  input  logic                     in_tlp_is_replay_i,
  output logic                     in_tlp_rdy_o,

  // Arbitrated Outbound Stream (to MAC / Physical Layer Framing)
  output logic                     out_frame_val_o,
  output logic                     out_frame_is_dllp_o,
  output logic [47:0]              out_dllp_data_o,
  output pcie_pkg::tlp_unpacked_s  out_tlp_data_o,
  output logic                     out_tlp_is_replay_o,
  input  logic                     out_frame_rdy_i
);
  import pcie_pkg::*;

  /* verilator lint_off UNUSEDSIGNAL */

  //---------------------------------------------------------------------------
  // Flow Control Initialization FSM States
  //---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    FC_S_IDLE   = 2'b00,
    FC_S_INIT1  = 2'b01,
    FC_S_INIT2  = 2'b10,
    FC_S_ACTIVE = 2'b11
  } fc_fsm_e;

  fc_fsm_e fc_state_q, fc_state_d;

  // Tracking reception of partner FC initialization
  logic rcvd_fc1_p_q,   rcvd_fc1_p_d;
  logic rcvd_fc1_np_q,  rcvd_fc1_np_d;
  logic rcvd_fc1_cpl_q, rcvd_fc1_cpl_d;

  logic rcvd_fc2_p_q,   rcvd_fc2_p_d;
  logic rcvd_fc2_np_q,  rcvd_fc2_np_d;
  logic rcvd_fc2_cpl_q, rcvd_fc2_cpl_d;

  // Remote Credit Storage Registers
  logic [7:0]  rem_p_hdr_q,   rem_p_hdr_d;
  logic [11:0] rem_p_data_q,  rem_p_data_d;
  logic [7:0]  rem_np_hdr_q,  rem_np_hdr_d;
  logic [11:0] rem_np_data_q, rem_np_data_d;
  logic [7:0]  rem_cpl_hdr_q, rem_cpl_hdr_d;
  logic [11:0] rem_cpl_data_q,rem_cpl_data_d;

  assign remote_p_hdr_credits_o   = rem_p_hdr_q;
  assign remote_p_data_credits_o  = rem_p_data_q;
  assign remote_np_hdr_credits_o  = rem_np_hdr_q;
  assign remote_np_data_credits_o = rem_np_data_q;
  assign remote_cpl_hdr_credits_o = rem_cpl_hdr_q;
  assign remote_cpl_data_credits_o= rem_cpl_data_q;

  assign fc_init_done_o = (fc_state_q == FC_S_ACTIVE);
  assign dl_state_o     = (fc_state_q == FC_S_ACTIVE) ? DL_ACTIVE :
                          (fc_state_q == FC_S_IDLE)   ? DL_INACTIVE : DL_INIT;

  // Round-robin index for FC DLLP transmission: 0=P, 1=NP, 2=CPL
  logic [1:0] fc_tx_type_q, fc_tx_type_d;

  // Periodic UpdateFC Counter
  logic [31:0] update_timer_q, update_timer_d;
  logic        trigger_update_fc;

  //---------------------------------------------------------------------------
  // Inbound DLLP CRC Check & Parser Instance
  //---------------------------------------------------------------------------
  logic        rx_crc_val_o;
  logic [31:0] rx_crc_payload_o;
  logic        rx_crc_err_o;

  logic        unused_rx_tx_val;
  logic [47:0] unused_rx_tx_dllp;

  dllp_crc16 u_rx_dllp_crc (
    .clk          (clk),
    .rst_n        (rst_n),
    .tx_val_i     (1'b0),
    .tx_data_i    (32'h0),
    .tx_val_o     (unused_rx_tx_val),
    .tx_dllp_o    (unused_rx_tx_dllp),
    .rx_val_i     (rx_dllp_val_i),
    .rx_dllp_i    (rx_dllp_data_i),
    .rx_val_o     (rx_crc_val_o),
    .rx_payload_o (rx_crc_payload_o),
    .rx_crc_err_o (rx_crc_err_o)
  );

  // Registered Ack / Nak outputs
  logic        ack_rcvd_q, ack_rcvd_d;
  logic [11:0] ack_seq_q,  ack_seq_d;
  logic        nak_rcvd_q, nak_rcvd_d;
  logic [11:0] nak_seq_q,  nak_seq_d;

  assign ack_rcvd_o = ack_rcvd_q;
  assign ack_seq_o  = ack_seq_q;
  assign nak_rcvd_o = nak_rcvd_q;
  assign nak_seq_o  = nak_seq_q;

  // Parse Received DLLPs
  always_comb begin
    rcvd_fc1_p_d   = rcvd_fc1_p_q;
    rcvd_fc1_np_d  = rcvd_fc1_np_q;
    rcvd_fc1_cpl_d = rcvd_fc1_cpl_q;

    rcvd_fc2_p_d   = rcvd_fc2_p_q;
    rcvd_fc2_np_d  = rcvd_fc2_np_q;
    rcvd_fc2_cpl_d = rcvd_fc2_cpl_q;

    rem_p_hdr_d    = rem_p_hdr_q;
    rem_p_data_d   = rem_p_data_q;
    rem_np_hdr_d   = rem_np_hdr_q;
    rem_np_data_d  = rem_np_data_q;
    rem_cpl_hdr_d  = rem_cpl_hdr_q;
    rem_cpl_data_d = rem_cpl_data_q;

    ack_rcvd_d     = 1'b0;
    ack_seq_d      = ack_seq_q;
    nak_rcvd_d     = 1'b0;
    nak_seq_d      = nak_seq_q;

    if (rx_crc_val_o && !rx_crc_err_o) begin
      case (rx_crc_payload_o[31:24])
        DLLP_ACK: begin
          ack_rcvd_d = 1'b1;
          ack_seq_d  = rx_crc_payload_o[11:0];
        end
        DLLP_NAK: begin
          nak_rcvd_d = 1'b1;
          nak_seq_d  = rx_crc_payload_o[11:0];
        end
        DLLP_INITFC1_P: begin
          rcvd_fc1_p_d = 1'b1;
          rem_p_hdr_d  = rx_crc_payload_o[21:14];
          rem_p_data_d = rx_crc_payload_o[11:0];
        end
        DLLP_INITFC1_NP: begin
          rcvd_fc1_np_d = 1'b1;
          rem_np_hdr_d  = rx_crc_payload_o[21:14];
          rem_np_data_d = rx_crc_payload_o[11:0];
        end
        DLLP_INITFC1_CPL: begin
          rcvd_fc1_cpl_d = 1'b1;
          rem_cpl_hdr_d  = rx_crc_payload_o[21:14];
          rem_cpl_data_d = rx_crc_payload_o[11:0];
        end
        DLLP_INITFC2_P: begin
          rcvd_fc2_p_d = 1'b1;
          rem_p_hdr_d  = rx_crc_payload_o[21:14];
          rem_p_data_d = rx_crc_payload_o[11:0];
        end
        DLLP_INITFC2_NP: begin
          rcvd_fc2_np_d = 1'b1;
          rem_np_hdr_d  = rx_crc_payload_o[21:14];
          rem_np_data_d = rx_crc_payload_o[11:0];
        end
        DLLP_INITFC2_CPL: begin
          rcvd_fc2_cpl_d = 1'b1;
          rem_cpl_hdr_d  = rx_crc_payload_o[21:14];
          rem_cpl_data_d = rx_crc_payload_o[11:0];
        end
        DLLP_UPDATEFC_P: begin
          rem_p_hdr_d  = rx_crc_payload_o[21:14];
          rem_p_data_d = rx_crc_payload_o[11:0];
        end
        DLLP_UPDATEFC_NP: begin
          rem_np_hdr_d  = rx_crc_payload_o[21:14];
          rem_np_data_d = rx_crc_payload_o[11:0];
        end
        DLLP_UPDATEFC_CPL: begin
          rem_cpl_hdr_d  = rx_crc_payload_o[21:14];
          rem_cpl_data_d = rx_crc_payload_o[11:0];
        end
        default: ;
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // Flow Control Initialization State Machine
  //---------------------------------------------------------------------------
  always_comb begin
    fc_state_d = fc_state_q;

    case (fc_state_q)
      FC_S_IDLE: begin
        if (link_up_i) begin
          fc_state_d = FC_S_INIT1;
        end
      end

      FC_S_INIT1: begin
        if (!link_up_i) begin
          fc_state_d = FC_S_IDLE;
        end else if (rcvd_fc1_p_q && rcvd_fc1_np_q && rcvd_fc1_cpl_q) begin
          fc_state_d = FC_S_INIT2;
        end
      end

      FC_S_INIT2: begin
        if (!link_up_i) begin
          fc_state_d = FC_S_IDLE;
        end else if (rcvd_fc2_p_q && rcvd_fc2_np_q && rcvd_fc2_cpl_q) begin
          fc_state_d = FC_S_ACTIVE;
        end
      end

      FC_S_ACTIVE: begin
        if (!link_up_i) begin
          fc_state_d = FC_S_IDLE;
        end
      end

      default: fc_state_d = FC_S_IDLE;
    endcase
  end

  // Periodic Update Timer
  assign trigger_update_fc = (update_timer_q >= 32'(UPDATE_FC_INTERVAL));

  always_comb begin
    update_timer_d = update_timer_q;
    if ((fc_state_q != FC_S_ACTIVE) || trigger_update_fc) begin
      update_timer_d = '0;
    end else begin
      update_timer_d = update_timer_q + 1'b1;
    end
  end

  //---------------------------------------------------------------------------
  // Outbound DLLP Candidate Generation
  //---------------------------------------------------------------------------
  logic        dllp_cand_val;
  logic [31:0] dllp_cand_payload;

  // Helper function to build 32-bit DLLP payload
  function automatic logic [31:0] build_dllp_payload(
    input logic [7:0]  p_type,
    input logic [1:0]  h_scale,
    input logic [7:0]  h_fc,
    input logic [1:0]  d_scale,
    input logic [11:0] d_fc
  );
    return {p_type, h_scale, h_fc, d_scale, d_fc};
  endfunction

  always_comb begin
    dllp_cand_val     = 1'b0;
    dllp_cand_payload = 32'h0;
    fc_tx_type_d      = fc_tx_type_q;

    // Highest DLLP Priority: Pending Ack / Nak
    if (send_ack_req_i) begin
      dllp_cand_val     = 1'b1;
      dllp_cand_payload = {DLLP_ACK, 8'h00, 4'h0, send_ack_seq_i};
    end else if (send_nak_req_i) begin
      dllp_cand_val     = 1'b1;
      dllp_cand_payload = {DLLP_NAK, 8'h00, 4'h0, send_nak_seq_i};
    end else begin
      // Flow Control DLLP Generation
      case (fc_state_q)
        FC_S_INIT1: begin
          dllp_cand_val = 1'b1;
          case (fc_tx_type_q)
            2'd0: dllp_cand_payload = build_dllp_payload(DLLP_INITFC1_P,   2'b00, local_p_hdr_init_i,   2'b00, local_p_data_init_i);
            2'd1: dllp_cand_payload = build_dllp_payload(DLLP_INITFC1_NP,  2'b00, local_np_hdr_init_i,  2'b00, local_np_data_init_i);
            2'd2: dllp_cand_payload = build_dllp_payload(DLLP_INITFC1_CPL, 2'b00, local_cpl_hdr_init_i, 2'b00, local_cpl_data_init_i);
            default: ;
          endcase
          if (out_frame_rdy_i) begin
            fc_tx_type_d = (fc_tx_type_q == 2'd2) ? 2'd0 : (fc_tx_type_q + 1'b1);
          end
        end

        FC_S_INIT2: begin
          dllp_cand_val = 1'b1;
          case (fc_tx_type_q)
            2'd0: dllp_cand_payload = build_dllp_payload(DLLP_INITFC2_P,   2'b00, local_p_hdr_init_i,   2'b00, local_p_data_init_i);
            2'd1: dllp_cand_payload = build_dllp_payload(DLLP_INITFC2_NP,  2'b00, local_np_hdr_init_i,  2'b00, local_np_data_init_i);
            2'd2: dllp_cand_payload = build_dllp_payload(DLLP_INITFC2_CPL, 2'b00, local_cpl_hdr_init_i, 2'b00, local_cpl_data_init_i);
            default: ;
          endcase
          if (out_frame_rdy_i) begin
            fc_tx_type_d = (fc_tx_type_q == 2'd2) ? 2'd0 : (fc_tx_type_q + 1'b1);
          end
        end

        FC_S_ACTIVE: begin
          if (trigger_update_fc) begin
            dllp_cand_val = 1'b1;
            case (fc_tx_type_q)
              2'd0: dllp_cand_payload = build_dllp_payload(DLLP_UPDATEFC_P,   2'b00, local_p_hdr_curr_i,   2'b00, local_p_data_curr_i);
              2'd1: dllp_cand_payload = build_dllp_payload(DLLP_UPDATEFC_NP,  2'b00, local_np_hdr_curr_i,  2'b00, local_np_data_curr_i);
              2'd2: dllp_cand_payload = build_dllp_payload(DLLP_UPDATEFC_CPL, 2'b00, local_cpl_hdr_curr_i, 2'b00, local_cpl_data_curr_i);
              default: ;
            endcase
            if (out_frame_rdy_i) begin
              fc_tx_type_d = (fc_tx_type_q == 2'd2) ? 2'd0 : (fc_tx_type_q + 1'b1);
            end
          end
        end

        default: ;
      endcase
    end
  end

  // Outbound CRC-16 Generator Instance
  logic        tx_crc_val_o;
  logic [47:0] tx_crc_dllp_o;

  logic        unused_tx_rx_val;
  logic [31:0] unused_tx_rx_payload;
  logic        unused_tx_rx_err;

  dllp_crc16 u_tx_dllp_crc (
    .clk          (clk),
    .rst_n        (rst_n),
    .tx_val_i     (dllp_cand_val),
    .tx_data_i    (dllp_cand_payload),
    .tx_val_o     (tx_crc_val_o),
    .tx_dllp_o    (tx_crc_dllp_o),
    .rx_val_i     (1'b0),
    .rx_dllp_i    (48'h0),
    .rx_val_o     (unused_tx_rx_val),
    .rx_payload_o (unused_tx_rx_payload),
    .rx_crc_err_o (unused_tx_rx_err)
  );

  //---------------------------------------------------------------------------
  // Arbitration between Outbound DLLP and TLP
  // Priority 1: DLLPs (Ack/Nak, InitFC, UpdateFC)
  // Priority 2: TLPs (from Replay Buffer or Transaction Layer)
  //---------------------------------------------------------------------------
  always_comb begin
    in_tlp_rdy_o = 1'b0;

    if (tx_crc_val_o) begin
      // DLLP takes strict priority
      in_tlp_rdy_o = 1'b0;
    end else if (fc_state_q == FC_S_ACTIVE) begin
      // TLPs permitted only when FC is active and link is ready
      in_tlp_rdy_o = out_frame_rdy_i;
    end
  end

  // Registered Output Stage
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      out_frame_val_o     <= 1'b0;
      out_frame_is_dllp_o <= 1'b0;
      out_dllp_data_o     <= '0;
      out_tlp_data_o      <= '0;
      out_tlp_is_replay_o <= 1'b0;
    end else begin
      if (out_frame_rdy_i) begin
        if (tx_crc_val_o) begin
          // Emit DLLP
          out_frame_val_o     <= 1'b1;
          out_frame_is_dllp_o <= 1'b1;
          out_dllp_data_o     <= tx_crc_dllp_o;
          out_tlp_data_o      <= '0;
          out_tlp_is_replay_o <= 1'b0;
        end else if (in_tlp_val_i && (fc_state_q == FC_S_ACTIVE)) begin
          // Emit TLP
          out_frame_val_o     <= 1'b1;
          out_frame_is_dllp_o <= 1'b0;
          out_dllp_data_o     <= '0;
          out_tlp_data_o      <= in_tlp_i;
          out_tlp_is_replay_o <= in_tlp_is_replay_i;
        end else begin
          out_frame_val_o     <= 1'b0;
          out_frame_is_dllp_o <= 1'b0;
          out_dllp_data_o     <= '0;
          out_tlp_data_o      <= '0;
          out_tlp_is_replay_o <= 1'b0;
        end
      end
    end
  end

  //---------------------------------------------------------------------------
  // Synchronous State Register Updates
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fc_state_q     <= FC_S_IDLE;
      rcvd_fc1_p_q   <= 1'b0;
      rcvd_fc1_np_q  <= 1'b0;
      rcvd_fc1_cpl_q <= 1'b0;
      rcvd_fc2_p_q   <= 1'b0;
      rcvd_fc2_np_q  <= 1'b0;
      rcvd_fc2_cpl_q <= 1'b0;
      rem_p_hdr_q    <= '0;
      rem_p_data_q   <= '0;
      rem_np_hdr_q   <= '0;
      rem_np_data_q  <= '0;
      rem_cpl_hdr_q  <= '0;
      rem_cpl_data_q <= '0;
      fc_tx_type_q   <= 2'd0;
      update_timer_q <= '0;
      ack_rcvd_q     <= 1'b0;
      ack_seq_q      <= '0;
      nak_rcvd_q     <= 1'b0;
      nak_seq_q      <= '0;
    end else begin
      fc_state_q     <= fc_state_d;
      rcvd_fc1_p_q   <= rcvd_fc1_p_d;
      rcvd_fc1_np_q  <= rcvd_fc1_np_d;
      rcvd_fc1_cpl_q <= rcvd_fc1_cpl_d;
      rcvd_fc2_p_q   <= rcvd_fc2_p_d;
      rcvd_fc2_np_q  <= rcvd_fc2_np_d;
      rcvd_fc2_cpl_q <= rcvd_fc2_cpl_d;
      rem_p_hdr_q    <= rem_p_hdr_d;
      rem_p_data_q   <= rem_p_data_d;
      rem_np_hdr_q   <= rem_np_hdr_d;
      rem_np_data_q  <= rem_np_data_d;
      rem_cpl_hdr_q  <= rem_cpl_hdr_d;
      rem_cpl_data_q <= rem_cpl_data_d;
      fc_tx_type_q   <= fc_tx_type_d;
      update_timer_q <= update_timer_d;
      ack_rcvd_q     <= ack_rcvd_d;
      ack_seq_q      <= ack_seq_d;
      nak_rcvd_q     <= nak_rcvd_d;
      nak_seq_q      <= nak_seq_d;
    end
  end

endmodule : dllp_engine

`endif // DLLP_ENGINE_SV
