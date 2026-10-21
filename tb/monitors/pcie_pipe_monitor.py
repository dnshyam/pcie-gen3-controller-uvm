"""
PCIe PIPE Interface Monitor (cocotb / pyuvm)
"""

try:
    from pyuvm import uvm_monitor
except ImportError:
    class uvm_monitor:
        def __init__(self, name="uvm_monitor", parent=None):
            self.name = name
            self.parent = parent


class PciePipeMonitor(uvm_monitor):
    """
    Passive monitor sampling the PIPE interface, parsing framing, DLLPs, and TLPs.
    """
    def __init__(self, name: str = "pcie_pipe_monitor", parent=None):
        super().__init__(name, parent)
        self.vif = None

    async def run_phase(self):
        pass
