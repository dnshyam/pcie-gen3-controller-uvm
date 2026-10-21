# PCIe Gen 3 Packet Formats & Encodings

## 1. Transaction Layer Packet (TLP) Format

### Common Header DW0 (32 bits)
```
 31 30 29 28 27 26 25 24 23 22 21 20 19 18 17 16 15 14 13 12 11 10 9 8 7 6 5 4 3 2 1 0
+--------+--------------+---+--------+---+--+--+--+--+--+-----+-----+-------------------+
|  Fmt   |     Type     | R |   TC   | R |A2| R|TH|TD|EP| Attr| AT  |      Length       |
| [2:0]  |    [4:0]     |   | [2:0]  |   |  |  |  |  |  |[1:0]|[1:0]|       [9:0]       |
+--------+--------------+---+--------+---+--+--+--+--+--+-----+-----+-------------------+
```

- **Fmt[2:0]**:
  - `3'b000`: 3DW header, no data (MRd32)
  - `3'b001`: 4DW header, no data (MRd64)
  - `3'b010`: 3DW header, with data (MWr32, CplD)
  - `3'b011`: 4DW header, with data (MWr64)
- **Length[9:0]**: In double words (DW). `10'h001` = 1 DW (4 Bytes); `10'h000` = 1024 DW (4096 Bytes).
- **Max Payload Size**: 128 Bytes (32 DWs).

### 3DW Memory Request Header (MRd32 / MWr32)
- **DW0**: Format (`000b` / `010b`), Type (`00000b`), TC, Length.
- **DW1**: `Requester ID [31:16]`, `Tag [15:8]`, `Last DW BE [7:4]`, `First DW BE [3:0]`.
- **DW2**: `Address[31:2]`, `PH / Reserved [1:0]`.

### 4DW Memory Request Header (MRd64 / MWr64)
- **DW0**: Format (`001b` / `011b`), Type (`00000b`), TC, Length.
- **DW1**: `Requester ID [31:16]`, `Tag [15:8]`, `Last DW BE [7:4]`, `First DW BE [3:0]`.
- **DW2**: `Address [63:32]`.
- **DW3**: `Address [31:2]`, `PH / Reserved [1:0]`.

### Completion Header (Cpl / CplD)
- **DW0**: Format (`000b` / `010b`), Type (`01010b`).
- **DW1**: `Completer ID [31:16]`, `Cpl Status [15:13]`, `BCM [12]`, `Byte Count [11:0]`.
- **DW2**: `Requester ID [31:16]`, `Tag [15:8]`, `Rsvd [7]`, `Lower Address [6:0]`.

---

## 2. Data Link Layer Packet (DLLP) Format

All DLLPs are 6 bytes (48 bits) in length: 4 bytes payload + 2 bytes 16-bit CRC.

### Flow Control DLLP (InitFC1, InitFC2, UpdateFC)
```
Byte 0 (bits 47:40): DLLP Type [7:0] ({Type[7:4], Rsvd[3], VC[2:0]})
Byte 1 (bits 39:32): HdrScale [1:0] (bits 39:38), HdrFC [7:2] (bits 37:32)
Byte 2 (bits 31:24): HdrFC [1:0] (bits 31:30), DataScale [1:0] (bits 29:28), DataFC [11:8] (bits 27:24)
Byte 3 (bits 23:16): DataFC [7:0] (bits 23:16)
Byte 4-5 (bits 15:0): 16-bit CRC
```

### Ack / Nak DLLP
```
Byte 0 (bits 47:40): 0x00 (Ack) / 0x10 (Nak)
Byte 1 (bits 39:32): Reserved [7:0]
Byte 2 (bits 31:24): Reserved [3:0], Ack/Nak Seq Num [11:8]
Byte 3 (bits 23:16): Ack/Nak Seq Num [7:0]
Byte 4-5 (bits 15:0): 16-bit CRC
```
