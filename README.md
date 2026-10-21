# Synthesizable PCIe Gen 3 Controller Subsystem & pyuvm Testbench

An open-source, synthesizable PCI Express Base Specification Rev 3.0 controller subsystem (Transaction Layer & Data Link Layer subset) verified using Verilator, cocotb, and pyuvm.

---

## 1. Subsystem Architecture

The controller implements a synthesizable PCIe Gen 3 core targeted at FPGA and ASIC prototypes. It interfaces to application logic via a 64-bit AXI-Stream interface and connects to an external PHY / SERDES MAC via a standard 32-bit PIPE interface running at 250 MHz (Gen 3 x1 equivalent throughput of 8.0 GT/s).

```
 +-------------------------------------------------------------------------------+
 |                               Application Logic                               |
 +-------------------------------------------------------------------------------+
                       |                                   ^
       app_tx_* (64b)  | (Tx Streaming TLP)  app_rx_* (64b)| (Rx Completions)
                       v                                   |
 +-------------------------------------------------------------------------------+
 |                        Transaction Layer Core (tlp_engine)                    |
 |                                                                               |
 |   +------------------------------------+   +------------------------------+   |
 |   | TLP Ingress Parser & Disassembler  |   | Packet Assembler & Formatter |   |
 |   | - MPS 128-Byte Payload Ceiling     |   | - 3DW/4DW Header Generation  |   |
 |   | - 32-bit Parallel LCRC Checker     |   | - 32-bit Parallel LCRC Gen   |   |
 |   +------------------------------------+   +------------------------------+   |
 |                                                                               |
 |   +-----------------------------------------------------------------------+   |
 |   | Credit Flow Control Accounting (P, NP, Cpl)                           |   |
 |   | - Remote Credit Limit vs. Local Consumed (PH, PD, NPH, NPD, CPLH, CPLD) |
 |   | - Transmit Throttle & app_tx_ready Backpressure Generator             |   |
 |   +-----------------------------------------------------------------------+   |
 +-------------------------------------------------------------------------------+
                       |                                   ^
        tlp_to_replay  | (Unpacked TLP)                    | Credit Returns /
                       v                                   | Ack/Nak Feedback
 +-------------------------------------------------------------------------------+
 |                          Data Link Layer Subsystem                            |
 |                                                                               |
 |   +----------------------------------+     +------------------------------+   |
 |   |  Replay Buffer (replay_buffer)   |     | DLLP Engine (dllp_engine)    |   |
 |   |  - 64-Entry Dual-Port RAM Ring   |     | - Flow Control Init FSM      |   |
 |   |  - 12-bit Sequence Tagging       |     |   (INIT1 -> INIT2 -> ACTIVE) |   |
 |   |  - Replay Timer & Nak Retransmit |     | - Periodic UpdateFC Generator|   |
 |   |  - Rollback / Commit Pointers    |     | - Strict DLLP Priority Arb   |   |
 |   +----------------------------------+     +------------------------------+   |
 |                     \                                     /                   |
 |                      \                                   /                    |
 |                       v                                 v                     |
 |                     +-------------------------------------+                   |
 |                     | Parallel 16-bit CRC Generator/Check |                   |
 |                     | (Polynomial: x^16 + x^12 + x^5 + 1) |                   |
 |                     +-------------------------------------+                   |
 +-------------------------------------------------------------------------------+
                                         |
                       out_frame (48b DLLP / 32b TLP DW)
                                         v
 +-------------------------------------------------------------------------------+
 |                       PIPE 32-bit Physical Layer Adapter                      |
 |                   (128b/130b Sync Headers, 8.0 GT/s Signaling)                |
 +-------------------------------------------------------------------------------+
                                         |
                                         v
 +-------------------------------------------------------------------------------+
 |             Verilator Simulation Wrapper (tb_top.sv) & SVA Bindings           |
 |              - pcie_protocol_sva: 128B MPS, Modulo Credit Invariants          |
 |              - cocotb Drivers, Passive Bus Monitors & pyuvm Scoreboard        |
 +-------------------------------------------------------------------------------+
```

