"""
PCIe Subsystem pyuvm Base Test
"""

try:
    from pyuvm import uvm_test
except ImportError:
    class uvm_test:
        def __init__(self, name="uvm_test", parent=None):
            self.name = name
            self.parent = parent


class BaseTest(uvm_test):
    """
    Base test initiating the verification environment and controlling simulation phases.
    """
    def __init__(self, name: str = "base_test", parent=None):
        super().__init__(name, parent)

    def build_phase(self):
        super().build_phase() if hasattr(super(), "build_phase") else None

    async def run_phase(self):
        pass
