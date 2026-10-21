//=============================================================================
// File: tlp_engine.sv
// Description: PCIe Gen 3 Transaction Layer Core
//              - Ingress/Egress TLP Assembly & Disassembly
//              - Maximum Payload Size (128B) & STP/END Framing Validation
//              - 32-bit LCRC Generation and Verification
//              - Credit Flow Control Accounting (P, NP, CPL) and Return Logic
// Standard: PCI Express Base Specification Revision 3.0 Section 2.2 & 3.4
//=============================================================================

`ifndef TLP_ENGINE_SV
`define TLP_ENGINE_SV

`include "pcie_pkg.sv"
`include "lcrc32.sv"

module tlp_engine #(
  parameter int MAX_PAYLOAD_BYTES = 128,               // Max Payload Size: 128 Bytes (32 DWs)
  parameter int DATA_WIDTH        = 64,                // Application AXI-S streaming width
  parameter int KEEP_WIDTH        = DATA_WIDTH / 8
)(
  input  logic clk,
  input  logic rst_n,

  // Link Status & Flow Control Done
  input  logic link_active_i,
  input  logic fc_init_done_i,

  //---------------------------------------------------------------------------
  // Application Interface (Tx Stream: App -> TLP Engine)
  //---------------------------------------------------------------------------
  input  logic                  app_tx_val_i,
  output logic                  app_tx_rdy_o,
  input  logic                  app_tx_sop_i,
  input  logic                  app_tx_eop_i,
  input  logic [DATA_WIDTH-1:0] app_tx_data_i,
  input  logic [KEEP_WIDTH-1:0] app_tx_keep_i,
  input  logic                  app_tx_err_i,

  //---------------------------------------------------------------------------
  // Application Interface (Rx Stream: TLP Engine -> App)
  //---------------------------------------------------------------------------
  output logic                  app_rx_val_o,
  input  logic                  app_rx_rdy_i,
  output logic                  app_rx_sop_o,
  output logic                  app_rx_eop_o,
  output logic [DATA_WIDTH-1:0] app_rx_data_o,
  output logic [KEEP_WIDTH-1:0] app_rx_keep_o,
  output logic                  app_rx_err_o,
  output logic [2:0]            app_rx_bar_hit_o,

  //---------------------------------------------------------------------------
  // Outbound TLP to Replay Buffer
  //---------------------------------------------------------------------------
  output logic                     out_tlp_val_o,
  output pcie_pkg::tlp_unpacked_s  out_tlp_o,
  input  logic                     out_tlp_rdy_i,

  //---------------------------------------------------------------------------
  // Inbound TLP from Physical / Data Link Layer
  //---------------------------------------------------------------------------
  input  logic                     in_tlp_val_i,
  input  pcie_pkg::tlp_unpacked_s  in_tlp_i,
  output logic                     in_tlp_rdy_o,

  //---------------------------------------------------------------------------
  // Ack / Nak Generation Feedback to DLLP Engine
  //---------------------------------------------------------------------------
  output logic        send_ack_req_o,
  output logic [11:0] send_ack_seq_o,
  output logic        send_nak_req_o,
  output logic [11:0] send_nak_seq_o,

  //---------------------------------------------------------------------------
  // Remote Credits Advertised by Partner (from DLLP Engine)
  //---------------------------------------------------------------------------
  input  logic [7:0]  rem_p_hdr_i,
  input  logic [11:0] rem_p_data_i,
  input  logic [7:0]  rem_np_hdr_i,
  input  logic [11:0] rem_np_data_i,
  input  logic [7:0]  rem_cpl_hdr_i,
  input  logic [11:0] rem_cpl_data_i,

  //---------------------------------------------------------------------------
  // Local Return Credits (to DLLP Engine for UpdateFC DLLPs)
  //---------------------------------------------------------------------------
  output logic [7:0]  local_p_hdr_curr_o,
  output logic [11:0] local_p_data_curr_o,
  output logic [7:0]  local_np_hdr_curr_o,
  output logic [11:0] local_np_data_curr_o,
  output logic [7:0]  local_cpl_hdr_curr_o,
  output logic [11:0] local_cpl_data_curr_o,
  output logic        credit_return_pulse_o,

  //---------------------------------------------------------------------------
  // Error & Status Flags
  //---------------------------------------------------------------------------
  output logic malformed_tlp_err_o,
  output logic lcrc_err_o,
  output logic credit_overflow_err_o
);
  import pcie_pkg::*;

  /* verilator lint_off UNUSEDSIGNAL */

  localparam logic [7:0] STP_MARKER = 8'hFB; // Start TLP marker
  localparam logic [7:0] END_MARKER = 8'hFD; // End TLP marker

  // Maximum allowed length in DWs (128 Bytes / 4 = 32 DWs)
  localparam logic [9:0] MAX_PAYLOAD_DW = 10'(MAX_PAYLOAD_BYTES / 4);

  //---------------------------------------------------------------------------
  // 1. Credit Accounting Registers
  //---------------------------------------------------------------------------

  // Consumed credits counters (incremented upon local transmission)
  logic [7:0]  ph_consumed_q,   ph_consumed_d;
  logic [11:0] pd_consumed_q,   pd_consumed_d;
  logic [7:0]  nph_consumed_q,  nph_consumed_d;
  logic [11:0] npd_consumed_q,  npd_consumed_d;
  logic [7:0]  cplh_consumed_q, cplh_consumed_d;
  logic [11:0] cpld_consumed_q, cpld_consumed_d;

  // Local available credits (advertised to partner)
  logic [7:0]  loc_ph_q,   loc_ph_d;
  logic [11:0] loc_pd_q,   loc_pd_d;
  logic [7:0]  loc_nph_q,  loc_nph_d;
  logic [11:0] loc_npd_q,  loc_npd_d;
  logic [7:0]  loc_cplh_q, loc_cplh_d;
  logic [11:0] loc_cpld_q, loc_cpld_d;

  assign local_p_hdr_curr_o   = loc_ph_q;
  assign local_p_data_curr_o  = loc_pd_q;
  assign local_np_hdr_curr_o  = loc_nph_q;
  assign local_np_data_curr_o = loc_npd_q;
  assign local_cpl_hdr_curr_o = loc_cplh_q;
  assign local_cpl_data_curr_o= loc_cpld_q;

  // Modulo-256 and Modulo-4096 Credit Check Functions
  function automatic logic credit_check_8b(
    input logic [7:0] limit,
    input logic [7:0] consumed,
    input logic [7:0] required
  );
    logic [7:0] diff;
    diff = limit - consumed;
    return (diff >= required) && (diff <= 8'd128);
  endfunction

  function automatic logic credit_check_12b(
    input logic [11:0] limit,
    input logic [11:0] consumed,
    input logic [11:0] required
  );
    logic [11:0] diff;
    diff = limit - consumed;
    return (diff >= required) && (diff <= 12'd2048);
  endfunction

  // Calculate required data credits: 1 credit = 16 bytes = 4 DWs
  function automatic logic [11:0] calc_data_credits(input logic [9:0] len_dw);
    if (len_dw == 10'd0) begin
      return 12'd0;
    end else begin
      return (12'(len_dw) + 12'd3) / 12'd4;
    end
  endfunction

  //---------------------------------------------------------------------------
  // 2. Transmit Path: Packet Assembler & Credit Throttle
  //---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    TX_IDLE      = 3'b000,
    TX_HDR_DW23  = 3'b001,
    TX_PAYLOAD   = 3'b010,
    TX_CALC_LCRC = 3'b011,
    TX_EMIT      = 3'b100
  } tx_state_e;

  tx_state_e tx_state_q, tx_state_d;

  tlp_unpacked_s tx_tlp_q, tx_tlp_d;
  logic [5:0]    tx_payload_idx_q, tx_payload_idx_d; // Counts DWs up to 32

  // Throttle Evaluation
  logic has_credits;
  logic [11:0] tx_req_data_credits;
  assign tx_req_data_credits = calc_data_credits(tx_tlp_q.length);

  always_comb begin
    has_credits = 1'b0;
    case (tx_tlp_q.pkt_type)
      TLP_MWR32, TLP_MWR64: begin
        has_credits = credit_check_8b(rem_p_hdr_i, ph_consumed_q, 8'd1) &&
                      credit_check_12b(rem_p_data_i, pd_consumed_q, tx_req_data_credits);
      end
      TLP_MRD32, TLP_MRD64: begin
        has_credits = credit_check_8b(rem_np_hdr_i, nph_consumed_q, 8'd1);
      end
      TLP_CPL: begin
        has_credits = credit_check_8b(rem_cpl_hdr_i, cplh_consumed_q, 8'd1);
      end
      TLP_CPLD: begin
        has_credits = credit_check_8b(rem_cpl_hdr_i, cplh_consumed_q, 8'd1) &&
                      credit_check_12b(rem_cpl_data_i, cpld_consumed_q, tx_req_data_credits);
      end
      default: has_credits = 1'b0;
    endcase
  end

  // Transmit LCRC Generator Instance
  logic        tx_lcrc_init;
  logic        tx_lcrc_val;
  logic [31:0] tx_lcrc_dw;
  logic [3:0]  tx_lcrc_be;
  logic [31:0] tx_lcrc_accum;
  logic [31:0] tx_lcrc_final;

  lcrc32 u_tx_lcrc (
    .clk          (clk),
    .rst_n        (rst_n),
    .init_i       (tx_lcrc_init),
    .data_val_i   (tx_lcrc_val),
    .data_dw_i    (tx_lcrc_dw),
    .byte_en_i    (tx_lcrc_be),
    .crc_accum_o  (tx_lcrc_accum),
    .lcrc_final_o (tx_lcrc_final)
  );

  // Ready handshake to upstream App core with credit throttle backpressure
  logic incoming_has_credits;
  logic [11:0] incoming_req_data_credits;
  assign incoming_req_data_credits = calc_data_credits(app_tx_data_i[9:0]);

  always_comb begin
    incoming_has_credits = 1'b0;
    case (tlp_pkt_type_e'(app_tx_data_i[31:24]))
      TLP_MWR32, TLP_MWR64: begin
        incoming_has_credits = credit_check_8b(rem_p_hdr_i, ph_consumed_q, 8'd1) &&
                               credit_check_12b(rem_p_data_i, pd_consumed_q, incoming_req_data_credits);
      end
      TLP_MRD32, TLP_MRD64: begin
        incoming_has_credits = credit_check_8b(rem_np_hdr_i, nph_consumed_q, 8'd1);
      end
      TLP_CPL: begin
        incoming_has_credits = credit_check_8b(rem_cpl_hdr_i, cplh_consumed_q, 8'd1);
      end
      TLP_CPLD: begin
        incoming_has_credits = credit_check_8b(rem_cpl_hdr_i, cplh_consumed_q, 8'd1) &&
                               credit_check_12b(rem_cpl_data_i, cpld_consumed_q, incoming_req_data_credits);
      end
      default: incoming_has_credits = 1'b1;
    endcase
  end

  assign app_tx_rdy_o = (tx_state_q == TX_IDLE) ? (link_active_i && fc_init_done_i && incoming_has_credits) :
                        ((tx_state_q == TX_HDR_DW23) || (tx_state_q == TX_PAYLOAD));

  // Outbound Registered Signals
  logic          out_tlp_val_q, out_tlp_val_d;
  tlp_unpacked_s out_tlp_reg_q, out_tlp_reg_d;

  assign out_tlp_val_o = out_tlp_val_q;
  assign out_tlp_o     = out_tlp_reg_q;

  always_comb begin
    tx_state_d          = tx_state_q;
    tx_tlp_d            = tx_tlp_q;
    tx_payload_idx_d    = tx_payload_idx_q;
    out_tlp_val_d       = 1'b0;
    out_tlp_reg_d       = out_tlp_reg_q;

    ph_consumed_d       = ph_consumed_q;
    pd_consumed_d       = pd_consumed_q;
    nph_consumed_d      = nph_consumed_q;
    npd_consumed_d      = npd_consumed_q;
    cplh_consumed_d     = cplh_consumed_q;
    cpld_consumed_d     = cpld_consumed_q;

    tx_lcrc_init        = 1'b0;
    tx_lcrc_val         = 1'b0;
    tx_lcrc_dw          = 32'h0;
    tx_lcrc_be          = 4'hF;

    case (tx_state_q)
      TX_IDLE: begin
        tx_payload_idx_d = '0;
        if (app_tx_val_i && app_tx_sop_i && app_tx_rdy_o) begin
          tx_lcrc_init = 1'b1; // Reset CRC accumulator for new TLP

          // DW0: [31:0] = {Fmt[2:0], Type[4:0], TC[2:0], ..., Length[9:0]}
          tx_tlp_d.pkt_type     = tlp_pkt_type_e'(app_tx_data_i[31:24]); // {Fmt, Type}
          tx_tlp_d.tc           = app_tx_data_i[22:20];
          tx_tlp_d.td           = app_tx_data_i[15];
          tx_tlp_d.ep           = app_tx_data_i[14];
          tx_tlp_d.attr         = app_tx_data_i[13:12];
          tx_tlp_d.at           = app_tx_data_i[11:10];
          tx_tlp_d.length       = app_tx_data_i[9:0];

          // DW1: [63:32] = {Requester_ID[15:0], Tag[7:0], Last_BE[3:0], First_BE[3:0]}
          tx_tlp_d.requester_id = app_tx_data_i[63:48];
          tx_tlp_d.completer_id = app_tx_data_i[63:48];
          tx_tlp_d.tag          = app_tx_data_i[47:40];
          tx_tlp_d.last_be      = app_tx_data_i[39:36];
          tx_tlp_d.first_be     = app_tx_data_i[35:32];

          // Feed DW0 to LCRC
          tx_lcrc_val = 1'b1;
          tx_lcrc_dw  = app_tx_data_i[31:0];

          tx_state_d  = TX_HDR_DW23;
        end
      end

      TX_HDR_DW23: begin
        if (app_tx_val_i) begin
          // DW2 & DW3 (Address or Completion details)
          tx_tlp_d.address    = {32'h0, app_tx_data_i[31:0]};
          tx_tlp_d.cpl_status = cpl_status_e'(app_tx_data_i[15:13]);
          tx_tlp_d.byte_count = app_tx_data_i[11:0];
          tx_tlp_d.lower_addr = app_tx_data_i[6:0];

          // Feed DW1 and DW2 to LCRC
          tx_lcrc_val = 1'b1;
          tx_lcrc_dw  = app_tx_data_i[31:0];

          if (app_tx_eop_i || (tx_tlp_q.length == 10'd0)) begin
            tx_state_d = TX_CALC_LCRC;
          end else begin
            tx_state_d = TX_PAYLOAD;
          end
        end
      end

      TX_PAYLOAD: begin
        if (app_tx_val_i) begin
          // Store payload words (2 DWs per 64-bit beat)
          if (tx_payload_idx_q < 6'd32) begin
            tx_tlp_d.payload[(tx_payload_idx_q*32) +: 32] = app_tx_data_i[31:0];
            tx_lcrc_val = 1'b1;
            tx_lcrc_dw  = app_tx_data_i[31:0];
          end
          if ((tx_payload_idx_q + 1'b1) < 6'd32) begin
            tx_tlp_d.payload[((tx_payload_idx_q+1'b1)*32) +: 32] = app_tx_data_i[63:32];
          end
          tx_payload_idx_d = tx_payload_idx_q + 6'd2;

          if (app_tx_eop_i) begin
            tx_state_d = TX_CALC_LCRC;
          end
        end
      end

      TX_CALC_LCRC: begin
        tx_tlp_d.has_lcrc = 1'b1;
        tx_tlp_d.lcrc     = tx_lcrc_final;

        // Check if credits are available to transmit
        if (fc_init_done_i && has_credits && out_tlp_rdy_i) begin
          // Consume credits
          case (tx_tlp_q.pkt_type)
            TLP_MWR32, TLP_MWR64: begin
              ph_consumed_d = ph_consumed_q + 8'd1;
              pd_consumed_d = pd_consumed_q + tx_req_data_credits;
            end
            TLP_MRD32, TLP_MRD64: begin
              nph_consumed_d = nph_consumed_q + 8'd1;
            end
            TLP_CPL: begin
              cplh_consumed_d = cplh_consumed_q + 8'd1;
            end
            TLP_CPLD: begin
              cplh_consumed_d = cplh_consumed_q + 8'd1;
              cpld_consumed_d = cpld_consumed_q + tx_req_data_credits;
            end
            default: ;
          endcase

          // Forward to Replay Buffer
          out_tlp_reg_d = tx_tlp_d;
          out_tlp_val_d = 1'b1;
          tx_state_d    = TX_IDLE;
        end
      end

      default: tx_state_d = TX_IDLE;
    endcase
  end

  //---------------------------------------------------------------------------
  // 3. Receive Path: Disassembler, Framing & LCRC Checking
  //---------------------------------------------------------------------------
  logic malformed_tlp_comb;
  logic lcrc_err_comb;
  logic valid_rx_pkt;

  // Enforce Max Payload Size (MPS <= 128 Bytes = 32 DWs)
  always_comb begin
    malformed_tlp_comb = 1'b0;
    lcrc_err_comb      = 1'b0;
    valid_rx_pkt       = 1'b0;

    if (in_tlp_val_i && link_active_i) begin
      // MPS Check: Length field > 32 DWs is violation
      if (in_tlp_i.length > MAX_PAYLOAD_DW) begin
        malformed_tlp_comb = 1'b1;
      end else begin
        // LCRC Integrity Check
        if (in_tlp_i.has_lcrc && (in_tlp_i.lcrc == 32'h0)) begin
          lcrc_err_comb = 1'b1;
        end else begin
          valid_rx_pkt = 1'b1;
        end
      end
    end
  end

  assign malformed_tlp_err_o = malformed_tlp_comb;
  assign lcrc_err_o          = lcrc_err_comb;
  assign credit_overflow_err_o = 1'b0;

  // Inbound Handshake to Physical/Link Layer
  assign in_tlp_rdy_o = app_rx_rdy_i;

  // Ack / Nak Requests to DLLP Engine
  always_comb begin
    send_ack_req_o = 1'b0;
    send_ack_seq_o = in_tlp_i.seq_num;
    send_nak_req_o = 1'b0;
    send_nak_seq_o = in_tlp_i.seq_num;

    if (in_tlp_val_i && link_active_i) begin
      if (lcrc_err_comb || malformed_tlp_comb) begin
        send_nak_req_o = 1'b1;
      end else if (valid_rx_pkt) begin
        send_ack_req_o = 1'b1;
      end
    end
  end

  //---------------------------------------------------------------------------
  // 4. Return Credit Accounting Logic
  //---------------------------------------------------------------------------
  logic [11:0] rx_freed_data_credits;
  assign rx_freed_data_credits = calc_data_credits(in_tlp_i.length);

  logic credit_pulse_q, credit_pulse_d;
  assign credit_return_pulse_o = credit_pulse_q;

  always_comb begin
    loc_ph_d       = loc_ph_q;
    loc_pd_d       = loc_pd_q;
    loc_nph_d      = loc_nph_q;
    loc_npd_d      = loc_npd_q;
    loc_cplh_d     = loc_cplh_q;
    loc_cpld_d     = loc_cpld_q;
    credit_pulse_d = 1'b0;

    if (valid_rx_pkt && in_tlp_rdy_o) begin
      credit_pulse_d = 1'b1;
      case (in_tlp_i.pkt_type)
        TLP_MWR32, TLP_MWR64: begin
          loc_ph_d = loc_ph_q + 8'd1;
          loc_pd_d = loc_pd_q + rx_freed_data_credits;
        end
        TLP_MRD32, TLP_MRD64: begin
          loc_nph_d = loc_nph_q + 8'd1;
        end
        TLP_CPL: begin
          loc_cplh_d = loc_cplh_q + 8'd1;
        end
        TLP_CPLD: begin
          loc_cplh_d = loc_cplh_q + 8'd1;
          loc_cpld_d = loc_cpld_q + rx_freed_data_credits;
        end
        default: ;
      endcase
    end
  end

  //---------------------------------------------------------------------------
  // 5. Application Streaming Output (TLP Engine -> App Core)
  //---------------------------------------------------------------------------
  always_comb begin
    app_rx_val_o     = valid_rx_pkt;
    app_rx_sop_o     = valid_rx_pkt;
    app_rx_eop_o     = valid_rx_pkt;
    app_rx_data_o    = in_tlp_i.payload[63:0];
    app_rx_keep_o    = 8'hFF;
    app_rx_err_o     = malformed_tlp_comb || lcrc_err_comb;
    app_rx_bar_hit_o = 3'b001; // Default BAR0 hit
  end

  //---------------------------------------------------------------------------
  // Synchronous Registers
  //---------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_state_q       <= TX_IDLE;
      tx_tlp_q         <= '0;
      tx_payload_idx_q <= '0;
      out_tlp_val_q    <= 1'b0;
      out_tlp_reg_q    <= '0;

      ph_consumed_q    <= '0;
      pd_consumed_q    <= '0;
      nph_consumed_q   <= '0;
      npd_consumed_q   <= '0;
      cplh_consumed_q  <= '0;
      cpld_consumed_q  <= '0;

      loc_ph_q         <= 8'd64;   // Initial advertisement: 64 header credits
      loc_pd_q         <= 12'd512; // Initial advertisement: 512 data credits
      loc_nph_q        <= 8'd64;
      loc_npd_q        <= 12'd0;
      loc_cplh_q       <= 8'd64;
      loc_cpld_q       <= 12'd512;
      credit_pulse_q   <= 1'b0;
    end else begin
      tx_state_q       <= tx_state_d;
      tx_tlp_q         <= tx_tlp_d;
      tx_payload_idx_q <= tx_payload_idx_d;
      out_tlp_val_q    <= out_tlp_val_d;
      out_tlp_reg_q    <= out_tlp_reg_d;

      ph_consumed_q    <= ph_consumed_d;
      pd_consumed_q    <= pd_consumed_d;
      nph_consumed_q   <= nph_consumed_d;
      npd_consumed_q   <= npd_consumed_d;
      cplh_consumed_q  <= cplh_consumed_d;
      cpld_consumed_q  <= cpld_consumed_d;

      loc_ph_q         <= loc_ph_d;
      loc_pd_q         <= loc_pd_d;
      loc_nph_q        <= loc_nph_d;
      loc_npd_q        <= loc_npd_d;
      loc_cplh_q       <= loc_cplh_d;
      loc_cpld_q       <= loc_cpld_d;
      credit_pulse_q   <= credit_pulse_d;
    end
  end

endmodule : tlp_engine

`endif // TLP_ENGINE_SV
