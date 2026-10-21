"""
PCIe Gen 3 Sequence Items for pyuvm & cocotb
Standard: PCI Express Base Specification Revision 3.0
"""

import random
from enum import IntEnum
from typing import List, Optional
from pyuvm import uvm_sequence_item


class TlpType(IntEnum):
    MRD32 = 0b000_00000
    MRD64 = 0b001_00000
    MWR32 = 0b010_00000
    MWR64 = 0b011_00000
    CPL   = 0b000_01010
    CPLD  = 0b010_01010


class DllpType(IntEnum):
    ACK          = 0x00
    NAK          = 0x10
    INITFC1_P    = 0x40
    INITFC1_NP   = 0x50
    INITFC1_CPL  = 0x60
    INITFC2_P    = 0xC0
    INITFC2_NP   = 0xD0
    INITFC2_CPL  = 0xE0
    UPDATEFC_P   = 0x80
    UPDATEFC_NP  = 0x90
    UPDATEFC_CPL = 0xA0


class CplStatus(IntEnum):
    SC  = 0b000  # Successful Completion
    UR  = 0b001  # Unsupported Request
    CRS = 0b010  # Configuration Retry Status
    CA  = 0b100  # Completer Abort


class PcieTlpItem(uvm_sequence_item):
    """
    Transaction Layer Packet (TLP) Sequence Item with constrained randomization.
    """
    def __init__(self, name: str = "pcie_tlp_item"):
        super().__init__(name)
        self.pkt_type: TlpType = TlpType.MWR32
        self.tc: int = 0
        self.td: int = 0
        self.ep: int = 0
        self.attr: int = 0
        self.at: int = 0
        self.length: int = 1               # Length in DWs (1 to 32)
        self.requester_id: int = 0x0100
        self.completer_id: int = 0x0000
        self.tag: int = 0
        self.first_be: int = 0xF
        self.last_be: int = 0x0
        self.address: int = 0x1000_0000
        self.cpl_status: CplStatus = CplStatus.SC
        self.byte_count: int = 4
        self.lower_addr: int = 0
        self.payload: List[int] = [0xDEADBEEF] # 32-bit DWORDs
        self.seq_num: Optional[int] = None
        self.lcrc: Optional[int] = None
        self.corrupt_crc: bool = False     # Flag to inject bad LCRC

    def randomize(
        self,
        traffic_types: Optional[List[TlpType]] = None,
        allow_invalid_len: bool = False,
        inject_crc_err: bool = False
    ) -> bool:
        """
        Custom constrained randomization supporting valid/invalid lengths and CRC corruption.
        """
        types = traffic_types if traffic_types else [TlpType.MRD32, TlpType.MWR32, TlpType.CPLD]
        self.pkt_type = random.choice(types)
        self.tc = random.randint(0, 7)
        self.tag = random.randint(0, 255)
        self.address = random.randint(0x1000, 0xFFFF) & ~0x3 # 4-byte aligned
        self.corrupt_crc = inject_crc_err

        # Constrain payload length
        if allow_invalid_len:
            # Generate invalid payload length (> 32 DWs / 128B) to test MPS ceiling
            self.length = random.randint(33, 64)
        else:
            # Valid PCIe MPS ceiling (1..32 DWs = 4..128 Bytes)
            if self.pkt_type in (TlpType.MRD32, TlpType.MRD64, TlpType.CPL):
                self.length = random.randint(1, 32)
                self.payload = []
            else:
                self.length = random.randint(1, 32)
                self.payload = [random.randint(0, 0xFFFF_FFFF) for _ in range(self.length)]

        self.byte_count = self.length * 4
        self.first_be = 0xF
        self.last_be = 0xF if self.length > 1 else 0x0
        return True

    def __str__(self) -> str:
        return (f"[{self.name}] Type={self.pkt_type.name} Tag={self.tag} "
                f"Addr=0x{self.address:08X} Len={self.length}DW "
                f"PayloadBytes={len(self.payload)*4} CorruptCRC={self.corrupt_crc}")


class PcieDllpItem(uvm_sequence_item):
    """
    Data Link Layer Packet (DLLP) Sequence Item with constrained randomization.
    """
    def __init__(self, name: str = "pcie_dllp_item"):
        super().__init__(name)
        self.dllp_type: DllpType = DllpType.ACK
        self.vc: int = 0
        self.hdr_scale: int = 0
        self.hdr_fc: int = 64
        self.data_scale: int = 0
        self.data_fc: int = 512
        self.seq_num: int = 0
        self.crc16: Optional[int] = None
        self.corrupt_crc: bool = False

    def randomize(
        self,
        dllp_types: Optional[List[DllpType]] = None,
        inject_crc_err: bool = False
    ) -> bool:
        types = dllp_types if dllp_types else [DllpType.ACK, DllpType.NAK, DllpType.UPDATEFC_P]
        self.dllp_type = random.choice(types)
        self.vc = 0
        self.seq_num = random.randint(0, 4095)
        self.hdr_fc = random.randint(1, 128)
        self.data_fc = random.randint(1, 2048)
        self.corrupt_crc = inject_crc_err
        return True

    def __str__(self) -> str:
        if self.dllp_type in (DllpType.ACK, DllpType.NAK):
            return f"[{self.name}] {self.dllp_type.name} SeqNum={self.seq_num} CorruptCRC={self.corrupt_crc}"
        else:
            return (f"[{self.name}] {self.dllp_type.name} "
                    f"HdrFC={self.hdr_fc} DataFC={self.data_fc} CorruptCRC={self.corrupt_crc}")
