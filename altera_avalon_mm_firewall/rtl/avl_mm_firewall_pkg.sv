`timescale 1ns/1ps

// =============================================================================
// avl_mm_firewall_pkg.sv
//
// Definitions shared by avl_mm_firewall_top.sv (which produces verdicts) and
// avl_mm_firewall_regs.sv (which reports them through FAULT_INFO.TYPE).
//
// This package exists because the two used to hold parallel copies of the same
// numbering - a DEC_* set in the datapath and a FAULT_* set in the register
// block, kept equal by a comment. That is exactly the kind of agreement that
// survives review and then quietly breaks the first time someone inserts a
// code in the middle. One definition, imported by both.
//
// COMPILE THIS FILE FIRST. It is listed first in avl_mm_firewall_hw.tcl and in
// both simulation flows for that reason.
// =============================================================================

package avl_mm_firewall_pkg;

    // -------------------------------------------------------------------
    // Avalon-MM response encoding (Avalon Interface Specifications, the
    // `response` signal). Valid with readdatavalid on reads and with
    // writeresponsevalid on writes.
    // -------------------------------------------------------------------
    // 2'b01 is RESERVED in the specification and is deliberately not given a
    // name here - naming it invites someone to drive it.
    localparam logic [1:0] RESP_OKAY        = 2'b00;
    localparam logic [1:0] RESP_SLAVEERROR  = 2'b10;
    localparam logic [1:0] RESP_DECODEERROR = 2'b11;

    // -------------------------------------------------------------------
    // One code space, used both as the datapath's per-transaction verdict and
    // as the value software reads back in FAULT_INFO[3:1].
    //
    // FW_ALLOW and FW_BLOCKED never reach FAULT_INFO: the first is not a
    // fault, and the second is a rejection that happens *because* of a fault
    // already latched - re-latching on every subsequent rejected access would
    // overwrite the FAULT_ADDR that actually diagnoses the problem.
    //
    // Enum-typed rather than localparams so Questa names the verdicts in its
    // coverage report instead of showing bare 3'b encodings.
    // -------------------------------------------------------------------
    typedef enum logic [2:0] {
        FW_ALLOW        = 3'd0,  // forward it
        FW_ADDR         = 3'd1,  // no valid rule contains the address
        FW_PERM         = 3'd2,  // rule matched, wrong direction
        FW_TIMEOUT      = 3'd3,  // downstream stopped making progress
        FW_BURST_RANGE  = 3'd4,  // burst extends beyond the matched window
        FW_BURST_DENIED = 3'd5,  // rule matched but forbids bursts
        FW_BLOCKED      = 3'd6   // isolated, or downstream known broken
    } fw_code_e;

    // Which STATUS bit a verdict sets. FW_BURST_RANGE and FW_BURST_DENIED
    // share bit 3 and stay distinguishable through FAULT_INFO.TYPE.
    //   FW_ADDR -> STATUS[0]   FW_PERM        -> STATUS[1]
    //   FW_TIMEOUT -> STATUS[2]  FW_BURST_*   -> STATUS[3]

    // A range violation is a decode error - the transaction reaches addresses
    // that are, as far as this window is concerned, not there. A permission or
    // burst-capability refusal is a slave error - the address is real, the
    // access is not allowed.
    function automatic logic [1:0] fw_resp(input fw_code_e c);
        if (c == FW_ADDR || c == FW_BURST_RANGE) return RESP_DECODEERROR;
        return RESP_SLAVEERROR;
    endfunction

    // -------------------------------------------------------------------
    // RULE_PERM[3:0]. Declared MSB-first so the packed layout is exactly
    // {BURST_ALLOW, VALID, WRITE_ALLOW, READ_ALLOW}.
    //
    // burst_en is per-window rather than global because "this peripheral
    // cannot handle bursts" is a property of the peripheral, and a system
    // usually has both kinds behind one firewall.
    // -------------------------------------------------------------------
    typedef struct packed {
        logic burst_en;
        logic valid;
        logic wr_en;
        logic rd_en;
    } rule_perm_t;

endpackage
