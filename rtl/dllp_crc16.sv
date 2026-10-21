//=============================================================================
// File: dllp_crc16.sv
// Description: Synthesizable Parallel 16-bit CRC Generator & Checker for DLLPs
// Standard: PCI Express Base Specification Revision 3.0 (x^16 + x^12 + x^5 + 1)
//=============================================================================

`ifndef DLLP_CRC16_SV
`define DLLP_CRC16_SV

`include "pcie_pkg.sv"

module dllp_crc16 (
  input  logic        clk,
  input  logic        rst_n,

  // CRC Generation Interface (Tx Path)
  input  logic        tx_val_i,
  input  logic [31:0] tx_data_i,         // 4-byte DLLP payload (Byte 0 to Byte 3)
  output logic        tx_val_o,
  output logic [47:0] tx_dllp_o,         // 48-bit DLLP: {Payload[31:0], CRC16[15:0]}

  // CRC Checking Interface (Rx Path)
  input  logic        rx_val_i,
  input  logic [47:0] rx_dllp_i,         // 48-bit incoming DLLP
  output logic        rx_val_o,
  output logic [31:0] rx_payload_o,      // Extracted 32-bit payload
  output logic        rx_crc_err_o       // High if received CRC fails
);
  import pcie_pkg::*;

  /* verilator lint_off UNUSEDSIGNAL */

  //---------------------------------------------------------------------------
  // CRC-16 Calculation Function (x^16 + x^12 + x^5 + 1, Poly = 16'h1021)
  // Evaluates 8 bits LSB-to-MSB per byte as per PCIe 3.0 Spec
  //---------------------------------------------------------------------------
  function automatic logic [15:0] crc16_8b(
    input logic [7:0]  data_byte,
    input logic [15:0] current_crc
  );
    logic [15:0] c;
    logic        fb;
    c = current_crc;
    for (int i = 0; i < 8; i++) begin
      fb = data_byte[i] ^ c[15];
      c  = {c[14:0], 1'b0};
      if (fb) begin
        c = c ^ 16'h1021;
      end
    end
    return c;
  endfunction

  // Unrolled 32-bit (4-byte) Parallel CRC Calculator
  function automatic logic [15:0] calc_dllp_crc(input logic [31:0] payload);
    logic [15:0] crc;
    crc = 16'hFFFF; // Initial Seed
    crc = crc16_8b(payload[7:0],   crc);  // Byte 0
    crc = crc16_8b(payload[15:8],  crc);  // Byte 1
    crc = crc16_8b(payload[23:16], crc);  // Byte 2
    crc = crc16_8b(payload[31:24], crc);  // Byte 3
    return ~crc;                          // 1's complement inversion
  endfunction

  //---------------------------------------------------------------------------
  // Transmit Logic (Registered Output)
  //---------------------------------------------------------------------------
  logic [15:0] tx_crc_comb;

  always_comb begin
    tx_crc_comb = calc_dllp_crc(tx_data_i);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_val_o  <= 1'b0;
      tx_dllp_o <= 48'h0;
    end else begin
      tx_val_o  <= tx_val_i;
      if (tx_val_i) begin
        // Byte 0..3 payload concatenated with 16-bit CRC
        tx_dllp_o <= {tx_data_i, tx_crc_comb};
      end else begin
        tx_dllp_o <= 48'h0;
      end
    end
  end

  //---------------------------------------------------------------------------
  // Receive Checker Logic (Registered Output)
  //---------------------------------------------------------------------------
  logic [31:0] rx_payload_comb;
  logic [15:0] rx_received_crc_comb;
  logic [15:0] rx_computed_crc_comb;
  logic        rx_err_comb;

  always_comb begin
    rx_payload_comb      = rx_dllp_i[47:16];
    rx_received_crc_comb = rx_dllp_i[15:0];
    rx_computed_crc_comb = calc_dllp_crc(rx_payload_comb);
    rx_err_comb          = (rx_received_crc_comb != rx_computed_crc_comb);
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_val_o     <= 1'b0;
      rx_payload_o <= 32'h0;
      rx_crc_err_o <= 1'b0;
    end else begin
      rx_val_o <= rx_val_i;
      if (rx_val_i) begin
        rx_payload_o <= rx_payload_comb;
        rx_crc_err_o <= rx_err_comb;
      end else begin
        rx_payload_o <= 32'h0;
        rx_crc_err_o <= 1'b0;
      end
    end
  end

endmodule : dllp_crc16

`endif // DLLP_CRC16_SV
