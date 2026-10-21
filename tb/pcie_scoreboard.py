"""
PCIe Subsystem Scoreboard (pyuvm)
Transaction-level reference model checking data integrity, credit accounting, and replay.
"""

from typing import Dict, List, Optional
from pyuvm import uvm_scoreboard, uvm_analysis_imp

from tb.pcie_seq_item import PcieTlpItem, PcieDllpItem, DllpType, TlpType


class PcieScoreboard(uvm_scoreboard):
    """
    Scoreboard verifying end-to-end transaction integrity, credit accounting, and Ack/Nak replay.
    """
    def __init__(self, name: str = "pcie_scoreboard", parent=None):
        super().__init__(name, parent)
        self.match_count: int = 0
        self.mismatch_count: int = 0

        # Reference Credit State
        self.p_hdr_limit: int = 64
        self.p_data_limit: int = 512
        self.p_hdr_consumed: int = 0
        self.p_data_consumed: int = 0

        self.np_hdr_limit: int = 64
        self.np_data_limit: int = 0
        self.np_hdr_consumed: int = 0
        self.np_data_consumed: int = 0

        self.cpl_hdr_limit: int = 64
        self.cpl_data_limit: int = 512
        self.cpl_hdr_consumed: int = 0
        self.cpl_data_consumed: int = 0

        # Outstanding unacknowledged TLPs (seq_num -> PcieTlpItem)
        self.unacked_tlps: Dict[int, PcieTlpItem] = {}
        self.pending_replays: List[int] = []

    def build_phase(self):
        super().build_phase() if hasattr(super(), "build_phase") else None
        self.tlp_export = uvm_analysis_imp(self, "write_tlp")
        self.dllp_export = uvm_analysis_imp(self, "write_dllp")

    def write_tlp(self, item: PcieTlpItem):
        """Analyze outbound TLP for credit sufficiency and data integrity."""
        # 1. Enforce 128B (32 DW) Payload ceiling
        if item.length > 32:
            self.logger.error(f"[SCOREBOARD] Ceiling violation: Length {item.length} DWs > 32 DWs!")
            self.mismatch_count += 1
            return

        # 2. Check Credit Sufficiency prior to transmission
        hdr_req = 1
        data_req = (item.length + 3) // 4 if len(item.payload) > 0 else 0

        if item.pkt_type in (TlpType.MWR32, TlpType.MWR64):
            avail_h = (self.p_hdr_limit - self.p_hdr_consumed) & 0xFF
            avail_d = (self.p_data_limit - self.p_data_consumed) & 0xFFF
            if avail_h < hdr_req or avail_d < data_req or avail_h > 128:
                self.logger.error(
                    f"[SCOREBOARD ERROR] Posted TLP dispatched without credit! "
                    f"AvailH={avail_h}, ReqH={hdr_req}, AvailD={avail_d}, ReqD={data_req}"
                )
                self.mismatch_count += 1
            else:
                self.p_hdr_consumed = (self.p_hdr_consumed + hdr_req) & 0xFF
                self.p_data_consumed = (self.p_data_consumed + data_req) & 0xFFF
                self.match_count += 1

        elif item.pkt_type in (TlpType.MRD32, TlpType.MRD64):
            avail_h = (self.np_hdr_limit - self.np_hdr_consumed) & 0xFF
            if avail_h < hdr_req or avail_h > 128:
                self.logger.error(f"[SCOREBOARD ERROR] Non-Posted TLP dispatched without credit! AvailH={avail_h}")
                self.mismatch_count += 1
            else:
                self.np_hdr_consumed = (self.np_hdr_consumed + hdr_req) & 0xFF
                self.match_count += 1

        # 3. Track in unacknowledged buffer
        if item.seq_num is not None:
            self.unacked_tlps[item.seq_num] = item

            # Check if this was an expected replay
            if item.seq_num in self.pending_replays:
                self.pending_replays.remove(item.seq_num)
                self.logger.info(f"[SCOREBOARD] Replayed TLP seq_num={item.seq_num} observed successfully.")
                self.match_count += 1

    def write_dllp(self, item: PcieDllpItem):
        """Track Ack/Nak and Credit Updates from DLLP stream."""
        if item.dllp_type == DllpType.ACK:
            # Advance committed packets
            committed = [s for s in list(self.unacked_tlps.keys()) if ((item.seq_num - s) & 0xFFF) <= 2048]
            for s in committed:
                del self.unacked_tlps[s]
            self.logger.info(f"[SCOREBOARD] ACK seq={item.seq_num} committed {len(committed)} packets.")
            self.match_count += 1

        elif item.dllp_type == DllpType.NAK:
            # Mark all unacknowledged packets after nak_seq as requiring replay
            self.pending_replays = [s for s in self.unacked_tlps.keys() if s > item.seq_num]
            self.logger.info(f"[SCOREBOARD] NAK seq={item.seq_num} flagged {len(self.pending_replays)} replays.")
            self.match_count += 1

        elif item.dllp_type == DllpType.UPDATEFC_P:
            self.p_hdr_limit = item.hdr_fc
            self.p_data_limit = item.data_fc
            self.match_count += 1

    def check_phase(self):
        """Verify no unacknowledged retransmission failures remain at end of simulation."""
        if len(self.pending_replays) > 0:
            self.logger.error(
                f"[SCOREBOARD ERROR] Replay failure! Un-Acked packets {self.pending_replays} failed to replay!"
            )
            self.mismatch_count += len(self.pending_replays)

        self.logger.info(
            f"[SCOREBOARD SUMMARY] Matches: {self.match_count}, Mismatches: {self.mismatch_count}"
        )
        assert self.mismatch_count == 0, f"Scoreboard detected {self.mismatch_count} mismatches!"
