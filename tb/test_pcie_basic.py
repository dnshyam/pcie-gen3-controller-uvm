"""
PCIe Gen 3 Controller Subsystem Test Suite (pyuvm & cocotb)
Tests:
  1. test_flow_control_init: Link FC initialization (FC_INIT1 -> FC_INIT2 -> ACTIVE)
  2. test_credit_exhaustion: Backpressure verification on credit ceiling
  3. test_crc_error_nak_replay: NAK injection and Replay Buffer re-transmission
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles, Timer
from pyuvm import uvm_test, uvm_root

from tb.pcie_env import PcieEnv
from tb.pcie_seq_item import PcieTlpItem, PcieDllpItem, DllpType, TlpType


async def setup_dut(dut):
    """Start 250 MHz PCIe PCLK (4ns period) and apply synchronous reset."""
    cocotb.start_soon(Clock(dut.clk, 4, unit="ns").start())

    dut.rst_n.value = 0
    # Initialize PIPE inputs
    dut.pipe_rx_data.value = 0
    dut.pipe_rx_data_valid.value = 0
    dut.pipe_rx_valid.value = 0
    dut.pipe_rx_elec_idle.value = 1
    dut.pipe_phy_status.value = 0

    # Initialize Application inputs
    dut.app_tx_valid.value = 0
    dut.app_tx_sop.value = 0
    dut.app_tx_eop.value = 0
    dut.app_tx_data.value = 0
    dut.app_tx_keep.value = 0
    dut.app_tx_err.value = 0
    dut.app_rx_ready.value = 1

    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 5)

    # Bring PHY link out of electrical idle
    dut.pipe_rx_elec_idle.value = 0
    dut.pipe_rx_valid.value = 1
    await ClockCycles(dut.clk, 5)


async def send_pipe_dllp(dut, dllp_type: DllpType, hdr_fc=64, data_fc=512, seq_num=0):
    """Helper to inject a DLLP on the PIPE receive interface."""
    await RisingEdge(dut.clk)
    dut.pipe_rx_data_valid.value = 1

    if dllp_type in (DllpType.ACK, DllpType.NAK):
        payload = (int(dllp_type) << 24) | (seq_num & 0xFFF)
    else:
        payload = (int(dllp_type) << 24) | ((hdr_fc & 0xFF) << 14) | (data_fc & 0xFFF)

    dut.pipe_rx_data.value = payload
    await RisingEdge(dut.clk)
    dut.pipe_rx_data_valid.value = 0
    dut.pipe_rx_data.value = 0


@cocotb.test()
async def test_flow_control_init(dut):
    """
    Test 1: Verify Flow Control Initialization sequence:
    Receives partner InitFC1 (P, NP, Cpl) and InitFC2 (P, NP, Cpl) -> asserts ACTIVE state.
    """
    await setup_dut(dut)
    dut._log.info("Starting test_flow_control_init...")

    # Controller should be in INIT state initially
    assert dut.app_link_up.value == 0, "Link should not be up before FC init!"

    # 1. Partner responds with InitFC1 packets
    await send_pipe_dllp(dut, DllpType.INITFC1_P, hdr_fc=64, data_fc=512)
    await send_pipe_dllp(dut, DllpType.INITFC1_NP, hdr_fc=64, data_fc=0)
    await send_pipe_dllp(dut, DllpType.INITFC1_CPL, hdr_fc=64, data_fc=512)
    await ClockCycles(dut.clk, 5)

    # 2. Partner responds with InitFC2 packets
    await send_pipe_dllp(dut, DllpType.INITFC2_P, hdr_fc=64, data_fc=512)
    await send_pipe_dllp(dut, DllpType.INITFC2_NP, hdr_fc=64, data_fc=0)
    await send_pipe_dllp(dut, DllpType.INITFC2_CPL, hdr_fc=64, data_fc=512)
    await ClockCycles(dut.clk, 10)

    # Verify transition to ACTIVE and credits available
    assert dut.app_fc_init_done.value == 1, "Flow Control initialization did not complete!"
    assert dut.app_link_up.value == 1, "Link UP was not asserted after FC init!"
    assert dut.app_p_hdr_credits.value == 64, f"P Hdr credits mismatch: {dut.app_p_hdr_credits.value}"
    assert dut.app_p_data_credits.value == 512, f"P Data credits mismatch: {dut.app_p_data_credits.value}"
    dut._log.info("test_flow_control_init PASSED successfully.")


@cocotb.test()
async def test_credit_exhaustion(dut):
    """
    Test 2: Transmit traffic until buffers block, verifying backpressure.
    """
    await setup_dut(dut)
    dut._log.info("Starting test_credit_exhaustion...")

    # Advertise minimal partner credits (e.g. 2 header credits)
    await send_pipe_dllp(dut, DllpType.INITFC1_P, hdr_fc=2, data_fc=16)
    await send_pipe_dllp(dut, DllpType.INITFC1_NP, hdr_fc=2, data_fc=0)
    await send_pipe_dllp(dut, DllpType.INITFC1_CPL, hdr_fc=2, data_fc=16)
    await send_pipe_dllp(dut, DllpType.INITFC2_P, hdr_fc=2, data_fc=16)
    await send_pipe_dllp(dut, DllpType.INITFC2_NP, hdr_fc=2, data_fc=0)
    await send_pipe_dllp(dut, DllpType.INITFC2_CPL, hdr_fc=2, data_fc=16)
    await ClockCycles(dut.clk, 10)

    # Inject Memory Write 1
    dut.app_tx_valid.value = 1
    dut.app_tx_sop.value = 1
    dut.app_tx_eop.value = 0
    dut.app_tx_data.value = (0x0100_0000 << 32) | (int(TlpType.MWR32) << 24) | 0x01 # 1 DW write
    dut.app_tx_keep.value = 0xFF

    await RisingEdge(dut.clk)
    dut.app_tx_sop.value = 0
    dut.app_tx_eop.value = 1
    dut.app_tx_data.value = (0x12345678 << 32) | 0x1000_0000

    await RisingEdge(dut.clk)
    dut.app_tx_valid.value = 0
    dut.app_tx_eop.value = 0

    await ClockCycles(dut.clk, 5)

    # Inject Memory Write 2
    dut.app_tx_valid.value = 1
    dut.app_tx_sop.value = 1
    dut.app_tx_eop.value = 0
    dut.app_tx_data.value = (0x0100_0000 << 32) | (int(TlpType.MWR32) << 24) | 0x01
    await RisingEdge(dut.clk)
    dut.app_tx_sop.value = 0
    dut.app_tx_eop.value = 1
    await RisingEdge(dut.clk)
    dut.app_tx_valid.value = 0
    dut.app_tx_eop.value = 0

    await ClockCycles(dut.clk, 10)

    # Credits are now exhausted (2/2). Attempting Write 3 should cause backpressure
    dut.app_tx_valid.value = 1
    dut.app_tx_sop.value = 1
    dut.app_tx_data.value = (0x0100_0000 << 32) | (int(TlpType.MWR32) << 24) | 0x01
    await ClockCycles(dut.clk, 3)

    # Confirm backpressure (app_tx_ready must be 0)
    dut._log.info(f"Checking backpressure, tx_ready={dut.app_tx_ready.value}")
    assert int(dut.app_tx_ready.value) == 0, f"Controller failed to backpressure! tx_ready={dut.app_tx_ready.value}"
    dut.app_tx_valid.value = 0
    dut.app_tx_sop.value = 0

    # Now partner returns credits via UpdateFC
    await send_pipe_dllp(dut, DllpType.UPDATEFC_P, hdr_fc=64, data_fc=512)
    await ClockCycles(dut.clk, 10)

    # Controller unblocks
    dut.app_tx_valid.value = 1
    dut.app_tx_sop.value = 1
    dut.app_tx_data.value = (0x0100_0000 << 32) | (int(TlpType.MWR32) << 24) | 0x01
    await RisingEdge(dut.clk)
    assert int(dut.app_tx_ready.value) == 1, "Controller did not unblock after UpdateFC credit refresh!"
    dut.app_tx_valid.value = 0
    dut.app_tx_sop.value = 0
    dut._log.info("test_credit_exhaustion PASSED successfully.")


@cocotb.test()
async def test_crc_error_nak_replay(dut):
    """
    Test 3: Intentionally inject NAK DLLP and validate replay buffer retransmission.
    """
    await setup_dut(dut)
    dut._log.info("Starting test_crc_error_nak_replay...")

    # Complete FC Init
    await send_pipe_dllp(dut, DllpType.INITFC1_P, hdr_fc=64, data_fc=512)
    await send_pipe_dllp(dut, DllpType.INITFC1_NP, hdr_fc=64, data_fc=0)
    await send_pipe_dllp(dut, DllpType.INITFC1_CPL, hdr_fc=64, data_fc=512)
    await send_pipe_dllp(dut, DllpType.INITFC2_P, hdr_fc=64, data_fc=512)
    await send_pipe_dllp(dut, DllpType.INITFC2_NP, hdr_fc=64, data_fc=0)
    await send_pipe_dllp(dut, DllpType.INITFC2_CPL, hdr_fc=64, data_fc=512)
    await ClockCycles(dut.clk, 10)

    # Transmit a TLP from App
    dut.app_tx_valid.value = 1
    dut.app_tx_sop.value = 1
    dut.app_tx_eop.value = 0
    dut.app_tx_data.value = (0x0100_0000 << 32) | (int(TlpType.MWR32) << 24) | 0x01
    dut.app_tx_keep.value = 0xFF
    await RisingEdge(dut.clk)
    dut.app_tx_sop.value = 0
    dut.app_tx_eop.value = 1
    dut.app_tx_data.value = (0xCAFEBABE << 32) | 0x2000_0000
    await RisingEdge(dut.clk)
    dut.app_tx_valid.value = 0
    dut.app_tx_eop.value = 0

    await ClockCycles(dut.clk, 10)
    dut._log.info(f"Before NAK: link_active={dut.u_dut.link_active.value}, "
                  f"occupancy={dut.u_dut.u_replay_buffer.occupancy_q.value}, "
                  f"state={dut.u_dut.u_replay_buffer.state_q.value}, "
                  f"next_seq={dut.u_dut.u_replay_buffer.next_trans_seq_q.value}, "
                  f"ackd_seq={dut.u_dut.u_replay_buffer.ackd_seq_q.value}")

    # Inject NAK for sequence number 4095 (requesting retransmission of packet 0)
    dut._log.info("Injecting NAK seq_num=0xFFF...")
    await send_pipe_dllp(dut, DllpType.NAK, seq_num=0xFFF)
    await ClockCycles(dut.clk, 2)
    dut._log.info(f"After NAK: nak_rcvd={dut.u_dut.nak_rcvd.value}, "
                  f"nak_seq={dut.u_dut.nak_seq.value}, "
                  f"occupancy={dut.u_dut.u_replay_buffer.occupancy_q.value}, "
                  f"state={dut.u_dut.u_replay_buffer.state_q.value}")

    # Verify that Replay Buffer re-emits the unacknowledged TLP
    replayed = False
    for cycle in range(50):
        await RisingEdge(dut.clk)
        valid = int(dut.pipe_tx_data_valid.value)
        data = int(dut.pipe_tx_data.value)
        if valid == 1:
            dut._log.info(f"Cycle {cycle}: valid={valid}, data=0x{data:08X}")
            # If it's a TLP (TLP_MWR32 = 0x40 in bits [31:24], or not a DLLP)
            if (data >> 24) == int(TlpType.MWR32):
                replayed = True
                dut._log.info(f"Replay TLP detected on PIPE: data=0x{data:08X}")
                break

    assert replayed, "Replay buffer failed to retransmit TLP after NAK injection!"
    dut._log.info("test_crc_error_nak_replay PASSED successfully.")
