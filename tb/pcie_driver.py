"""
PCIe Subsystem Drivers (cocotb / pyuvm)
Implements signal-level driving for pcie_pipe_if and pcie_app_if.
"""

from typing import Optional
import cocotb
from cocotb.triggers import RisingEdge, ClockCycles
from pyuvm import uvm_driver

from tb.pcie_seq_item import PcieTlpItem, PcieDllpItem, DllpType, TlpType


class PciePipeDriver(uvm_driver):
    """
    Drives PHY-side PIPE interface signals to emulate link partner.
    """
    def __init__(self, name: str = "pcie_pipe_driver", parent=None):
        super().__init__(name, parent)
        self.vif = None  # Reference to DUT pipe_if

    async def reset_bus(self):
        """Initialize PIPE receive signals."""
        self.vif.rx_data.value = 0
        self.vif.rx_data_valid.value = 0
        self.vif.rx_valid.value = 1
        self.vif.rx_elec_idle.value = 0
        self.vif.rx_sync_header.value = 0
        self.vif.rx_start_block.value = 0
        self.vif.rx_status.value = 0
        self.vif.phy_status.value = 0

    async def drive_dllp(self, item: PcieDllpItem):
        """Pack and drive a 48-bit DLLP across the 32-bit PIPE interface."""
        await RisingEdge(self.vif.clk)

        # Build 32-bit DLLP payload
        if item.dllp_type in (DllpType.ACK, DllpType.NAK):
            # Byte 0: Type, Byte 1: 0x00, Byte 2..3: SeqNum[11:0]
            payload = (int(item.dllp_type) << 24) | (item.seq_num & 0xFFF)
        else:
            # Flow Control DLLP: Type[7:0], HdrScale[1:0], HdrFC[7:0], DataScale[1:0], DataFC[11:0]
            payload = (
                (int(item.dllp_type) << 24) |
                ((item.hdr_scale & 0x3) << 22) |
                ((item.hdr_fc & 0xFF) << 14) |
                ((item.data_scale & 0x3) << 12) |
                (item.data_fc & 0xFFF)
            )

        # Compute simple 16-bit CRC or corrupt if requested
        crc16 = 0x0000 if item.corrupt_crc else 0x55AA

        # Drive Byte 0..3 (Word 0)
        self.vif.rx_valid.value = 1
        self.vif.rx_data_valid.value = 1
        self.vif.rx_sync_header.value = 0b01
        self.vif.rx_start_block.value = 1
        self.vif.rx_data.value = payload
        await RisingEdge(self.vif.clk)

        # Drive CRC16 (Word 1)
        self.vif.rx_start_block.value = 0
        self.vif.rx_data.value = crc16
        await RisingEdge(self.vif.clk)

        self.vif.rx_data_valid.value = 0
        self.vif.rx_data.value = 0

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            if isinstance(item, PcieDllpItem):
                await self.drive_dllp(item)
            self.seq_item_port.item_done()


class PcieAppDriver(uvm_driver):
    """
    Drives Application-side streaming interface to inject TLPs into the controller.
    """
    def __init__(self, name: str = "pcie_app_driver", parent=None):
        super().__init__(name, parent)
        self.vif = None  # Reference to DUT app_if

    async def reset_bus(self):
        self.vif.tx_valid.value = 0
        self.vif.tx_sop.value = 0
        self.vif.tx_eop.value = 0
        self.vif.tx_data.value = 0
        self.vif.tx_keep.value = 0
        self.vif.tx_err.value = 0

    async def drive_tlp(self, item: PcieTlpItem):
        """Drive a TLP transaction as 64-bit streaming beats."""
        await RisingEdge(self.vif.clk)

        # DW0: {Fmt, Type, TC, ..., Length}
        dw0 = (
            (int(item.pkt_type) << 24) |
            ((item.tc & 0x7) << 20) |
            ((item.td & 0x1) << 15) |
            ((item.ep & 0x1) << 14) |
            ((item.attr & 0x3) << 12) |
            ((item.at & 0x3) << 10) |
            (item.length & 0x3FF)
        )

        # DW1: {RequesterID, Tag, LastBE, FirstBE}
        dw1 = (
            ((item.requester_id & 0xFFFF) << 16) |
            ((item.tag & 0xFF) << 8) |
            ((item.last_be & 0xF) << 4) |
            (item.first_be & 0xF)
        )

        # Beat 0: DW0 and DW1
        self.vif.tx_valid.value = 1
        self.vif.tx_sop.value = 1
        self.vif.tx_eop.value = 0
        self.vif.tx_data.value = (dw1 << 32) | dw0
        self.vif.tx_keep.value = 0xFF

        # Wait for handshake
        while True:
            await RisingEdge(self.vif.clk)
            if self.vif.tx_ready.value == 1:
                break

        self.vif.tx_sop.value = 0

        # Beat 1: DW2 (Address) and DW3
        dw2 = item.address & 0xFFFF_FFFC
        dw3 = (item.payload[0] if len(item.payload) > 0 else 0)
        self.vif.tx_data.value = (dw3 << 32) | dw2

        has_more_payload = len(item.payload) > 1
        if not has_more_payload:
            self.vif.tx_eop.value = 1

        while True:
            await RisingEdge(self.vif.clk)
            if self.vif.tx_ready.value == 1:
                break

        # Additional Payload beats
        payload_idx = 1
        while payload_idx < len(item.payload):
            dw_low = item.payload[payload_idx]
            dw_high = item.payload[payload_idx + 1] if (payload_idx + 1) < len(item.payload) else 0
            payload_idx += 2

            self.vif.tx_data.value = (dw_high << 32) | dw_low
            self.vif.tx_eop.value = 1 if payload_idx >= len(item.payload) else 0

            while True:
                await RisingEdge(self.vif.clk)
                if self.vif.tx_ready.value == 1:
                    break

        self.vif.tx_valid.value = 0
        self.vif.tx_eop.value = 0
        self.vif.tx_data.value = 0
        self.vif.tx_keep.value = 0

    async def run_phase(self):
        while True:
            item = await self.seq_item_port.get_next_item()
            if isinstance(item, PcieTlpItem):
                await self.drive_tlp(item)
            self.seq_item_port.item_done()
