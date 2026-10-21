//=============================================================================
// File: pcie_pipe_if.sv
// Description: Physical Interface for PCI Express (PIPE) Specification (Gen 3)
// Standard: Intel PHY Interface for the PCI Express Architecture v4.3/v5.x
//=============================================================================

`ifndef PCIE_PIPE_IF_SV
`define PCIE_PIPE_IF_SV

`include "pcie_pkg.sv"

interface pcie_pipe_if #(
  parameter int DATA_WIDTH = 32,
  parameter int STRB_WIDTH = DATA_WIDTH / 8
)(
  input logic clk,
  input logic rst_n
);
  import pcie_pkg::*;

  /* verilator lint_off UNUSEDSIGNAL */

  //---------------------------------------------------------------------------
  // Transmit Data Path (MAC -> PHY)
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] tx_data;
  logic [STRB_WIDTH-1:0] tx_data_k;           // For Gen 1/2 fallback (8b/10b)
  logic [1:0]            tx_sync_header;      // For Gen 3 (128b/130b: 2'b01 Data, 2'b10 Sync)
  logic                  tx_start_block;      // Gen 3 first symbol of 130-bit block
  logic                  tx_data_valid;       // Transmit valid symbol/block
  logic                  tx_elec_idle;        // Force transmitter electrical idle
  logic                  tx_detect_rx_loopback; // Receiver detection & loopback request
  logic                  tx_compliance;       // Transmit compliance pattern
  logic [1:0]            power_down;          // P0 (normal), P0s, P1, P2

  //---------------------------------------------------------------------------
  // Receive Data Path (PHY -> MAC)
  //---------------------------------------------------------------------------
  logic [DATA_WIDTH-1:0] rx_data;
  logic [STRB_WIDTH-1:0] rx_data_k;           // For Gen 1/2 fallback
  logic [1:0]            rx_sync_header;      // For Gen 3 (128b/130b)
  logic                  rx_start_block;      // Gen 3 block boundary
  logic                  rx_data_valid;       // Receive data valid
  logic                  rx_valid;            // Symbol lock / valid byte indication
  logic                  rx_elec_idle;        // Receiver electrical idle detected
  logic [2:0]            rx_status;           // 000=OK, 001=SKP add, 010=SKP del, 011=detect, etc.

  //---------------------------------------------------------------------------
  // Link Control & PHY Status
  //---------------------------------------------------------------------------
  logic                  phy_status;          // PHY command handshake / status
  pcie_rate_e            rate;                // Gen1 (2.5GT), Gen2 (5.0GT), Gen3 (8.0GT)
  logic [1:0]            width;               // Link width: 00=x1, 01=x2, 10=x4, 11=x8
  logic                  rx_polarity;         // Invert receiver polarity
  logic [1:0]            tx_deemph;           // Transmit de-emphasis
  logic                  tx_swing;            // Transmit swing level (0=Full, 1=Reduced)

`ifndef VERILATOR
  //---------------------------------------------------------------------------
  // Verification Clocking Blocks
  //---------------------------------------------------------------------------
  clocking cb_mac @(posedge clk);
    default input #1step output #1step;
    output tx_data, tx_data_k, tx_sync_header, tx_start_block, tx_data_valid;
    output tx_elec_idle, tx_detect_rx_loopback, tx_compliance, power_down;
    output rate, width, rx_polarity, tx_deemph, tx_swing;
    input  rx_data, rx_data_k, rx_sync_header, rx_start_block, rx_data_valid;
    input  rx_valid, rx_elec_idle, rx_status, phy_status;
  endclocking

  clocking cb_phy @(posedge clk);
    default input #1step output #1step;
    input  tx_data, tx_data_k, tx_sync_header, tx_start_block, tx_data_valid;
    input  tx_elec_idle, tx_detect_rx_loopback, tx_compliance, power_down;
    input  rate, width, rx_polarity, tx_deemph, tx_swing;
    output rx_data, rx_data_k, rx_sync_header, rx_start_block, rx_data_valid;
    output rx_valid, rx_elec_idle, rx_status, phy_status;
  endclocking

  clocking cb_mon @(posedge clk);
    default input #1step;
    input tx_data, tx_data_k, tx_sync_header, tx_start_block, tx_data_valid;
    input tx_elec_idle, tx_detect_rx_loopback, tx_compliance, power_down;
    input rate, width, rx_polarity, tx_deemph, tx_swing;
    input rx_data, rx_data_k, rx_sync_header, rx_start_block, rx_data_valid;
    input rx_valid, rx_elec_idle, rx_status, phy_status;
  endclocking
`endif

  //---------------------------------------------------------------------------
  // Modports
  //---------------------------------------------------------------------------

  // MAC / PCIe Controller side
  modport mac (
    output tx_data, tx_data_k, tx_sync_header, tx_start_block, tx_data_valid,
    output tx_elec_idle, tx_detect_rx_loopback, tx_compliance, power_down,
    output rate, width, rx_polarity, tx_deemph, tx_swing,
    input  rx_data, rx_data_k, rx_sync_header, rx_start_block, rx_data_valid,
    input  rx_valid, rx_elec_idle, rx_status, phy_status,
    input  clk, rst_n
  );

  // PHY Model side
  modport phy (
    input  tx_data, tx_data_k, tx_sync_header, tx_start_block, tx_data_valid,
    input  tx_elec_idle, tx_detect_rx_loopback, tx_compliance, power_down,
    input  rate, width, rx_polarity, tx_deemph, tx_swing,
    output rx_data, rx_data_k, rx_sync_header, rx_start_block, rx_data_valid,
    output rx_valid, rx_elec_idle, rx_status, phy_status,
    input  clk, rst_n
  );

`ifndef VERILATOR
  // Testbench MAC master modport
  modport tb_mac (
    clocking cb_mac,
    input    clk, rst_n
  );

  // Testbench PHY slave modport
  modport tb_phy (
    clocking cb_phy,
    input    clk, rst_n
  );

  // Passive Monitor modport
  modport mon (
    clocking cb_mon,
    input    clk, rst_n
  );
`endif

endinterface : pcie_pipe_if

`endif // PCIE_PIPE_IF_SV
