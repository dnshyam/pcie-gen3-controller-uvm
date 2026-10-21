"""
PCIe Subsystem pyuvm Verification Environment
Assembles agents, monitors, scoreboard, and sequencers.
"""

from pyuvm import uvm_env, uvm_agent, uvm_sequencer
from tb.pcie_driver import PciePipeDriver, PcieAppDriver
from tb.pcie_monitor import PciePipeMonitor, PcieAppMonitor
from tb.pcie_scoreboard import PcieScoreboard
from tb.pcie_seq_item import PcieTlpItem, PcieDllpItem


class PciePipeAgent(uvm_agent):
    def __init__(self, name: str = "pcie_pipe_agent", parent=None):
        super().__init__(name, parent)
        self.driver = None
        self.sequencer = None
        self.monitor = None

    def build_phase(self):
        super().build_phase() if hasattr(super(), "build_phase") else None
        self.driver = PciePipeDriver("pipe_driver", self)
        self.sequencer = uvm_sequencer("pipe_sequencer", self)
        self.monitor = PciePipeMonitor("pipe_monitor", self)

    def connect_phase(self):
        super().connect_phase() if hasattr(super(), "connect_phase") else None
        self.driver.seq_item_port.connect(self.sequencer.seq_item_export)


class PcieAppAgent(uvm_agent):
    def __init__(self, name: str = "pcie_app_agent", parent=None):
        super().__init__(name, parent)
        self.driver = None
        self.sequencer = None
        self.monitor = None

    def build_phase(self):
        super().build_phase() if hasattr(super(), "build_phase") else None
        self.driver = PcieAppDriver("app_driver", self)
        self.sequencer = uvm_sequencer("app_sequencer", self)
        self.monitor = PcieAppMonitor("app_monitor", self)

    def connect_phase(self):
        super().connect_phase() if hasattr(super(), "connect_phase") else None
        self.driver.seq_item_port.connect(self.sequencer.seq_item_export)


class PcieEnv(uvm_env):
    """
    Top-level UVM Environment assembling PIPE agent, App agent, and Scoreboard.
    """
    def __init__(self, name: str = "pcie_env", parent=None):
        super().__init__(name, parent)
        self.pipe_agent = None
        self.app_agent = None
        self.scoreboard = None

    def build_phase(self):
        super().build_phase() if hasattr(super(), "build_phase") else None
        self.pipe_agent = PciePipeAgent("pipe_agent", self)
        self.app_agent = PcieAppAgent("app_agent", self)
        self.scoreboard = PcieScoreboard("scoreboard", self)

    def connect_phase(self):
        super().connect_phase() if hasattr(super(), "connect_phase") else None
        self.pipe_agent.monitor.tlp_ap.connect(self.scoreboard.tlp_export)
        self.pipe_agent.monitor.dllp_ap.connect(self.scoreboard.dllp_export)
