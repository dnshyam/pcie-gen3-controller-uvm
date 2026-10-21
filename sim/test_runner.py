"""
Cocotb Runner Script for Verilator Simulation
Standard: Cocotb 2.x cocotb_tools.runner
"""

import os
import sys
from pathlib import Path
from cocotb_tools.runner import get_runner


def run_pcie_tests():
    if os.name == "posix":
        build_dir = str(Path.home() / "pcie_build")
        if (Path.home() / "pcie_project").exists():
            proj_dir = Path.home() / "pcie_project"
        else:
            proj_dir = Path(__file__).resolve().parent.parent
    else:
        if Path("P:/").exists():
            proj_dir = Path("P:/")
            os.chdir("P:/")
        else:
            proj_dir = Path(__file__).resolve().parent.parent
        build_dir = str(proj_dir / "sim_build")

    rtl_dir = proj_dir / "rtl"
    tb_dir = proj_dir / "tb"

    verilog_sources = [
        rtl_dir / "pcie_pkg.sv",
        rtl_dir / "lcrc32.sv",
        rtl_dir / "tlp_engine.sv",
        rtl_dir / "dllp_crc16.sv",
        rtl_dir / "replay_buffer.sv",
        rtl_dir / "dllp_engine.sv",
        rtl_dir / "pcie_pipe_if.sv",
        rtl_dir / "pcie_app_if.sv",
        rtl_dir / "pcie_controller_top.sv",
        rtl_dir / "pcie_protocol_sva.sv",
        tb_dir / "tb_top.sv",
    ]

    if os.name != "posix":
        # Ensure .venv/Scripts and msys64/mingw64 toolchain are in PATH
        msys_paths = [
            str(proj_dir / ".venv" / "Scripts"),
            r"C:\msys64\mingw64\bin",
            r"C:\msys64\usr\bin"
        ]
        os.environ["PATH"] = os.pathsep.join(msys_paths) + os.pathsep + os.environ.get("PATH", "")
        if "VERILATOR_ROOT" in os.environ:
            del os.environ["VERILATOR_ROOT"]

    waves = os.environ.get("WAVES", "1") == "1"

    runner = get_runner("verilator")
    runner.build(
        sources=[str(s) for s in verilog_sources],
        hdl_toplevel="tb_top",
        includes=[str(rtl_dir), str(tb_dir)],
        build_dir=build_dir,
        build_args=[
            "-Wall",
            "-Wno-fatal",
            "-Wno-DECLFILENAME",
            "-Wno-UNUSEDPARAM",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-MULTITOP",
            "-Wno-SYNCASYNCNET",
            "-Wno-TIMESCALEMOD",
            "--timescale", "1ns/1ps",
            "--timing",
            "--assert",
        ],
        waves=waves,
        always=True,
    )

    # Set sys.path and PYTHONPATH so cocotb discovers tb modules
    if str(tb_dir) not in sys.path:
        sys.path.insert(0, str(tb_dir))
    if str(proj_dir) not in sys.path:
        sys.path.insert(0, str(proj_dir))

    pythonpath = f"{tb_dir}{os.pathsep}{proj_dir}{os.pathsep}{os.environ.get('PYTHONPATH', '')}"
    os.environ["PYTHONPATH"] = pythonpath

    runner.test(
        hdl_toplevel="tb_top",
        test_module="test_pcie_basic",
        test_dir=build_dir,
        build_dir=build_dir,
        waves=waves,
        extra_env={"PYTHONPATH": pythonpath},
    )


def test_pcie_regression():
    """Pytest entrypoint for the full PCIe verification suite."""
    run_pcie_tests()


if __name__ == "__main__":
    run_pcie_tests()
