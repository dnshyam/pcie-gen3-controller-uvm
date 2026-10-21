//=============================================================================
// File: pcie_pkg.sv
// Description: PCIe Gen 3 Subsystem Definitions, Enums, Structs and Parameters
// Standard: PCI Express Base Specification Revision 3.0
//=============================================================================

`ifndef PCIE_PKG_SV
`define PCIE_PKG_SV

package pcie_pkg;

  /* verilator lint_off UNUSEDPARAM */
  /* verilator lint_off UNUSEDSIGNAL */

  //---------------------------------------------------------------------------
  // Global Architectural Parameters
  //---------------------------------------------------------------------------
  localparam int MAX_PAYLOAD_BYTES      = 128;               // Max Payload Size (MPS): 128 Bytes
  localparam int MAX_PAYLOAD_DWORDS     = MAX_PAYLOAD_BYTES / 4; // 32 DWs
  localparam int MAX_PAYLOAD_BITS       = MAX_PAYLOAD_BYTES * 8; // 1024 bits

  localparam int FC_HDR_UNIT_DWORDS     = 4;                 // 1 Header Credit = 4 DWs
  localparam int FC_HDR_UNIT_BYTES      = FC_HDR_UNIT_DWORDS * 4; // 16 Bytes
  localparam int FC_DATA_UNIT_BYTES     = 16;                // 1 Data Credit = 16 Bytes (4 DWs)
  localparam int FC_DATA_UNIT_DWORDS    = FC_DATA_UNIT_BYTES / 4; // 4 DWs

  localparam int SEQ_NUM_WIDTH          = 12;                // 12-bit sequence number
  localparam int LCRC_WIDTH             = 32;                // 32-bit LCRC for TLPs
  localparam int DLLP_CRC_WIDTH         = 16;                // 16-bit CRC for DLLPs

  localparam int FC_HDR_CREDIT_WIDTH    = 8;                 // 8-bit Header Credit Counter
  localparam int FC_DATA_CREDIT_WIDTH   = 12;                // 12-bit Data Credit Counter

  //---------------------------------------------------------------------------
  // TLP Format and Type Encodings (PCIe 3.0 Spec)
  //---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    TLP_FMT_3DW_NODATA = 3'b000,
    TLP_FMT_4DW_NODATA = 3'b001,
    TLP_FMT_3DW_DATA   = 3'b010,
    TLP_FMT_4DW_DATA   = 3'b011,
    TLP_FMT_PREFIX     = 3'b100
  } tlp_fmt_e;

  typedef enum logic [4:0] {
    TLP_TYPE_MEM_REQ    = 5'b00000, // Memory Read or Write
    TLP_TYPE_MEM_REQ_LK = 5'b00001, // Memory Read Lock
    TLP_TYPE_IO_REQ     = 5'b00010, // I/O Read or Write
    TLP_TYPE_CFG0       = 5'b00100, // Configuration Type 0
    TLP_TYPE_CFG1       = 5'b00101, // Configuration Type 1
    TLP_TYPE_CPL        = 5'b01010, // Completion without Data
    TLP_TYPE_CPL_LK     = 5'b01011  // Completion Locked
  } tlp_type_e;

  // Composite 8-bit {Fmt, Type} Packet Encoding
  typedef enum logic [7:0] {
    TLP_MRD32 = 8'b000_00000, // 3DW Memory Read Request
    TLP_MRD64 = 8'b001_00000, // 4DW Memory Read Request
    TLP_MWR32 = 8'b010_00000, // 3DW Memory Write Request
    TLP_MWR64 = 8'b011_00000, // 4DW Memory Write Request
    TLP_CPL   = 8'b000_01010, // Completion without Data
    TLP_CPLD  = 8'b010_01010  // Completion with Data
  } tlp_pkt_type_e;

  // Completion Status
  typedef enum logic [2:0] {
    CPL_STATUS_SC  = 3'b000, // Successful Completion
    CPL_STATUS_UR  = 3'b001, // Unsupported Request
    CPL_STATUS_CRS = 3'b010, // Configuration Request Retry Status
    CPL_STATUS_CA  = 3'b100  // Completer Abort
  } cpl_status_e;

  // Flow Control Traffic Class / Credit Types
  typedef enum logic [1:0] {
    FC_TYPE_POSTED     = 2'b00,
    FC_TYPE_NON_POSTED = 2'b01,
    FC_TYPE_CPL        = 2'b10
  } fc_type_e;

  //---------------------------------------------------------------------------
  // DLLP Encodings (PCIe 3.0 Spec Chapter 3)
  //---------------------------------------------------------------------------
  typedef enum logic [7:0] {
    DLLP_ACK         = 8'h00, // Ack DLLP
    DLLP_NAK         = 8'h10, // Nak DLLP
    DLLP_PM_ENTER_L1 = 8'h20, // PM Enter L1
    DLLP_PM_ENTER_L2 = 8'h21, // PM Enter L23
    DLLP_PM_REQ_ACK  = 8'h24, // PM Request Ack
    DLLP_INITFC1_P   = 8'h40, // InitFC1 Posted
    DLLP_INITFC1_NP  = 8'h50, // InitFC1 Non-Posted
    DLLP_INITFC1_CPL = 8'h60, // InitFC1 Completion
    DLLP_INITFC2_P   = 8'hC0, // InitFC2 Posted
    DLLP_INITFC2_NP  = 8'hD0, // InitFC2 Non-Posted
    DLLP_INITFC2_CPL = 8'hE0, // InitFC2 Completion
    DLLP_UPDATEFC_P  = 8'h80, // UpdateFC Posted
    DLLP_UPDATEFC_NP = 8'h90, // UpdateFC Non-Posted
    DLLP_UPDATEFC_CPL= 8'hA0  // UpdateFC Completion
  } dllp_type_e;

  //---------------------------------------------------------------------------
  // Status and Error Enums
  //---------------------------------------------------------------------------
  typedef enum logic [2:0] {
    DL_INACTIVE = 3'b000,
    DL_INIT     = 3'b001,
    DL_ACTIVE   = 3'b010
  } dl_state_e;

  typedef enum logic [1:0] {
    FC_INIT_STATE_IDLE  = 2'b00,
    FC_INIT_STATE_FC1   = 2'b01,
    FC_INIT_STATE_FC2   = 2'b10,
    FC_INIT_STATE_DONE  = 2'b11
  } fc_state_e;

  typedef enum logic [3:0] {
    ERR_NONE                 = 4'h0,
    ERR_LCRC                 = 4'h1,
    ERR_SEQ_NUM              = 4'h2,
    ERR_REPLAY_TIMEOUT       = 4'h3,
    ERR_REPLAY_NUM_ROLLOVER  = 4'h4,
    ERR_BAD_TLP              = 4'h5,
    ERR_MALFORMED_TLP        = 4'h6,
    ERR_FC_OVERFLOW          = 4'h7,
    ERR_UNSUPPORTED_REQ      = 4'h8,
    ERR_COMPLETER_ABORT      = 4'h9
  } pcie_err_e;

  // Link Speed / Rate
  typedef enum logic [1:0] {
    GEN1_2_5GT = 2'b00,
    GEN2_5_0GT = 2'b01,
    GEN3_8_0GT = 2'b10
  } pcie_rate_e;

  //---------------------------------------------------------------------------
  // Packed TLP Header Structs (Standard PCIe DW Representation)
  //---------------------------------------------------------------------------

  // Common Header DW0 (32 bits)
  typedef struct packed {
    logic [2:0] fmt;      // [31:29] Format
    logic [4:0] pkt_type; // [28:24] Type
    logic       rsvd0;    // [23]
    logic [2:0] tc;       // [22:20] Traffic Class
    logic       rsvd1;    // [19]
    logic       attr2;    // [18] Attribute bit 2 (ID-based ordering)
    logic       rsvd2;    // [17]
    logic       th;       // [16] TLP Processing Hints
    logic       td;       // [15] Digest / ECRC present
    logic       ep;       // [14] Poisoned TLP
    logic [1:0] attr1_0;  // [13:12] Attributes [1:0]
    logic [1:0] at;       // [11:10] Address Translation
    logic [9:0] length;   // [9:0] Length in DWs (0 means 1024 DWs)
  } tlp_dw0_s;

  // Request Header DW1 (32 bits) - For MRd, MWr
  typedef struct packed {
    logic [15:0] requester_id; // [31:16] Bus[7:0], Dev[4:0], Fn[2:0]
    logic [7:0]  tag;          // [15:8]
    logic [3:0]  last_be;      // [7:4] Last DW Byte Enable
    logic [3:0]  first_be;     // [3:0] First DW Byte Enable
  } tlp_req_dw1_s;

  // Completion Header DW1 (32 bits) - For Cpl, CplD
  typedef struct packed {
    logic [15:0] completer_id; // [31:16] Completer ID
    logic [2:0]  cpl_status;   // [15:13] Completion Status
    logic        bcm;          // [12] Byte Count Modified
    logic [11:0] byte_count;   // [11:0] Remaining byte count
  } tlp_cpl_dw1_s;

  // Completion Header DW2 (32 bits) - For Cpl, CplD
  typedef struct packed {
    logic [15:0] requester_id; // [31:16] Original Requester ID
    logic [7:0]  tag;          // [15:8] Tag matching request
    logic        rsvd;         // [7]
    logic [6:0]  lower_addr;   // [6:0] Lower byte address
  } tlp_cpl_dw2_s;

  // 3DW Memory Header (96 bits)
  typedef struct packed {
    tlp_dw0_s     dw0;
    tlp_req_dw1_s dw1;
    logic [31:2]  address;
    logic [1:0]   ph;          // Processing hint / reserved
  } tlp_hdr_3dw_s;

  // 4DW Memory Header (128 bits)
  typedef struct packed {
    tlp_dw0_s     dw0;
    tlp_req_dw1_s dw1;
    logic [31:0]  addr_hi;
    logic [31:2]  addr_lo;
    logic [1:0]   ph;
  } tlp_hdr_4dw_s;

  // 3DW Completion Header (96 bits)
  typedef struct packed {
    tlp_dw0_s     dw0;
    tlp_cpl_dw1_s dw1;
    tlp_cpl_dw2_s dw2;
  } tlp_cpl_hdr_s;

  //---------------------------------------------------------------------------
  // Packed DLLP Structs (48 bits: 32 bits Payload + 16 bits 16-bit CRC)
  //---------------------------------------------------------------------------

  // Flow Control DLLP (InitFC1, InitFC2, UpdateFC) - 48 bits total
  // Byte 0: Type[7:0] ({Type[7:4], Rsvd[3], VC[2:0]})
  // Byte 1-3 (24b): HdrScale[1:0], HdrFC[7:0], DataScale[1:0], DataFC[11:0]
  // Byte 4-5 (16b): CRC16[15:0]
  typedef struct packed {
    logic [7:0]  dllp_type;   // [47:40] DLLP Type & VC
    logic [1:0]  hdr_scale;   // [39:38] Header Credit Scale
    logic [7:0]  hdr_fc;      // [37:30] Header Credits
    logic [1:0]  data_scale;  // [29:28] Data Credit Scale
    logic [11:0] data_fc;     // [27:16] Data Credits
    logic [15:0] crc16;       // [15:0] 16-bit CRC
  } dllp_fc_s;

  // Ack / Nak DLLP - 48 bits total
  typedef struct packed {
    logic [7:0]  dllp_type;   // [47:40] DLLP_ACK / DLLP_NAK
    logic [7:0]  rsvd0;       // [39:32]
    logic [3:0]  rsvd1;       // [31:28]
    logic [11:0] seq_num;     // [27:16] Ack/Nak Sequence Number
    logic [15:0] crc16;       // [15:0] 16-bit CRC
  } dllp_ack_nak_s;

  // Universal 48-bit DLLP Struct
  typedef union packed {
    dllp_fc_s      fc;
    dllp_ack_nak_s ack_nak;
    logic [47:0]   raw;
  } dllp_pkt_u;

  //---------------------------------------------------------------------------
  // Unpacked High-Level TLP Representation
  // (Utilized for Internal Subsystem Queues and pyuvm Verification)
  //---------------------------------------------------------------------------
  typedef struct packed {
    tlp_pkt_type_e            pkt_type;
    logic [2:0]               tc;
    logic                     td;
    logic                     ep;
    logic [1:0]               attr;
    logic [1:0]               at;
    logic [9:0]               length;       // Length in DWs
    logic [15:0]              requester_id;
    logic [15:0]              completer_id;
    logic [7:0]               tag;
    logic [3:0]               first_be;
    logic [3:0]               last_be;
    logic [63:0]              address;
    cpl_status_e              cpl_status;
    logic [11:0]              byte_count;
    logic [6:0]               lower_addr;
    logic [MAX_PAYLOAD_BITS-1:0] payload;   // Up to 128 Bytes
    logic [SEQ_NUM_WIDTH-1:0] seq_num;
    logic                     has_lcrc;
    logic [LCRC_WIDTH-1:0]    lcrc;
  } tlp_unpacked_s;

  // Credit Tracking Struct
  typedef struct packed {
    logic [FC_HDR_CREDIT_WIDTH-1:0]  hdr_credits;
    logic [FC_DATA_CREDIT_WIDTH-1:0] data_credits;
  } fc_credit_s;

  // DLLP CRC-16 Calculation Functions (PCIe 3.0 Poly = 16'h1021)
  function automatic logic [15:0] crc16_8b(
    input logic [7:0]  data_byte,
    input logic [15:0] current_crc
  );
    logic [15:0] c;
    logic        fb;
    c = current_crc;
    for (int i = 0; i < 8; i++) begin
      fb = data_byte[i] ^ c[15];
      c  = {c[14:0], 1'b0};
      if (fb) begin
        c = c ^ 16'h1021;
      end
    end
    return c;
  endfunction

  function automatic logic [15:0] calc_dllp_crc(input logic [31:0] payload);
    logic [15:0] crc;
    crc = 16'hFFFF; // Initial Seed
    crc = crc16_8b(payload[7:0],   crc);  // Byte 0
    crc = crc16_8b(payload[15:8],  crc);  // Byte 1
    crc = crc16_8b(payload[23:16], crc);  // Byte 2
    crc = crc16_8b(payload[31:24], crc);  // Byte 3
    return ~crc;                          // 1's complement inversion
  endfunction

endpackage : pcie_pkg

`endif // PCIE_PKG_SV
