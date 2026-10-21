//=============================================================================
// File: pcie_app_if.sv
// Description: Application / Core Interface to PCIe Controller Subsystem
// Standard: AXI-S style packet streaming with flow-control & config sideband
//=============================================================================

`ifndef PCIE_APP_IF_SV
`define PCIE_APP_IF_SV

`include "pcie_pkg.sv"

interface pcie_app_if #(
  parameter int DATA_WIDTH = 64,
  parameter int KEEP_WIDTH = DATA_WIDTH / 8
)(
  input logic clk,
  input logic rst_n
);
  import pcie_pkg::*;

  /* verilator lint_off UNUSEDSIGNAL */

  //---------------------------------------------------------------------------
  // Transmit Stream Channel (App -> PCIe Subsystem)
  //---------------------------------------------------------------------------
  logic                  tx_valid;
  logic                  tx_ready;
  logic                  tx_sop;             // Start of packet
  logic                  tx_eop;             // End of packet
  logic [DATA_WIDTH-1:0] tx_data;
  logic [KEEP_WIDTH-1:0] tx_keep;            // Byte strobe
  logic                  tx_err;             // Packet abort / error flag

  //---------------------------------------------------------------------------
  // Receive Stream Channel (PCIe Subsystem -> App)
  //---------------------------------------------------------------------------
  logic                  rx_valid;
  logic                  rx_ready;
  logic                  rx_sop;             // Start of packet
  logic                  rx_eop;             // End of packet
  logic [DATA_WIDTH-1:0] rx_data;
  logic [KEEP_WIDTH-1:0] rx_keep;            // Byte strobe
  logic                  rx_err;             // Poisoned TLP or LCRC error indication
  logic [2:0]            rx_bar_hit;         // BAR decode: 3'b001=BAR0, 3'b010=BAR1, etc.

  //---------------------------------------------------------------------------
  // Flow Control Credit Status (From Subsystem to App)
  //---------------------------------------------------------------------------
  logic                            fc_init_done;
  logic [FC_HDR_CREDIT_WIDTH-1:0]  p_hdr_credits;
  logic [FC_DATA_CREDIT_WIDTH-1:0] p_data_credits;
  logic [FC_HDR_CREDIT_WIDTH-1:0]  np_hdr_credits;
  logic [FC_DATA_CREDIT_WIDTH-1:0] np_data_credits;
  logic [FC_HDR_CREDIT_WIDTH-1:0]  cpl_hdr_credits;
  logic [FC_DATA_CREDIT_WIDTH-1:0] cpl_data_credits;

  //---------------------------------------------------------------------------
  // Configuration & Link Status Sideband
  //---------------------------------------------------------------------------
  logic        link_up;
  pcie_rate_e  link_rate;
  logic        cfg_bus_master_en;
  logic        cfg_mem_space_en;
  logic [2:0]  cfg_max_payload_size;    // 3'b000 = 128B
  logic [2:0]  cfg_max_read_req_size;   // 3'b000 = 128B, 3'b001 = 256B, etc.
  logic [15:0] cfg_completer_id;        // {Bus[7:0], Dev[4:0], Fn[2:0]}

`ifndef VERILATOR
  //---------------------------------------------------------------------------
  // Verification Clocking Blocks
  //---------------------------------------------------------------------------
  clocking cb_app @(posedge clk);
    default input #1step output #1step;
    output tx_valid, tx_sop, tx_eop, tx_data, tx_keep, tx_err;
    input  tx_ready;
    input  rx_valid, rx_sop, rx_eop, rx_data, rx_keep, rx_err, rx_bar_hit;
    output rx_ready;
    input  fc_init_done, p_hdr_credits, p_data_credits, np_hdr_credits, np_data_credits;
    input  cpl_hdr_credits, cpl_data_credits;
    input  link_up, link_rate, cfg_bus_master_en, cfg_mem_space_en;
    input  cfg_max_payload_size, cfg_max_read_req_size, cfg_completer_id;
  endclocking

  clocking cb_controller @(posedge clk);
    default input #1step output #1step;
    input  tx_valid, tx_sop, tx_eop, tx_data, tx_keep, tx_err;
    output tx_ready;
    output rx_valid, rx_sop, rx_eop, rx_data, rx_keep, rx_err, rx_bar_hit;
    input  rx_ready;
    output fc_init_done, p_hdr_credits, p_data_credits, np_hdr_credits, np_data_credits;
    output cpl_hdr_credits, cpl_data_credits;
    output link_up, link_rate, cfg_bus_master_en, cfg_mem_space_en;
    output cfg_max_payload_size, cfg_max_read_req_size, cfg_completer_id;
  endclocking

  clocking cb_mon @(posedge clk);
    default input #1step;
    input tx_valid, tx_ready, tx_sop, tx_eop, tx_data, tx_keep, tx_err;
    input rx_valid, rx_ready, rx_sop, rx_eop, rx_data, rx_keep, rx_err, rx_bar_hit;
    input fc_init_done, p_hdr_credits, p_data_credits, np_hdr_credits, np_data_credits;
    input cpl_hdr_credits, cpl_data_credits;
    input link_up, link_rate, cfg_bus_master_en, cfg_mem_space_en;
    input cfg_max_payload_size, cfg_max_read_req_size, cfg_completer_id;
  endclocking
`endif

  //---------------------------------------------------------------------------
  // Modports
  //---------------------------------------------------------------------------

  // Application Logic / User Core
  modport app (
    output tx_valid, tx_sop, tx_eop, tx_data, tx_keep, tx_err,
    input  tx_ready,
    input  rx_valid, rx_sop, rx_eop, rx_data, rx_keep, rx_err, rx_bar_hit,
    output rx_ready,
    input  fc_init_done, p_hdr_credits, p_data_credits, np_hdr_credits, np_data_credits,
    input  cpl_hdr_credits, cpl_data_credits,
    input  link_up, link_rate, cfg_bus_master_en, cfg_mem_space_en,
    input  cfg_max_payload_size, cfg_max_read_req_size, cfg_completer_id,
    input  clk, rst_n
  );

  // PCIe Controller Subsystem
  modport controller (
    input  tx_valid, tx_sop, tx_eop, tx_data, tx_keep, tx_err,
    output tx_ready,
    output rx_valid, rx_sop, rx_eop, rx_data, rx_keep, rx_err, rx_bar_hit,
    input  rx_ready,
    output fc_init_done, p_hdr_credits, p_data_credits, np_hdr_credits, np_data_credits,
    output cpl_hdr_credits, cpl_data_credits,
    output link_up, link_rate, cfg_bus_master_en, cfg_mem_space_en,
    output cfg_max_payload_size, cfg_max_read_req_size, cfg_completer_id,
    input  clk, rst_n
  );

`ifndef VERILATOR
  // Testbench App master modport
  modport tb_app (
    clocking cb_app,
    input    clk, rst_n
  );

  // Testbench Controller slave modport
  modport tb_controller (
    clocking cb_controller,
    input    clk, rst_n
  );

  // Passive Monitor modport
  modport mon (
    clocking cb_mon,
    input    clk, rst_n
  );
`endif

endinterface : pcie_app_if

`endif // PCIE_APP_IF_SV
