//=============================================================================
// File: tb_top.sv
// Description: Testbench Top Wrapper for Cocotb & pyuvm Simulation
//=============================================================================

`timescale 1ns/1ps

`include "pcie_pkg.sv"
`include "pcie_pipe_if.sv"
`include "pcie_app_if.sv"
`include "pcie_controller_top.sv"

module tb_top (
  input  logic        clk,
  input  logic        rst_n,

  // Direct PIPE Interface Pins for Cocotb Driver/Monitor
  input  logic [31:0] pipe_rx_data,
  input  logic        pipe_rx_data_valid,
  input  logic        pipe_rx_valid,
  input  logic        pipe_rx_elec_idle,
  input  logic        pipe_phy_status,

  output logic [31:0] pipe_tx_data,
  output logic        pipe_tx_data_valid,
  output logic [1:0]  pipe_tx_sync_header,
  output logic        pipe_tx_elec_idle,

  // Direct Application Interface Pins for Cocotb Driver/Monitor
  input  logic        app_tx_valid,
  output logic        app_tx_ready,
  input  logic        app_tx_sop,
  input  logic        app_tx_eop,
  input  logic [63:0] app_tx_data,
  input  logic [7:0]  app_tx_keep,
  input  logic        app_tx_err,

  output logic        app_rx_valid,
  input  logic        app_rx_ready,
  output logic        app_rx_sop,
  output logic        app_rx_eop,
  output logic [63:0] app_rx_data,
  output logic [7:0]  app_rx_keep,
  output logic        app_rx_err,
  output logic [2:0]  app_rx_bar_hit,

  // Status & Credit Sideband
  output logic        app_link_up,
  output logic        app_fc_init_done,
  output logic [7:0]  app_p_hdr_credits,
  output logic [11:0] app_p_data_credits,
  output logic [7:0]  app_np_hdr_credits,
  output logic [7:0]  app_cpl_hdr_credits
);
  import pcie_pkg::*;

  /* verilator lint_off UNUSEDSIGNAL */

  // Instantiate Hardware Interfaces
  pcie_app_if #(
    .DATA_WIDTH (64)
  ) app_if (
    .clk   (clk),
    .rst_n (rst_n)
  );

  pcie_pipe_if #(
    .DATA_WIDTH (32)
  ) pipe_if (
    .clk   (clk),
    .rst_n (rst_n)
  );

  // Connect Top Pins to Interfaces
  assign app_if.tx_valid = app_tx_valid;
  assign app_tx_ready    = app_if.tx_ready;
  assign app_if.tx_sop   = app_tx_sop;
  assign app_if.tx_eop   = app_tx_eop;
  assign app_if.tx_data  = app_tx_data;
  assign app_if.tx_keep  = app_tx_keep;
  assign app_if.tx_err   = app_tx_err;

  assign app_rx_valid    = app_if.rx_valid;
  assign app_if.rx_ready = app_rx_ready;
  assign app_rx_sop      = app_if.rx_sop;
  assign app_rx_eop      = app_if.rx_eop;
  assign app_rx_data     = app_if.rx_data;
  assign app_rx_keep     = app_if.rx_keep;
  assign app_rx_err      = app_if.rx_err;
  assign app_rx_bar_hit  = app_if.rx_bar_hit;

  assign app_link_up        = app_if.link_up;
  assign app_fc_init_done   = app_if.fc_init_done;
  assign app_p_hdr_credits  = app_if.p_hdr_credits;
  assign app_p_data_credits = app_if.p_data_credits;
  assign app_np_hdr_credits = app_if.np_hdr_credits;
  assign app_cpl_hdr_credits= app_if.cpl_hdr_credits;

  assign pipe_if.rx_data       = pipe_rx_data;
  assign pipe_if.rx_data_valid = pipe_rx_data_valid;
  assign pipe_if.rx_valid      = pipe_rx_valid;
  assign pipe_if.rx_elec_idle  = pipe_rx_elec_idle;
  assign pipe_if.phy_status    = pipe_phy_status;

  assign pipe_tx_data          = pipe_if.tx_data;
  assign pipe_tx_data_valid    = pipe_if.tx_data_valid;
  assign pipe_tx_sync_header   = pipe_if.tx_sync_header;
  assign pipe_tx_elec_idle     = pipe_if.tx_elec_idle;

  // Instantiate PCIe Controller Subsystem DUT
  pcie_controller_top u_dut (
    .clk     (clk),
    .rst_n   (rst_n),
    .app_if  (app_if.controller),
    .pipe_if (pipe_if.mac)
  );

endmodule : tb_top