---

## 2. Engineering Trade-offs & Design Decisions

### 2.1 Store-and-Forward vs. Cut-Through Replay Buffer
* **Decision**: Implemented a **store-and-forward** circular dual-port RAM architecture for the Data Link Layer Replay Buffer.
* **Rationale**: In cut-through mode, data bytes are streamed to the physical layer before the full packet has been verified and stored in local SRAM. If the application asserts `app_tx_err` midway through a packet or if credit checks fail late, a cut-through engine must inject an `EDB` (End Bad) framing marker or corrupt the LCRC to force link partner rejection. Given our configured 128-byte Maximum Payload Size (MPS), the latency penalty of storing up to 32 DWs in a dual-port RAM block is at most 16 clock cycles at 64-bit width. The store-and-forward design guarantees that only validated, sequence-tagged packets enter the transmission pipeline, significantly simplifying recovery state machines and eliminating corrupted intermediate state on retransmissions.

### 2.2 pyuvm + Verilator vs. Proprietary EDA Toolchains (VCS / Questa / Xcelium)
* **Decision**: Adopted **Verilator 5.0+** paired with **cocotb 2.x** and **pyuvm 5.0** as the primary verification engine.
* **Rationale**: Traditional commercial SystemVerilog UVM environments require proprietary EDA simulator licenses that are inaccessible for independent research, open-source silicon tapeouts, and continuous integration runners. Verilator compiles synthesizable SystemVerilog into high-performance multi-threaded C++ binaries that execute simulation cycles at orders of magnitude higher throughput than interpreted event-driven simulators. By layering Python-based UVM (`pyuvm`) on top via cocotb's VPI bridge, we achieve:
  * Strict IEEE 1800.2 UVM structural compliance (phases, sequence items, drivers, monitors, analysis ports, and scoreboards).
  * Fast compilation times (<2 seconds for the complete subsystem).
  * Seamless CI/CD execution without license server dependencies.

### 2.3 Modular Credit Accounting (Modulo 256 / 4096 Arithmetic)
* **Decision**: Implemented PCIe-standard modular subtraction:
  $$\text{Available} = (\text{Allocated Limit} - \text{Total Consumed}) \pmod{2^N}$$
* **Rationale**: Rather than maintaining a decrementing credit pool (which requires complex credit-refund arbitration whenever multiple TLPs are dropped or uncommitted), PCIe maintains monotonic accumulating counters ($N=8$ bits for Headers, $N=12$ bits for Data). The subsystem compares signed distance modulo $2^N$ to confirm that available credit does not exceed $2^{N-1}$ units, natively handling rollover at 256 and 4096 without arithmetic discontinuities.

---

## 3. Directory Layout

```
.
├── rtl/                        # Synthesizable SystemVerilog Modules
│   ├── pcie_pkg.sv             # Enums, packet structs, CRC functions, parameters
│   ├── lcrc32.sv               # Parallel 32-bit LCRC generator/checker (Poly 0x04C11DB7)
│   ├── dllp_crc16.sv           # Parallel 16-bit CRC for DLLPs (Poly 0x1021)
│   ├── replay_buffer.sv        # 64-entry dual-port circular replay buffer
│   ├── dllp_engine.sv          # Flow control initialization FSM, UpdateFC & arbiter
│   ├── tlp_engine.sv           # TLP packet assembler, credit limiter & backpressure
│   ├── pcie_pipe_if.sv         # 32-bit Gen 3 PHY Interface (PIPE spec)
│   ├── pcie_app_if.sv          # 64-bit AXI-Stream Application Interface
│   ├── pcie_controller_top.sv  # Subsystem top wrapper
│   └── pcie_protocol_sva.sv    # SystemVerilog Assertions & cover properties
├── tb/                         # Verification Environment (cocotb / pyuvm)
│   ├── tb_top.sv               # Top-level SystemVerilog testbench pin wrapper
│   ├── pcie_seq_item.py        # PcieTlpItem & PcieDllpItem with constrained randomization
│   ├── pcie_driver.py          # PIPE and App coroutine drivers
│   ├── pcie_monitor.py         # Passive bus monitors with uvm_analysis_port
│   ├── pcie_scoreboard.py      # Reference model tracking credit accounting & replays
│   ├── pcie_env.py             # UVM agent, environment, and scoreboard hierarchy
│   └── test_pcie_basic.py      # Directed and constrained-random test cases
├── sim/                        # Simulation & Build Infrastructure
│   ├── Makefile                # Verilator compile, pytest, GTKWave targets
│   ├── test_runner.py          # Cocotb runner with FST/VCD tracing
│   ├── verilator.flags         # Optimization and warning flags
│   └── pytest.ini              # Pytest configuration
└── docs/                       # Technical Specifications & Packet Formats
    ├── specifications.md       # Subsystem architecture & timing specification
    ├── packet_formats.md       # Header encoding for TLPs and DLLPs
    └── credit_tracking_architecture.md # Flow control credit theory
```

