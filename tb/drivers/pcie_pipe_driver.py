"""
PCIe PIPE Interface Driver (cocotb / pyuvm)
"""

try:
    from pyuvm import uvm_driver
except ImportError:
    class uvm_driver:
        def __init__(self, name="uvm_driver", parent=None):
            self.name = name
            self.parent = parent


class PciePipeDriver(uvm_driver):
    """
    Driver responsible for translating DLLP/TLP packets into PIPE physical signals.
    """
    def __init__(self, name: str = "pcie_pipe_driver", parent=None):
        super().__init__(name, parent)
        self.vif = None

    async def run_phase(self):
        pass
