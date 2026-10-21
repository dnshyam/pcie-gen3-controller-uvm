# Flow Control & Credit Tracking Architecture

## 1. Principle of PCIe Flow Control
PCI Express employs credit-based flow control on a point-to-point link. Before transmitting any TLP across the link, the transmitter MUST verify that the receiving partner has sufficient buffer credits to accept the packet.

Credits are divided into three independent traffic types:
1. **Posted (P)**: Memory Writes (`MWr`), Messages.
2. **Non-Posted (NP)**: Memory Reads (`MRd`), Configuration Reads/Writes, I/O Reads/Writes.
3. **Completions (CPL)**: Completions with or without Data (`Cpl`, `CplD`).

Within each type, credits are tracked separately for:
- **Header Credits**: 1 Header Credit = 1 TLP Header (up to 4 DWs).
- **Data Credits**: 1 Data Credit = 16 Bytes (4 DWs).

---

## 2. Credit Counter Bit Widths and Arithmetic
- **Header Credits**: 8 bits ($[7:0]$), range 0 to 255 credits.
- **Data Credits**: 12 bits ($[11:0]$), range 0 to 4095 credits.
- **Modulo Comparison**:
  Credit tracking relies on modulo-$2^N$ unsigned modular arithmetic:
  $$\text{Credits Consumed} = (\text{CREDITS\_ALLOCATED} - \text{CREDITS\_RECEIVED}) \pmod{2^N}$$
  A transmission is permitted if:
  $$(\text{CREDITS\_ALLOCATED} - \text{CREDITS\_CONSUMED} - \text{TLP\_REQUIRED}) \le 2^{N-1}$$

---

## 3. Flow Control Initialization State Machine (FC_INIT)

```
        +-----------------------------------------+
        |            FC_INIT_STATE_IDLE           |
        +-----------------------------------------+
                             | Link Up (DL_ACTIVE)
                             v
        +-----------------------------------------+
        |            FC_INIT_STATE_FC1            |
        | - Transmit InitFC1-P, InitFC1-NP, Cpl   |
        | - Wait for partner's InitFC1 packets    |
        +-----------------------------------------+
                             | Received InitFC1 for P, NP, Cpl
                             v
        +-----------------------------------------+
        |            FC_INIT_STATE_FC2            |
        | - Transmit InitFC2-P, InitFC2-NP, Cpl   |
        | - Wait for partner's InitFC2 packets    |
        +-----------------------------------------+
                             | Received InitFC2 for P, NP, Cpl
                             v
        +-----------------------------------------+
        |            FC_INIT_STATE_DONE           |
        | - Flow control active                   |
        | - Periodic UpdateFC DLLPs dispatched    |
        +-----------------------------------------+
```

---

## 4. Hardware Implementation Strategy
- **Credit Limit Register (`CREDIT_LIMIT`)**: Stores credits advertised by remote partner via `InitFC1/2` and `UpdateFC`.
- **Credit Consumed Counter (`CREDIT_CONSUMED`)**: Incremented upon each local TLP transmission.
- **Credit Return Engine**: Monitors receiver FIFO drains and emits `UpdateFC` DLLPs whenever the freed credit delta exceeds the threshold or every $T_{\text{UpdateFC}}$ time interval.