---

## 4. Verification & Protocol Invariants

The testbench environment validates the controller using both **SystemVerilog Assertions (SVA)** embedded at the hardware interface and **pyuvm Scoreboard reference models** operating on high-level transaction streams.

### 4.1 SystemVerilog Assertions ([`rtl/pcie_protocol_sva.sv`](file:///c:/Users/shyam/Downloads/Project/NVIDIA/PCIe%20Gen%203%20Controller%20Subsystem%20&%20UVM%20Testbench/rtl/pcie_protocol_sva.sv))

| Assertion Name | Description | Protocol Constraint Checked |
|---|---|---|
| `assert_tlp_out_max_payload` | Payload length ceiling | Outbound TLP payload $\le$ 32 DWs (128 Bytes). |
| `assert_posted_hdr_credit_no_underflow` | Posted Header Credit Safety | Remote credit limit minus consumed count never underflows mod 256. |
| `assert_posted_write_has_credits` | Credit-Checked Dispatch | No Memory Write (`MWr32`/`MWr64`) is committed without available credits. |
| `assert_nak_triggers_replay` | Nak Retransmission Invariant | Inbound `Nak` DLLP triggers state transition to `S_REPLAY` within 1 clock cycle. |
| `assert_seq_num_increments_mod4096` | Sequence Monotonicity | Transmitted sequence numbers increment strictly by 1 mod 4096. |
| `assert_seq_num_stable_when_idle` | Sequence Stability | Sequence numbers remain invariant when no fresh TLP is committed. |
| `assert_dllp_strict_priority` | Arbitration Priority | Outbound DLLPs (`Ack`, `Nak`, `UpdateFC`) preempt pending TLPs. |

### 4.2 pyuvm Test Cases ([`tb/test_pcie_basic.py`](file:///c:/Users/shyam/Downloads/Project/NVIDIA/PCIe%20Gen%203%20Controller%20Subsystem%20&%20UVM%20Testbench/tb/test_pcie_basic.py))

1. **`test_flow_control_init`**:
   * Simulates link partner handshakes (`InitFC1-P/NP/Cpl` followed by `InitFC2-P/NP/Cpl`).
   * Validates internal FSM progression (`FC_INIT1` $\rightarrow$ `FC_INIT2` $\rightarrow$ `ACTIVE`).
   * Confirms `app_fc_init_done` and `app_link_up` assert with correct initial credit balances.
2. **`test_credit_exhaustion`**:
   * Advertises minimal partner credits (e.g., 2 Header credits).
   * Injects back-to-back `MWr32` transactions until remote credits are fully exhausted.
   * Confirms the controller immediately asserts backpressure on `app_tx_ready` ($=0$), blocking further application injection.
   * Injects an `UpdateFC_P` packet from the partner and verifies that `app_tx_ready` unblocks.
3. **`test_crc_error_nak_replay`**:
   * Injects an initial `MWr32` packet into the replay buffer ring.
   * Injects a `Nak` DLLP requesting retransmission of packet sequence 0 (`seq_num=0xFFF`).
   * Confirms the replay buffer FSM transitions to `S_REPLAY`, rewinds its read pointer to the oldest unacknowledged packet, and re-emits the exact uncorrupted TLP across the PIPE interface.

