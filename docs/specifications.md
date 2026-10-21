# PCIe Gen 3 Controller Subsystem Specification

## 1. Overview
This subsystem implements an open-source, synthesizable subset of the PCI Express Base Specification Revision 3.0, focusing on the **Transaction Layer (TL)** and **Data Link Layer (DLL)** paired with a standard **PIPE v4.3/v5.x** interface.

The design targets high-throughput, low-latency packet processing for ASIC and FPGA designs with full pyuvm/cocotb testbench verification in Verilator.

---

## 2. Subsystem Architecture

```
+-----------------------------------------------------------------+
|                       Application Layer                         |
|   (User Core / DMA Engine / AXI-S Packet Stream Interface)      |
+-----------------------------------------------------------------+
                                |  pcie_app_if
                                v
+-----------------------------------------------------------------+
|                      Transaction Layer (TL)                     |
|  - TLP Generator (MRd32/64, MWr32/64, Cpl, CplD)                |
|  - TLP Parser & Decoder                                         |
|  - Flow Control Credit Tracking (P, NP, CPL: Hdr & Data)       |
+-----------------------------------------------------------------+
                                |
                                v
+-----------------------------------------------------------------+
|                      Data Link Layer (DLL)                      |
|  - Sequence Number Generator & Checker (12-bit)                 |
|  - 32-bit LCRC Generator & Checker                              |
|  - Replay Buffer & Ack/Nak Transmission Engine                  |
|  - DLLP Engine (InitFC1, InitFC2, UpdateFC, Ack, Nak)           |
+-----------------------------------------------------------------+
                                |  pcie_pipe_if
                                v
+-----------------------------------------------------------------+
|                   Physical Layer (PHY / PIPE)                   |
|  - 32-bit / 64-bit Parallel PIPE interface (8.0 GT/s, Gen 3)   |
|  - 128b/130b Block Sync and Framing (Data/Ordered Set)          |
+-----------------------------------------------------------------+
```

---

## 3. Supported Features
- **PCIe Generation**: Gen 3 (8.0 GT/s).
- **Interface Width**: 32-bit @ 250 MHz (or 64-bit @ 125 MHz).
- **Maximum Payload Size (MPS)**: 128 Bytes (32 DWs).
- **Maximum Read Request Size (MRRS)**: Configurable up to 512 Bytes.
- **Transaction Types**:
  - `MRd32`, `MRd64` (Memory Read, 3DW / 4DW)
  - `MWr32`, `MWr64` (Memory Write, 3DW / 4DW)
  - `Cpl`, `CplD` (Completion without / with Data)
- **Data Link Layer Protocol**:
  - 12-bit Sequence numbering (`NEXT_TRANSMIT_SEQ`, `ACKD_SEQ`, `NEXT_RCV_SEQ`).
  - 32-bit LCRC polynomial ($0x04C11DB7$).
  - Circular replay buffer for unacknowledged TLPs.
  - Replay timer and Ack transmission timer.
  - DLLP generation: `Ack`, `Nak`, `InitFC1-P/NP/Cpl`, `InitFC2-P/NP/Cpl`, `UpdateFC-P/NP/Cpl`.
- **Credit Flow Control**:
  - Independent credit counters for Posted (`P`), Non-Posted (`NP`), and Completion (`CPL`).
  - Header credit unit: 4 DWs / 1 TLP header.
  - Data credit unit: 16 Bytes (4 DWs).
