"""
PCIe Gen 3 pyuvm / cocotb Sequence Items
Matches SystemVerilog definitions in rtl/pcie_pkg.sv
"""

from enum import IntEnum
from typing import List, Optional

try:
    from pyuvm import uvm_sequence_item
except ImportError:
    class uvm_sequence_item:
        def __init__(self, name="uvm_sequence_item"):
            self.name = name


class TlpPktType(IntEnum):
    TLP_MRD32 = 0b000_00000
    TLP_MRD64 = 0b001_00000
    TLP_MWR32 = 0b010_00000
    TLP_MWR64 = 0b011_00000
    TLP_CPL   = 0b000_01010
    TLP_CPLD  = 0b010_01010


class DllpType(IntEnum):
    DLLP_ACK         = 0x00
    DLLP_NAK         = 0x10
    DLLP_PM_ENTER_L1 = 0x20
    DLLP_PM_ENTER_L2 = 0x21
    DLLP_PM_REQ_ACK  = 0x24
    DLLP_INITFC1_P   = 0x40
    DLLP_INITFC1_NP  = 0x50
    DLLP_INITFC1_CPL = 0x60
    DLLP_INITFC2_P   = 0xC0
    DLLP_INITFC2_NP  = 0xD0
    DLLP_INITFC2_CPL = 0xE0
    DLLP_UPDATEFC_P  = 0x80
    DLLP_UPDATEFC_NP = 0x90
    DLLP_UPDATEFC_CPL= 0xA0


class CplStatus(IntEnum):
    CPL_STATUS_SC  = 0b000
    CPL_STATUS_UR  = 0b001
    CPL_STATUS_CRS = 0b010
    CPL_STATUS_CA  = 0b100


class PcieTlpSeqItem(uvm_sequence_item):
    """
    TLP Transaction Sequence Item for pyuvm testbench
    """
    def __init__(self, name: str = "pcie_tlp_seq_item"):
        super().__init__(name)
        self.pkt_type: TlpPktType = TlpPktType.TLP_MWR32
        self.tc: int = 0
        self.td: int = 0
        self.ep: int = 0
        self.attr: int = 0
        self.at: int = 0
        self.length: int = 1  # In DWs (1..32)
        self.requester_id: int = 0x0100
        self.completer_id: int = 0x0000
        self.tag: int = 0
        self.first_be: int = 0xF
        self.last_be: int = 0x0
        self.address: int = 0x0000_0000
        self.cpl_status: CplStatus = CplStatus.CPL_STATUS_SC
        self.byte_count: int = 4
        self.lower_addr: int = 0
        self.payload: List[int] = []  # List of 32-bit DWORDs (max 32 DWs = 128 Bytes)
        self.seq_num: Optional[int] = None
        self.lcrc: Optional[int] = None

    def __str__(self) -> str:
        return (f"[{self.name}] Type={self.pkt_type.name} "
                f"Addr=0x{self.address:08X} Tag={self.tag} "
                f"Len={self.length}DW PayloadLen={len(self.payload)}DW")


class PcieDllpSeqItem(uvm_sequence_item):
    """
    DLLP Transaction Sequence Item for pyuvm testbench
    """
    def __init__(self, name: str = "pcie_dllp_seq_item"):
        super().__init__(name)
        self.dllp_type: DllpType = DllpType.DLLP_ACK
        self.vc: int = 0
        self.hdr_scale: int = 0
        self.hdr_fc: int = 0
        self.data_scale: int = 0
        self.data_fc: int = 0
        self.seq_num: int = 0
        self.crc16: Optional[int] = None

    def __str__(self) -> str:
        if self.dllp_type in (DllpType.DLLP_ACK, DllpType.DLLP_NAK):
            return f"[{self.name}] {self.dllp_type.name} SeqNum={self.seq_num}"
        else:
            return (f"[{self.name}] {self.dllp_type.name} VC={self.vc} "
                    f"HdrFC={self.hdr_fc} (Scale={self.hdr_scale}) "
                    f"DataFC={self.data_fc} (Scale={self.data_scale})")