---

## 5. Quickstart Guide

### Prerequisites
* **Linux / WSL2** (Ubuntu 22.04 or 24.04 recommended)
* **Verilator** $\ge$ 5.020 (`sudo apt install verilator`)
* **Python** $\ge$ 3.10
* **GTKWave** (`sudo apt install gtkwave`)

### Setup Virtual Environment
```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

*(Dependencies: `cocotb>=2.0.0`, `cocotb-tools`, `pyuvm>=5.0.0`, `pytest`)*

### Running Regressions

From the project root:

```bash
# 1. Run static Verilator lint checks on all RTL and interfaces
make -C sim lint

# 2. Run the full cocotb / pyuvm test regression suite
make -C sim test

# 3. Alternatively, run using pytest with execution profiling
make -C sim pytest
```

### Regression Output Example
```
===================================================================================================
** TEST                                       STATUS  SIM TIME (ns)  REAL TIME (s)  RATIO (ns/s) **
===================================================================================================
** test_pcie_basic.test_flow_control_init      PASS         188.00           0.00     152586.01  **
** test_pcie_basic.test_credit_exhaustion      PASS         308.00           0.00     279492.34  **
** test_pcie_basic.test_crc_error_nak_replay   PASS         244.00           0.00     208149.92  **
===================================================================================================
** TESTS=3 PASS=3 FAIL=0 SKIP=0                             740.00           0.00     172195.88  **
===================================================================================================
```

---

## 6. Inspecting Waveforms (Nak Replay Verification)

When running simulations, Verilator generates an execution waveform (`dump.vcd` or `dump.fst`) in `~/pcie_build` or `sim/`.

To launch GTKWave:
```bash
make -C sim waves
```

### Key Signal Trace for Nak Retransmission Inspection
To observe the Replay Buffer retransmission sequence, add the following signals in GTKWave:

1. **Clock & Reset**:
   * `tb_top.clk`
   * `tb_top.rst_n`
2. **PIPE Receive Interface (Partner Injections)**:
   * `tb_top.pipe_rx_data_valid`
   * `tb_top.pipe_rx_data[31:0]` *(Observe `0x10000FFF` for Nak with seq 0xFFF)*
3. **Internal DLLP Engine Decoding**:
   * `tb_top.u_dut.nak_rcvd` *(Pulses high for 1 clock cycle upon Nak reception)*
   * `tb_top.u_dut.nak_seq[11:0]` *(Decoded sequence number requesting replay)*
4. **Replay Buffer Core State**:
   * `tb_top.u_dut.u_replay_buffer.state_q` *(`00` = S_NORMAL, `01` = S_REPLAY)*
   * `tb_top.u_dut.u_replay_buffer.replay_ptr_q[5:0]` *(Rewinds to commit pointer)*
   * `tb_top.u_dut.u_replay_buffer.occupancy_q[6:0]` *(Number of unacknowledged packets)*
5. **PIPE Transmit Interface (Subsystem Output)**:
   * `tb_top.pipe_tx_data_valid`
   * `tb_top.pipe_tx_data[31:0]` *(Observe `0x40000001` - Re-emitted MWr32 header)*

---

## 7. Compliance & Limitations

* **Implemented Spec Subset**: PCI Express Base Specification Rev 3.0 (x1 Gen 3 Data Link Layer & Transaction Layer).
* **Maximum Payload Size (MPS)**: 128 Bytes (32 DWs). Packets exceeding this ceiling are flagged and dropped.
* **Flow Control**: Single Virtual Channel (`VC0`) credit accounting for Posted, Non-Posted, and Completion streams.
* **Physical Layer**: Standard 32-bit PIPE interface abstraction (8.0 GT/s 128b/130b framing markers). PHY electrical analog blocks (CDR, equalization, and PLLs) are modeled at behavioral interface pins.
