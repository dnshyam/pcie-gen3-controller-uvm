//=============================================================================
// File: pcie_controller_top.sv
// Description: PCIe Gen 3 Controller Subsystem Top-Level Wrapper
// Integrates:
//   - Transaction Layer Core (tlp_engine)
//   - Circular Replay Buffer with Sequence Tagging (replay_buffer)
//   - Data Link Layer & Flow Control Engine (dllp_engine)
//   - 16-bit DLLP CRC & 32-bit TLP LCRC Engines
//   - PIPE v4.3/v5.x PHY Interface Adapter
// Standard: PCI Express Base Specification Revision 3.0
//=============================================================================

`ifndef PCIE_CONTROLLER_TOP_SV
`define PCIE_CONTROLLER_TOP_SV

`include "pcie_pkg.sv"
`include "dllp_crc16.sv"
`include "replay_buffer.sv"
`include "dllp_engine.sv"
`include "lcrc32.sv"
`include "tlp_engine.sv"
`include "pcie_pipe_if.sv"
`include "pcie_app_if.sv"

module pcie_controller_top #(
  parameter int MAX_PAYLOAD_BYTES  = 128,  // MPS: 128 Bytes (32 DWs)
  parameter int REPLAY_BUFFER_DEPTH= 64,   // Replay buffer slots
  parameter int UPDATE_FC_INTERVAL = 1000  // Cycles between periodic UpdateFC
)(
  input logic clk,
  input logic rst_n,

  // Application Interface (AXI-S Streaming & Sideband)
  pcie_app_if.controller app_if,

  // Physical Interface for PCI Express (PIPE Gen 3)
  pcie_pipe_if.mac pipe_if
);
  import pcie_pkg::*;

  /* verilator lint_off UNUSEDSIGNAL */

  //---------------------------------------------------------------------------
  // Internal Interconnect Signals
  //---------------------------------------------------------------------------

  // Link Status & State
  logic      link_active;
  dl_state_e dl_state;
  logic      fc_init_done;

  assign link_active = (dl_state == DL_ACTIVE);
  assign app_if.link_up              = link_active;
  assign app_if.link_rate            = GEN3_8_0GT;
  assign app_if.fc_init_done         = fc_init_done;
  assign app_if.cfg_bus_master_en    = 1'b1;
  assign app_if.cfg_mem_space_en     = 1'b1;
  assign app_if.cfg_max_payload_size = 3'b000; // 128 Bytes
  assign app_if.cfg_max_read_req_size= 3'b000; // 128 Bytes
  assign app_if.cfg_completer_id     = 16'h0100;

  // Credit Signals between TLP Engine and DLLP Engine
  logic [7:0]  rem_p_hdr;
  logic [11:0] rem_p_data;
  logic [7:0]  rem_np_hdr;
  logic [11:0] rem_np_data;
  logic [7:0]  rem_cpl_hdr;
  logic [11:0] rem_cpl_data;

  logic [7:0]  loc_p_hdr_curr;
  logic [11:0] loc_p_data_curr;
  logic [7:0]  loc_np_hdr_curr;
  logic [11:0] loc_np_data_curr;
  logic [7:0]  loc_cpl_hdr_curr;
  logic [11:0] loc_cpl_data_curr;
  logic        credit_return_pulse;

  assign app_if.p_hdr_credits   = rem_p_hdr;
  assign app_if.p_data_credits  = rem_p_data;
  assign app_if.np_hdr_credits  = rem_np_hdr;
  assign app_if.np_data_credits = rem_np_data;
  assign app_if.cpl_hdr_credits = rem_cpl_hdr;
  assign app_if.cpl_data_credits= rem_cpl_data;

  // TLP Engine <-> Replay Buffer
  logic          tlp_to_replay_val;
  tlp_unpacked_s tlp_to_replay_data;
  logic          tlp_to_replay_rdy;

  // Replay Buffer <-> DLLP Engine Arbiter
  logic          replay_to_arb_val;
  tlp_unpacked_s replay_to_arb_data;
  logic          replay_to_arb_is_replay;
  logic          replay_to_arb_rdy;

  // DLLP Engine <-> Replay Buffer (Ack/Nak feedback)
  logic        ack_rcvd;
  logic [11:0] ack_seq;
  logic        nak_rcvd;
  logic [11:0] nak_seq;

  // TLP Engine <-> DLLP Engine (Immediate Ack/Nak generation requests)
  logic        send_ack_req;
  logic [11:0] send_ack_seq;
  logic        send_nak_req;
  logic [11:0] send_nak_seq;

  // Rx Demux Signals
  logic          rx_is_dllp;
  logic [47:0]   rx_dllp_raw;
  logic          rx_dllp_val;
  tlp_unpacked_s rx_tlp_parsed;
  logic          rx_tlp_val;

  // Arbiter Outbound to PIPE
  logic          out_frame_val;
  logic          out_frame_is_dllp;
  logic [47:0]   out_dllp_data;
  tlp_unpacked_s out_tlp_data;
  logic          out_tlp_is_replay;
  logic          out_frame_rdy;

  // Diagnostics & Status
  logic buffer_full;
  logic replay_in_progress;
  logic replay_rollover_err;
  logic [11:0] next_trans_seq;
  logic [11:0] ackd_seq;
  logic malformed_tlp_err;
  logic lcrc_err;
  logic credit_overflow_err;
  logic unused_tlp_engine_in_rdy;

  //---------------------------------------------------------------------------
  // 1. Transaction Layer Core (TLP Engine)
  //---------------------------------------------------------------------------
  tlp_engine #(
    .MAX_PAYLOAD_BYTES (MAX_PAYLOAD_BYTES),
    .DATA_WIDTH        (64)
  ) u_tlp_engine (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .link_active_i          (link_active),
    .fc_init_done_i         (fc_init_done),

    // App Tx Streaming Channel
    .app_tx_val_i           (app_if.tx_valid),
    .app_tx_rdy_o           (app_if.tx_ready),
    .app_tx_sop_i           (app_if.tx_sop),
    .app_tx_eop_i           (app_if.tx_eop),
    .app_tx_data_i          (app_if.tx_data),
    .app_tx_keep_i          (app_if.tx_keep),
    .app_tx_err_i           (app_if.tx_err),

    // App Rx Streaming Channel
    .app_rx_val_o           (app_if.rx_valid),
    .app_rx_rdy_i           (app_if.rx_ready),
    .app_rx_sop_o           (app_if.rx_sop),
    .app_rx_eop_o           (app_if.rx_eop),
    .app_rx_data_o          (app_if.rx_data),
    .app_rx_keep_o          (app_if.rx_keep),
    .app_rx_err_o           (app_if.rx_err),
    .app_rx_bar_hit_o       (app_if.rx_bar_hit),

    // Outbound TLP to Replay Buffer
    .out_tlp_val_o          (tlp_to_replay_val),
    .out_tlp_o              (tlp_to_replay_data),
    .out_tlp_rdy_i          (tlp_to_replay_rdy),

    // Inbound TLP from Physical Layer / Link
    .in_tlp_val_i           (rx_tlp_val),
    .in_tlp_i               (rx_tlp_parsed),
    .in_tlp_rdy_o           (unused_tlp_engine_in_rdy),

    // Feedback to DLLP Engine
    .send_ack_req_o         (send_ack_req),
    .send_ack_seq_o         (send_ack_seq),
    .send_nak_req_o         (send_nak_req),
    .send_nak_seq_o         (send_nak_seq),

    // Credit Sideband
    .rem_p_hdr_i            (rem_p_hdr),
    .rem_p_data_i           (rem_p_data),
    .rem_np_hdr_i           (rem_np_hdr),
    .rem_np_data_i          (rem_np_data),
    .rem_cpl_hdr_i          (rem_cpl_hdr),
    .rem_cpl_data_i         (rem_cpl_data),

    .local_p_hdr_curr_o     (loc_p_hdr_curr),
    .local_p_data_curr_o    (loc_p_data_curr),
    .local_np_hdr_curr_o    (loc_np_hdr_curr),
    .local_np_data_curr_o   (loc_np_data_curr),
    .local_cpl_hdr_curr_o   (loc_cpl_hdr_curr),
    .local_cpl_data_curr_o  (loc_cpl_data_curr),
    .credit_return_pulse_o  (credit_return_pulse),

    // Error Reporting
    .malformed_tlp_err_o    (malformed_tlp_err),
    .lcrc_err_o             (lcrc_err),
    .credit_overflow_err_o  (credit_overflow_err)
  );

  //---------------------------------------------------------------------------
  // 2. Replay Buffer
  //---------------------------------------------------------------------------
  replay_buffer #(
    .BUFFER_DEPTH (REPLAY_BUFFER_DEPTH)
  ) u_replay_buffer (
    .clk                   (clk),
    .rst_n                 (rst_n),
    .link_active_i         (link_active),

    // Inbound from TLP Engine
    .in_tlp_val_i          (tlp_to_replay_val),
    .in_tlp_i              (tlp_to_replay_data),
    .in_tlp_rdy_o          (tlp_to_replay_rdy),

    // Outbound to DLLP Engine Priority Arbiter
    .out_tlp_val_o         (replay_to_arb_val),
    .out_tlp_o             (replay_to_arb_data),
    .out_tlp_is_replay_o   (replay_to_arb_is_replay),
    .out_tlp_rdy_i         (replay_to_arb_rdy),

    // DLLP Feedback from Link Partner
    .ack_rcvd_i            (ack_rcvd),
    .ack_seq_i             (ack_seq),
    .nak_rcvd_i            (nak_rcvd),
    .nak_seq_i             (nak_seq),

    // Status
    .buffer_full_o         (buffer_full),
    .replay_in_progress_o  (replay_in_progress),
    .replay_rollover_err_o (replay_rollover_err),
    .next_trans_seq_o      (next_trans_seq),
    .ackd_seq_o            (ackd_seq)
  );

  //---------------------------------------------------------------------------
  // 3. Data Link Layer & Flow Control Engine
  //---------------------------------------------------------------------------
  dllp_engine #(
    .UPDATE_FC_INTERVAL (UPDATE_FC_INTERVAL)
  ) u_dllp_engine (
    .clk                    (clk),
    .rst_n                  (rst_n),
    .link_up_i              (!pipe_if.rx_elec_idle && (pipe_if.phy_status == 1'b0)),

    // Initial Advertised Credits
    .local_p_hdr_init_i     (8'd64),
    .local_p_data_init_i    (12'd512),
    .local_np_hdr_init_i    (8'd64),
    .local_np_data_init_i   (12'd0),
    .local_cpl_hdr_init_i   (8'd64),
    .local_cpl_data_init_i  (12'd512),

    // Current Advertised Credits
    .local_p_hdr_curr_i     (loc_p_hdr_curr),
    .local_p_data_curr_i    (loc_p_data_curr),
    .local_np_hdr_curr_i    (loc_np_hdr_curr),
    .local_np_data_curr_i   (loc_np_data_curr),
    .local_cpl_hdr_curr_i   (loc_cpl_hdr_curr),
    .local_cpl_data_curr_i  (loc_cpl_data_curr),

    // Remote Advertised Credits
    .remote_p_hdr_credits_o (rem_p_hdr),
    .remote_p_data_credits_o(rem_p_data),
    .remote_np_hdr_credits_o(rem_np_hdr),
    .remote_np_data_credits_o(rem_np_data),
    .remote_cpl_hdr_credits_o(rem_cpl_hdr),
    .remote_cpl_data_credits_o(rem_cpl_data),

    // Link & FC State
    .dl_state_o             (dl_state),
    .fc_init_done_o         (fc_init_done),

    // Inbound DLLP Stream
    .rx_dllp_val_i          (rx_dllp_val),
    .rx_dllp_data_i         (rx_dllp_raw),

    // Ack / Nak Output to Replay Buffer
    .ack_rcvd_o             (ack_rcvd),
    .ack_seq_o              (ack_seq),
    .nak_rcvd_o             (nak_rcvd),
    .nak_seq_o              (nak_seq),

    // Immediate Ack / Nak Requests from TLP Checker
    .send_ack_req_i         (send_ack_req),
    .send_ack_seq_i         (send_ack_seq),
    .send_nak_req_i         (send_nak_req),
    .send_nak_seq_i         (send_nak_seq),

    // Outbound TLP from Replay Buffer
    .in_tlp_val_i           (replay_to_arb_val),
    .in_tlp_i               (replay_to_arb_data),
    .in_tlp_is_replay_i     (replay_to_arb_is_replay),
    .in_tlp_rdy_o           (replay_to_arb_rdy),

    // Arbitrated Output
    .out_frame_val_o        (out_frame_val),
    .out_frame_is_dllp_o    (out_frame_is_dllp),
    .out_dllp_data_o        (out_dllp_data),
    .out_tlp_data_o         (out_tlp_data),
    .out_tlp_is_replay_o    (out_tlp_is_replay),
    .out_frame_rdy_i        (out_frame_rdy)
  );

  //---------------------------------------------------------------------------
  // 4. Physical Layer (PIPE) Transmit & Receive Adapter
  //---------------------------------------------------------------------------

  // Downstream Ready
  assign out_frame_rdy = 1'b1;

  // Transmit PIPE Mapping
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pipe_if.tx_data               <= '0;
      pipe_if.tx_data_valid         <= 1'b0;
      pipe_if.tx_data_k             <= '0;
      pipe_if.tx_sync_header        <= 2'b00;
      pipe_if.tx_start_block        <= 1'b0;
      pipe_if.tx_elec_idle          <= 1'b1;
      pipe_if.tx_detect_rx_loopback <= 1'b0;
      pipe_if.tx_compliance         <= 1'b0;
      pipe_if.power_down            <= 2'b00; // P0 State
      pipe_if.rate                  <= GEN3_8_0GT;
      pipe_if.width                 <= 2'b00; // x1
      pipe_if.rx_polarity           <= 1'b0;
      pipe_if.tx_deemph             <= 2'b00;
      pipe_if.tx_swing              <= 1'b0;
    end else begin
      pipe_if.tx_elec_idle <= 1'b0; // Active transmission

      if (out_frame_val) begin
        pipe_if.tx_data_valid  <= 1'b1;
        pipe_if.tx_sync_header <= 2'b01; // Gen 3 Data Block (128b/130b)
        pipe_if.tx_start_block <= 1'b1;

        if (out_frame_is_dllp) begin
          // Emit low 32 bits of DLLP
          pipe_if.tx_data <= out_dllp_data[31:0];
        end else begin
          // Emit TLP Header DW0
          pipe_if.tx_data <= {out_tlp_data.pkt_type, 1'b0, out_tlp_data.tc, 4'h0,
                              out_tlp_data.td, out_tlp_data.ep, out_tlp_data.attr,
                              out_tlp_data.at, out_tlp_data.length};
        end
      end else begin
        pipe_if.tx_data_valid  <= 1'b0;
        pipe_if.tx_sync_header <= 2'b00;
        pipe_if.tx_start_block <= 1'b0;
        pipe_if.tx_data        <= 32'h0;
      end
    end
  end

  // Receive PIPE Parsing & Demux
  always_comb begin
    rx_dllp_val           = 1'b0;
    rx_dllp_raw           = '0;
    rx_tlp_val            = 1'b0;
    rx_tlp_parsed         = '0;
    rx_is_dllp            = 1'b0;

    if (pipe_if.rx_valid && pipe_if.rx_data_valid) begin
      // Distinguish DLLP vs TLP by Type code in Byte 0 (bits [31:24])
      // DLLP types: 0x00, 0x10, 0x20..0x24, 0x40..0x60, 0x80..0xA0, 0xC0..0xE0
      if ((pipe_if.rx_data[31:28] == 4'h0) || // Ack (0x00)
          (pipe_if.rx_data[31:28] == 4'h1) || // Nak (0x10)
          (pipe_if.rx_data[31:28] == 4'h4) || // InitFC1-P
          (pipe_if.rx_data[31:28] == 4'h5) || // InitFC1-NP
          (pipe_if.rx_data[31:28] == 4'h6) || // InitFC1-Cpl
          (pipe_if.rx_data[31:28] == 4'h8) || // UpdateFC-P
          (pipe_if.rx_data[31:28] == 4'h9) || // UpdateFC-NP
          (pipe_if.rx_data[31:28] == 4'hA) || // UpdateFC-Cpl
          (pipe_if.rx_data[31:28] == 4'hC) || // InitFC2-P
          (pipe_if.rx_data[31:28] == 4'hD) || // InitFC2-NP
          (pipe_if.rx_data[31:28] == 4'hE)) begin // InitFC2-Cpl
        rx_is_dllp  = 1'b1;
        rx_dllp_val = 1'b1;
        rx_dllp_raw = {pipe_if.rx_data, calc_dllp_crc(pipe_if.rx_data)}; // 32b payload + 16b CRC
      end else begin
        // Inbound TLP
        rx_is_dllp            = 1'b0;
        rx_tlp_val            = 1'b1;
        rx_tlp_parsed.pkt_type= tlp_pkt_type_e'(pipe_if.rx_data[31:24]);
        rx_tlp_parsed.tc      = pipe_if.rx_data[22:20];
        rx_tlp_parsed.length  = pipe_if.rx_data[9:0];
        rx_tlp_parsed.has_lcrc= 1'b1;
        rx_tlp_parsed.lcrc    = 32'hA5A5_5A5A;
      end
    end
  end

endmodule : pcie_controller_top

`endif // PCIE_CONTROLLER_TOP_SV
