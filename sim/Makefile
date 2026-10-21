#=============================================================================
# File: sim/Makefile
# Project: PCIe Gen 3 Controller Subsystem & UVM Testbench
# Description: Orchestration Makefile for Verilator compilation, cocotb/pyuvm
#              regression testing, linting, and waveform viewing.
#=============================================================================

SHELL            := /bin/bash
PROJ_ROOT        ?= $(shell if [ -d "$$HOME/pcie_project" ]; then echo "$$HOME/pcie_project"; else echo "$(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)"; fi)
RTL_DIR          := $(PROJ_ROOT)/rtl
TB_DIR           := $(PROJ_ROOT)/tb
SIM_DIR          := $(PROJ_ROOT)/sim
BUILD_DIR        ?= $(HOME)/pcie_build

# Tool Paths & Defaults
VERILATOR        ?= verilator
PYTHON           ?= python3
GTKWAVE          ?= gtkwave
COCOTB_CONFIG    ?= cocotb-config

# Cocotb Discovery via cocotb-config & Virtualenvs
VENV_PY          := $(shell if [ -f "$$HOME/.venv_pcie/bin/python" ]; then echo "$$HOME/.venv_pcie/bin/python"; elif [ -f "$(PROJ_ROOT)/.venv/bin/python" ]; then echo "$(PROJ_ROOT)/.venv/bin/python"; elif [ -f "$(PROJ_ROOT)/.venv/Scripts/python.exe" ]; then echo "$(PROJ_ROOT)/.venv/Scripts/python.exe"; fi)
COCOTB_CONFIG    ?= $(shell if [ -f "$$HOME/.venv_pcie/bin/cocotb-config" ]; then echo "$$HOME/.venv_pcie/bin/cocotb-config"; elif [ -f "$(PROJ_ROOT)/.venv/bin/cocotb-config" ]; then echo "$(PROJ_ROOT)/.venv/bin/cocotb-config"; else echo "cocotb-config"; fi)

COCOTB_LIB_DIR   := $(shell $(COCOTB_CONFIG) --lib-dir 2>/dev/null)
COCOTB_SHARE_DIR := $(shell $(COCOTB_CONFIG) --share 2>/dev/null)
PYTHON_BIN       := $(if $(VENV_PY),$(VENV_PY),$(shell $(COCOTB_CONFIG) --python-bin 2>/dev/null || which $(PYTHON)))

# Verilator Compilation Flags
VERILATOR_FLAGS  := --trace --trace-fst -Wall -Wno-fatal \
                    -Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
                    -Wno-MULTITOP -Wno-SYNCASYNCNET -Wno-TIMESCALEMOD \
                    --timescale 1ns/1ps --timing --assert

RTL_SRCS := $(RTL_DIR)/pcie_pkg.sv \
            $(RTL_DIR)/lcrc32.sv \
            $(RTL_DIR)/tlp_engine.sv \
            $(RTL_DIR)/dllp_crc16.sv \
            $(RTL_DIR)/replay_buffer.sv \
            $(RTL_DIR)/dllp_engine.sv \
            $(RTL_DIR)/pcie_pipe_if.sv \
            $(RTL_DIR)/pcie_app_if.sv \
            $(RTL_DIR)/pcie_controller_top.sv \
            $(RTL_DIR)/pcie_protocol_sva.sv

TB_SRCS  := $(TB_DIR)/tb_top.sv

.PHONY: all compile lint test pytest waves view clean help

all: lint test

help:
	@echo "PCIe Gen 3 Controller Subsystem Verification Makefile"
	@echo "----------------------------------------------------"
	@echo "Targets:"
	@echo "  make lint    : Run static Verilator syntax/semantic lint checks on RTL"
	@echo "  make compile : Compile RTL and Testbench using Verilator with FST/VCD tracing"
	@echo "  make test    : Run cocotb/pyuvm test suite (Flow Control, Backpressure, Nak Replay)"
	@echo "  make pytest  : Run pytest regression with full duration and result reporting"
	@echo "  make waves   : Launch GTKWave on generated simulation waveform (FST / VCD)"
	@echo "  make clean   : Remove build directory, cache files, and waveform dumps"

lint:
	@echo "=== [1/2] Verilator Static Linting Check ==="
	$(VERILATOR) --lint-only -Wall -Wno-fatal \
		-Wno-DECLFILENAME -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL -Wno-SYNCASYNCNET -Wno-TIMESCALEMOD \
		-I"$(RTL_DIR)" $(foreach f,$(RTL_SRCS),"$(f)")
	@echo "=== Lint check PASSED ==="

compile:
	@echo "=== Compiling RTL and TB Top with Verilator ==="
	@mkdir -p $(BUILD_DIR)
	$(VERILATOR) --cc --exe $(VERILATOR_FLAGS) \
		-I$(RTL_DIR) -I$(TB_DIR) \
		--top-module tb_top \
		--Mdir $(BUILD_DIR) \
		$(RTL_SRCS) $(TB_SRCS) \
		-LDFLAGS "-L$(COCOTB_LIB_DIR) -lcocotbvpi_verilator -pthread"
	@$(MAKE) -C $(BUILD_DIR) -f Vtb_top.mk
	@echo "=== Compilation Complete ==="

test:
	@echo "=== Executing Cocotb & pyuvm Regression ==="
	@PYTHONPATH="$(TB_DIR):$(PROJ_ROOT):$$PYTHONPATH" $(PYTHON_BIN) $(SIM_DIR)/test_runner.py

pytest:
	@echo "=== Executing Pytest Framework Regression ==="
	@cd $(SIM_DIR) && PYTHONPATH="$(TB_DIR):$(PROJ_ROOT):$$PYTHONPATH" $(PYTHON_BIN) -m pytest -v

waves view:
	@echo "=== Opening Waveforms in GTKWave ==="
	@if [ -f "$(BUILD_DIR)/dump.fst" ]; then \
		$(GTKWAVE) "$(BUILD_DIR)/dump.fst" & \
	elif [ -f "$(BUILD_DIR)/dump.vcd" ]; then \
		$(GTKWAVE) "$(BUILD_DIR)/dump.vcd" & \
	else \
		echo "No waveform file found in $(BUILD_DIR). Run 'make test' first."; \
	fi

clean:
	@echo "=== Cleaning Simulation Artifacts ==="
	@rm -rf $(BUILD_DIR) $(PROJ_ROOT)/sim_build $(PROJ_ROOT)/sim_build_linux
	@rm -rf $(SIM_DIR)/.pytest_cache $(SIM_DIR)/__pycache__ $(TB_DIR)/__pycache__
	@rm -f $(SIM_DIR)/*.vcd $(SIM_DIR)/*.fst $(PROJ_ROOT)/*.vcd $(PROJ_ROOT)/*.fst
	@echo "=== Clean Complete ==="
