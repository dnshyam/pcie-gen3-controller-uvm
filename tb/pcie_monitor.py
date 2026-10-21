"""
PCIe Subsystem Monitors (cocotb / pyuvm)
Passive bus monitors sampling at posedge clk and broadcasting via uvm_analysis_port.
"""

import cocotb
from cocotb.triggers import RisingEdge
from pyuvm import uvm_monitor, uvm_analysis_port

from tb.pcie_seq_item import PcieTlpItem, PcieDllpItem, DllpType, TlpType


class PciePipeMonitor(uvm_monitor):
    """
    Monitors PIPE interface, decodes 32-bit frames, and broadcasts DLLP/TLP items.
    """
    def __init__(self, name: str = "pcie_pipe_monitor", parent=None):
        super().__init__(name, parent)
        self.vif = None
        self.dllp_ap = uvm_analysis_port("dllp_ap", self)
        self.tlp_ap = uvm_analysis_port("tlp_ap", self)

    async def run_phase(self):
        while True:
            await RisingEdge(self.vif.clk)

            # Sample outbound PHY data
            if int(self.vif.tx_data_valid.value) == 1:
                raw_data = int(self.vif.tx_data.value)
                byte0 = (raw_data >> 24) & 0xFF
                type_nibble = (byte0 >> 4) & 0xF

                # Check if DLLP (Ack=0x0, Nak=0x1, InitFC1=0x4..0x6, UpdateFC=0x8..0xA, InitFC2=0xC..0xE)
                if type_nibble in (0x0, 0x1, 0x4, 0x5, 0x6, 0x8, 0x9, 0xA, 0xC, 0xD, 0xE):
                    dllp = PcieDllpItem("mon_dllp")
                    dllp.dllp_type = DllpType(byte0)
                    if dllp.dllp_type in (DllpType.ACK, DllpType.NAK):
                        dllp.seq_num = raw_data & 0xFFF
                    else:
                        dllp.hdr_scale = (raw_data >> 22) & 0x3
                        dllp.hdr_fc = (raw_data >> 14) & 0xFF
                        dllp.data_scale = (raw_data >> 12) & 0x3
                        dllp.data_fc = raw_data & 0xFFF
                    self.dllp_ap.write(dllp)
                else:
                    # TLP Header DW0
                    tlp = PcieTlpItem("mon_tlp")
                    tlp.pkt_type = TlpType(byte0)
                    tlp.tc = (raw_data >> 20) & 0x7
                    tlp.length = raw_data & 0x3FF
                    self.tlp_ap.write(tlp)


class PcieAppMonitor(uvm_monitor):
    """
    Monitors Application interface to verify received TLPs and credit availability.
    """
    def __init__(self, name: str = "pcie_app_monitor", parent=None):
        super().__init__(name, parent)
        self.vif = None
        self.ap = uvm_analysis_port("app_rx_ap", self)

    async def run_phase(self):
        while True:
            await RisingEdge(self.vif.clk)
            if int(self.vif.rx_valid.value) == 1 and int(self.vif.rx_ready.value) == 1:
                tlp = PcieTlpItem("mon_app_tlp")
                tlp.payload = [int(self.vif.rx_data.value) & 0xFFFF_FFFF]
                self.ap.write(tlp)
