//=============================================================================
// File: replay_buffer.sv
// Description: Dual-Port RAM Circular Replay Buffer for PCIe Gen 3 Data Link Layer
// Standard: PCI Express Base Specification Revision 3.0 Section 3.5.2
//=============================================================================

`ifndef REPLAY_BUFFER_SV
`define REPLAY_BUFFER_SV

`include "pcie_pkg.sv"

module replay_buffer #(
  parameter int BUFFER_DEPTH       = 64,
  parameter int ADDR_WIDTH         = $clog2(BUFFER_DEPTH),
  parameter int REPLAY_TIMEOUT_CYC = 25000 // Configurable replay timeout in clock cycles
)(
  input  logic clk,
  input  logic rst_n,

  // Link Status
  input  logic link_active_i,             // Link is active (DL_ACTIVE)

  // Inbound TLP from Transaction Layer
  input  logic                     in_tlp_val_i,
  input  pcie_pkg::tlp_unpacked_s  in_tlp_i,
  output logic                     in_tlp_rdy_o,

  // Outbound TLP to Arbiter / MAC Transmitter
  output logic                     out_tlp_val_o,
  output pcie_pkg::tlp_unpacked_s  out_tlp_o,
  output logic                     out_tlp_is_replay_o,
  input  logic                     out_tlp_rdy_i,

  // DLLP Feedback from Link Partner
  input  logic        ack_rcvd_i,
  input  logic [11:0] ack_seq_i,
  input  logic        nak_rcvd_i,
  input  logic [11:0] nak_seq_i,

  // Status & Error Flags
  output logic        buffer_full_o,
  output logic        replay_in_progress_o,
  output logic        replay_rollover_err_o,
  output logic [11:0] next_trans_seq_o,
  output logic [11:0] ackd_seq_o
);
  import pcie_pkg::*;

  /* verilator lint_off UNUSEDSIGNAL */

  //---------------------------------------------------------------------------
  // Internal State Machine
  //---------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_NORMAL  = 2'b00, // Normal operation: transmitting new TLPs
    S_REPLAY  = 2'b01, // Replaying unacknowledged TLPs from commit pointer
    S_ERROR   = 2'b10  // Fatal error: Replay counter exceeded limit (rollover)
  } replay_fsm_e;

  replay_fsm_e state_q, state_d;

  //---------------------------------------------------------------------------
  // Dual-Port RAM Definition for Replay Storage
  // Port A: Write Port (New Inbound TLPs)
  // Port B: Read Port (Replay re-transmission)
  //---------------------------------------------------------------------------
  tlp_unpacked_s ram [0:BUFFER_DEPTH-1];

  // Pointers and Slot Tracking
  logic [ADDR_WIDTH-1:0] wr_ptr_q, wr_ptr_d;       // Points to next write slot
  logic [ADDR_WIDTH-1:0] commit_ptr_q, commit_ptr_d; // Oldest unacknowledged slot
  logic [ADDR_WIDTH-1:0] replay_ptr_q, replay_ptr_d; // Current replay read slot
  logic [ADDR_WIDTH:0]   occupancy_q, occupancy_d; // Number of stored uncommitted TLPs

  // Sequence Number Counters (12-bit Modulo 4096)
  logic [11:0] next_trans_seq_q, next_trans_seq_d;
  logic [11:0] ackd_seq_q, ackd_seq_d;

  // Replay Control & Timers
  logic [31:0] replay_timer_q, replay_timer_d;
  logic [2:0]  replay_count_q, replay_count_d;
  logic        replay_timer_expired;
  logic        replay_rollover_err_q, replay_rollover_err_d;

  // Buffer full threshold
  logic buffer_full_comb;
  assign buffer_full_comb = (occupancy_q >= (ADDR_WIDTH+1)'(BUFFER_DEPTH - 1));
  assign buffer_full_o    = buffer_full_comb;

  // Ready handshake to upstream TLP engine
  assign in_tlp_rdy_o = (!buffer_full_comb) && (state_q == S_NORMAL) && link_active_i && out_tlp_rdy_i;

  // Sequence difference modulo-4096 calculations
  function automatic logic [11:0] seq_diff(input logic [11:0] a, input logic [11:0] b);
    return (a - b) & 12'hFFF;
  endfunction

  //---------------------------------------------------------------------------
  // Dual-Port RAM Operations
  //---------------------------------------------------------------------------
  logic ram_wr_en;
  logic [ADDR_WIDTH-1:0] ram_wr_addr;
  tlp_unpacked_s ram_wr_data;

  logic [ADDR_WIDTH-1:0] ram_rd_addr;
  tlp_unpacked_s ram_rd_data;

  assign ram_wr_addr = wr_ptr_q;
  assign ram_rd_addr = replay_ptr_q;

  // Synchronous Dual-Port RAM Block
  always_ff @(posedge clk) begin
    if (ram_wr_en) begin
      ram[ram_wr_addr] <= ram_wr_data;
    end
    ram_rd_data <= ram[ram_rd_addr];
  end

  //---------------------------------------------------------------------------
  // Outbound Multiplexing (Registered Pipeline)
  //---------------------------------------------------------------------------
  tlp_unpacked_s out_tlp_q, out_tlp_d;
  logic          out_tlp_val_q, out_tlp_val_d;
  logic          out_tlp_replay_q, out_tlp_replay_d;

  assign out_tlp_o           = out_tlp_q;
  assign out_tlp_val_o       = out_tlp_val_q;
  assign out_tlp_is_replay_o = out_tlp_replay_q;
  assign replay_in_progress_o = (state_q == S_REPLAY);
  assign replay_rollover_err_o= replay_rollover_err_q;
  assign next_trans_seq_o    = next_trans_seq_q;
  assign ackd_seq_o          = ackd_seq_q;

  //---------------------------------------------------------------------------
  // Next-State & Pointer Update Logic
  //---------------------------------------------------------------------------
  always_comb begin
    // Defaults
    state_d               = state_q;
    wr_ptr_d              = wr_ptr_q;
    commit_ptr_d          = commit_ptr_q;
    replay_ptr_d          = replay_ptr_q;
    occupancy_d           = occupancy_q;
    next_trans_seq_d      = next_trans_seq_q;
    ackd_seq_d            = ackd_seq_q;
    replay_timer_d        = replay_timer_q;
    replay_count_d        = replay_count_q;
    replay_rollover_err_d = replay_rollover_err_q;

    ram_wr_en             = 1'b0;
    ram_wr_data           = in_tlp_i;

    out_tlp_d             = out_tlp_q;
    out_tlp_val_d         = 1'b0;
    out_tlp_replay_d      = 1'b0;

    replay_timer_expired  = (replay_timer_q >= 32'(REPLAY_TIMEOUT_CYC));

    // 1. Process Received Ack / Nak DLLPs
    if (link_active_i) begin
      // Handling Ack
      if (ack_rcvd_i) begin
        logic [11:0] unacked_cnt;
        logic [11:0] ack_delta;
        unacked_cnt = seq_diff(next_trans_seq_q - 12'd1, ackd_seq_q);
        ack_delta   = seq_diff(ack_seq_i, ackd_seq_q);

        if ((unacked_cnt > 0) && (ack_delta > 0) && (ack_delta <= unacked_cnt)) begin
          ackd_seq_d = ack_seq_i;
          commit_ptr_d = commit_ptr_q + ack_delta[ADDR_WIDTH-1:0];
          occupancy_d  = (occupancy_q >= (ADDR_WIDTH+1)'(ack_delta[ADDR_WIDTH:0])) ?
                         (occupancy_q - (ADDR_WIDTH+1)'(ack_delta[ADDR_WIDTH:0])) : '0;

          // Restart or clear replay timer
          if (ack_seq_i == ((next_trans_seq_q - 12'd1) & 12'hFFF)) begin
            replay_timer_d = '0; // All pending TLPs acknowledged
            replay_count_d = '0;
          end else begin
            replay_timer_d = '0; // Partial acknowledgment: reload timer
          end
        end
      end

      // Handling Nak
      if (nak_rcvd_i) begin
        logic [11:0] unacked_cnt;
        logic [11:0] nak_delta;
        unacked_cnt = seq_diff(next_trans_seq_q - 12'd1, ackd_seq_q);
        nak_delta   = seq_diff(nak_seq_i, ackd_seq_q);

        // Advance acknowledged packets up to nak_seq
        if ((unacked_cnt > 0) && (nak_delta > 0) && (nak_delta <= unacked_cnt)) begin
          ackd_seq_d   = nak_seq_i;
          commit_ptr_d = commit_ptr_q + nak_delta[ADDR_WIDTH-1:0];
          occupancy_d  = (occupancy_q >= (ADDR_WIDTH+1)'(nak_delta[ADDR_WIDTH:0])) ?
                         (occupancy_q - (ADDR_WIDTH+1)'(nak_delta[ADDR_WIDTH:0])) : '0;
        end
      end
    end

    // 2. Replay Timer Increment
    if (link_active_i && (occupancy_q > 0) && (state_q == S_NORMAL)) begin
      replay_timer_d = replay_timer_q + 1'b1;
    end

    // 3. Main State Machine
    case (state_q)
      S_NORMAL: begin
        // Trigger Replay on Nak or Replay Timer Timeout
        if (link_active_i && (occupancy_q > 0) && (nak_rcvd_i || replay_timer_expired)) begin
          if (replay_count_q >= 3'd4) begin
            // PCIe Spec: Replay number rollover error after 4 attempts
            state_d               = S_ERROR;
            replay_rollover_err_d = 1'b1;
          end else begin
            state_d        = S_REPLAY;
            replay_ptr_d   = commit_ptr_d; // Rewind to oldest unacknowledged packet
            replay_count_d = replay_count_q + 3'd1;
            replay_timer_d = '0;
          end
        end else if (in_tlp_val_i && in_tlp_rdy_o) begin
          // Transmit fresh outbound TLP
          ram_wr_en            = 1'b1;
          ram_wr_data          = in_tlp_i;
          ram_wr_data.seq_num  = next_trans_seq_q; // Tag with current sequence number

          out_tlp_d            = ram_wr_data;
          out_tlp_val_d        = 1'b1;
          out_tlp_replay_d     = 1'b0;

          // Advance write pointer and sequence number
          wr_ptr_d             = wr_ptr_q + 1'b1;
          occupancy_d          = occupancy_q + 1'b1;
          next_trans_seq_d     = (next_trans_seq_q + 12'd1) & 12'hFFF;
        end
      end

      S_REPLAY: begin
        if (out_tlp_rdy_i) begin
          // Emit packet from replay buffer
          out_tlp_d        = ram_rd_data;
          out_tlp_val_d    = 1'b1;
          out_tlp_replay_d = 1'b1;

          // Advance replay pointer
          if ((replay_ptr_q + 1'b1) == wr_ptr_q) begin
            // Finished replaying all unacknowledged packets
            state_d        = S_NORMAL;
            replay_timer_d = '0;
          end else begin
            replay_ptr_d   = replay_ptr_q + 1'b1;
          end
        end
      end

      S_ERROR: begin
        // Fatal Link Error: Handled by LTSSM / Higher layer recovery
        if (!link_active_i) begin
          state_d               = S_NORMAL;
          replay_rollover_err_d = 1'b0;
          replay_count_d        = 0;
          replay_timer_d        = 0;
        end
      end

      default: state_d = S_NORMAL;
    endcase
  end

  //---------------------------------------------------------------------------
  // Synchronous State Register Updates
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state_q               <= S_NORMAL;
      wr_ptr_q              <= '0;
      commit_ptr_q          <= '0;
      replay_ptr_q          <= '0;
      occupancy_q           <= '0;
      next_trans_seq_q      <= 12'h000;
      ackd_seq_q            <= 12'hFFF; // Initialized to 4095 (-1)
      replay_timer_q        <= '0;
      replay_count_q        <= '0;
      replay_rollover_err_q <= 1'b0;
      out_tlp_val_q         <= 1'b0;
      out_tlp_replay_q      <= 1'b0;
      out_tlp_q             <= '0;
    end else begin
      state_q               <= state_d;
      wr_ptr_q              <= wr_ptr_d;
      commit_ptr_q          <= commit_ptr_d;
      replay_ptr_q          <= replay_ptr_d;
      occupancy_q           <= occupancy_d;
      next_trans_seq_q      <= next_trans_seq_d;
      ackd_seq_q            <= ackd_seq_d;
      replay_timer_q        <= replay_timer_d;
      replay_count_q        <= replay_count_d;
      replay_rollover_err_q <= replay_rollover_err_d;
      out_tlp_val_q         <= out_tlp_val_d;
      out_tlp_replay_q      <= out_tlp_replay_d;
      out_tlp_q             <= out_tlp_d;
    end
  end

endmodule : replay_buffer

`endif // REPLAY_BUFFER_SV
