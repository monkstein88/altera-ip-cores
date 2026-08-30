`timescale 1ns/1ps
// =============================================================================
// sdram_device_model.sv
//
// A behavioural SDR SDRAM device with ONE OPEN ROW PER BANK.
//
// WHY THIS REPLACES INTEL'S GENERATED MODEL
// -----------------------------------------
// Intel's altera_sdram_partner_module model keeps a single row register for
// the whole device:
//
//     if (CODE == 24'h414354)                    // ACTIVATE
//         addr_crb <= {ba[1], a, ba[0]};         // one register, not per bank
//     assign test_addr = {addr_crb, addr_col};
//
// Every ACTIVATE overwrites it regardless of bank, so a column command is
// serviced using whichever row was activated LAST, on whichever bank. Against
// a controller that keeps one row open per bank, reads and writes silently
// land in the wrong place.
//
// That is invisible with Intel's core, which only ever has one row
// open, and it is exactly the wrong bug to have in the reference model when the
// change being measured is per-bank row tracking: the model reports data
// corruption for legal command streams. A real device has a row register per
// bank; this model has one too.
//
// It also removes Quartus from the loop. Only Intel's core needs generating
// now, so measuring the custom core needs no Quartus installation.
//
// WHAT IT DOES AND DOES NOT MODEL
// -------------------------------
// Models: per-bank ACTIVATE/PRECHARGE state, the CAS-latency read pipeline,
// DQM write masking and read masking, mode-register CAS latency, burst
// length 1, and refusal to service a column command to a closed bank.
//
// Does NOT model: timing (tRCD, tRP, tRC, tRAS, tRRD, tWR), the refresh
// interval, or retention. That is deliberate and unchanged from Intel's model
// - sdram_timing_check.sv is what covers timing, and keeping the two concerns
// in separate modules is why a fault in one cannot excuse a fault in the other.
// =============================================================================

module sdram_device_model #(
    parameter int DATA_BITS = 16,
    parameter int ROW_BITS  = 13,
    parameter int COL_BITS  = 10,
    parameter int BANK_BITS = 2,
    parameter int SA_BITS   = 13,
    parameter int CAS_MAX   = 7,
    // Contents of a location never written. Reads of unwritten memory are a
    // benchmark bug (a read pattern with no priming pass), so this is a value
    // the integrity check will not accidentally match.
    parameter logic [15:0] UNWRITTEN = 16'hDEAD
) (
    input  logic                    clk,
    input  logic [SA_BITS-1:0]      zs_addr,
    input  logic [BANK_BITS-1:0]    zs_ba,
    input  logic                    zs_cas_n,
    input  logic                    zs_cke,
    input  logic                    zs_cs_n,
    inout  wire  [DATA_BITS-1:0]    zs_dq,
    input  logic [DATA_BITS/8-1:0]  zs_dqm,
    input  logic                    zs_ras_n,
    input  logic                    zs_we_n
);

    localparam int BANKS = 1 << BANK_BITS;
    localparam int DQM_W = DATA_BITS / 8;
    localparam int KEY_W = BANK_BITS + ROW_BITS + COL_BITS;

    // Sparse storage: the DE10-Lite part is 32M x 16, and a benchmark touches
    // a few thousand locations of it.
    logic [DATA_BITS-1:0] mem [logic [KEY_W-1:0]];

    // ---- per-bank row state.  THE POINT OF THIS MODULE. -------------------
    logic [ROW_BITS-1:0] open_row [BANKS];
    logic                row_act  [BANKS];

    logic [2:0] cas_lat = 3'd3;          // overwritten by LOAD MODE REGISTER

    // ---- command decode ----------------------------------------------------
    logic sel, cmd_act, cmd_rd, cmd_wr, cmd_pre, cmd_ref, cmd_mrs, cmd_pre_all;
    assign sel         = zs_cke && !zs_cs_n;
    assign cmd_act     = sel && !zs_ras_n &&  zs_cas_n &&  zs_we_n;
    assign cmd_rd      = sel &&  zs_ras_n && !zs_cas_n &&  zs_we_n;
    assign cmd_wr      = sel &&  zs_ras_n && !zs_cas_n && !zs_we_n;
    assign cmd_pre     = sel && !zs_ras_n &&  zs_cas_n && !zs_we_n;
    assign cmd_ref     = sel && !zs_ras_n && !zs_cas_n &&  zs_we_n;
    assign cmd_mrs     = sel && !zs_ras_n && !zs_cas_n && !zs_we_n;
    assign cmd_pre_all = cmd_pre && zs_addr[10];

    // Column bit 10 steps over A10, which is the auto-precharge flag.
    logic [COL_BITS-1:0] col;
    always_comb begin
        col = '0;
        for (int i = 0; i < COL_BITS; i++)
            col[i] = zs_addr[(i < 10) ? i : i + 1];
    end

    function automatic logic [KEY_W-1:0] key(input logic [BANK_BITS-1:0] b,
                                             input logic [ROW_BITS-1:0]  r,
                                             input logic [COL_BITS-1:0]  c);
        return {b, r, c};
    endfunction

    int unsigned bad_access;             // column commands to a closed bank

    // ---- read pipeline -----------------------------------------------------
    logic [DATA_BITS-1:0] rd_data [CAS_MAX];
    logic [DQM_W-1:0]     rd_mask [CAS_MAX];
    logic                 rd_vld  [CAS_MAX];

    logic [DATA_BITS-1:0] fetch;
    logic [KEY_W-1:0]     k;

    initial begin
        for (int b = 0; b < BANKS; b++) begin
            row_act[b]  = 1'b0;
            open_row[b] = '0;
        end
        for (int i = 0; i < CAS_MAX; i++) begin
            rd_vld[i]  = 1'b0;
            rd_data[i] = '0;
            rd_mask[i] = '1;
        end
        bad_access = 0;
    end

    always_ff @(posedge clk) if (zs_cke) begin
        // ---- row commands ----
        if (cmd_mrs) cas_lat <= zs_addr[6:4];

        if (cmd_act) begin
            open_row[zs_ba] <= zs_addr[ROW_BITS-1:0];
            row_act[zs_ba]  <= 1'b1;
        end

        if (cmd_pre)
            for (int b = 0; b < BANKS; b++)
                if (cmd_pre_all || (BANK_BITS'(b) == zs_ba)) row_act[b] <= 1'b0;

        // ---- column commands ----
        if (cmd_wr) begin
            if (!row_act[zs_ba]) begin
                bad_access++;
                $display("  MODEL ERROR  WRITE to bank %0d with no open row (t=%0t)",
                         zs_ba, $time);
            end else begin
                k = key(zs_ba, open_row[zs_ba], col);
                fetch = mem.exists(k) ? mem[k] : UNWRITTEN;
                for (int i = 0; i < DQM_W; i++)
                    if (!zs_dqm[i]) fetch[i*8 +: 8] = zs_dq[i*8 +: 8];
                mem[k] = fetch;
            end
        end

        // ---- read pipeline advances every cycle ----
        for (int i = CAS_MAX-1; i > 0; i--) begin
            rd_vld[i]  <= rd_vld[i-1];
            rd_data[i] <= rd_data[i-1];
            rd_mask[i] <= rd_mask[i-1];
        end
        rd_vld[0]  <= cmd_rd;
        rd_mask[0] <= zs_dqm;
        if (cmd_rd) begin
            if (!row_act[zs_ba]) begin
                bad_access++;
                $display("  MODEL ERROR  READ from bank %0d with no open row (t=%0t)",
                         zs_ba, $time);
                rd_data[0] <= 'x;
            end else begin
                k = key(zs_ba, open_row[zs_ba], col);
                rd_data[0] <= mem.exists(k) ? mem[k] : UNWRITTEN;
            end
        end
    end

    // Data is driven for the one cycle ending CAS_LAT edges after the READ
    // command, so the controller captures it on that edge.
    logic                 drv;
    logic [DATA_BITS-1:0] drv_data;
    logic [DQM_W-1:0]     drv_mask;
    assign drv      = rd_vld [cas_lat - 3'd1];
    assign drv_data = rd_data[cas_lat - 3'd1];
    assign drv_mask = rd_mask[cas_lat - 3'd1];

    genvar g;
    generate
        for (g = 0; g < DQM_W; g++) begin : g_dq
            assign zs_dq[g*8 +: 8] = (drv && !drv_mask[g]) ? drv_data[g*8 +: 8]
                                                           : 8'bz;
        end
    endgenerate

endmodule
