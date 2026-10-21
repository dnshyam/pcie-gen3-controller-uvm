"""
PCIe Subsystem pyuvm Verification Environment
"""

try:
    from pyuvm import uvm_env
except ImportError:
    class uvm_env:
        def __init__(self, name="uvm_env", parent=None):
            self.name = name
            self.parent = parent


class PcieEnv(uvm_env):
    """
    Top-level verification environment assembling agents, scoreboard, and virtual sequencer.
    """
    def __init__(self, name: str = "pcie_env", parent=None):
        super().__init__(name, parent)

    def build_phase(self):
        super().build_phase() if hasattr(super(), "build_phase") else None
