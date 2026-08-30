`timescale 1ns/1ps
// =============================================================================
// sdram_traffic_gen.sv
//
// An Avalon-MM master that issues a chosen access pattern at full rate and
// measures how long the memory takes to absorb it.
//
// WHY THIS EXISTS
// ---------------
// "Faster" is not a claim you can make about a memory controller without a
// ruler. This is the ruler. It drives whichever controller is under test with
// identical, reproducible traffic and reports cycles and bytes, so two
// controllers can be compared on the same patterns rather than on adjectives.
//
// The patterns are chosen to separate effects that a single "sequential"
// benchmark blurs together:
//
//   SEQ_RD / SEQ_WR   one direction, ascending - the best case, and the one
//                     Intel's core already runs at 97% of the bus limit.
//   SEQ_RW            ascending but alternating direction. Isolates the cost
//                     of a read/write turnaround. Never previously measured.
//   ROW_RW            alternating direction inside ONE open row. Removes row
//                     changes entirely, so whatever remains IS the turnaround.
//   BANK_STRIDE       steps 2^COL_BITS words at a time. Under the part's
//                     address map that alternates bank AND advances the row
//                     every second access, so it is a row thrash across two
//                     banks - not the same-row bank walk this comment used to
//                     claim. Kept because it is a fair hard case, named for
//                     what it does.
//   BANK_ROT          the walk BANK_STRIDE was supposed to be: rotate through
//                     all four banks at ONE row, advancing the column every
//                     fourth access. A controller tracking one open row
//                     thrashes; one tracking a row per bank should not notice.
//   RANDOM            LFSR addresses - the pathological case.
//
// MEASUREMENT
// -----------
// The cycle counter starts when the first command is accepted and stops when
// the last one retires: for reads that is the last `rvalid`, for writes the
// last accepted command. Writes are posted, so a short write run measures the
// controller's input FIFO rather than the memory - use enough operations that
// the FIFO saturates and steady state dominates. N_OPS >= 4096 is plenty.
//
// Read data is checked against the same address-derived pattern the write
// phase wrote, so a controller that returns wrong data quickly cannot look
// good here. Errors are counted, not tolerated.
// =============================================================================

module sdram_traffic_gen #(
    parameter int ADDR_W = 25,   // Avalon word address width
    parameter int DATA_W = 16
) (
    input  logic                clk,
    input  logic                reset_n,

    // ---------------- control ----------------
    input  logic                start,        // one-cycle pulse
    input  logic [3:0]          pattern,
    input  logic                prime,        // force writes, same addresses
    input  logic [31:0]         n_ops,        // operations in this run
    input  logic [ADDR_W-1:0]   base_addr,

    output logic                busy,
    output logic                done,         // one-cycle pulse
    output logic [31:0]         cycles,       // first accept -> last retire
    output logic [31:0]         ops_issued,
    output logic [31:0]         ops_retired,
    output logic [31:0]         errors,

    // ---------------- Avalon-MM master (legacy az_/za_ naming, to match
    //                  the slave port Intel's core presents, so that either
    //                  controller can be driven) ------------------------
    output logic [ADDR_W-1:0]   az_addr,
    output logic [DATA_W/8-1:0] az_be_n,
    output logic                az_cs,
    output logic [DATA_W-1:0]   az_data,
    output logic                az_rd_n,
    output logic                az_wr_n,
    input  logic [DATA_W-1:0]   za_data,
    input  logic                za_valid,
    input  logic                za_waitrequest
);

    // ------------------------------------------------------------------
    // Pattern codes. Kept as localparams rather than an enum so the
    // testbench and any external script can pass a plain integer.
    // ------------------------------------------------------------------
    localparam logic [3:0]
        P_SEQ_WR     = 4'd0,   // ascending writes
        P_SEQ_RD     = 4'd1,   // ascending reads
        P_SEQ_RW     = 4'd2,   // ascending, alternating direction
        P_ROW_RW     = 4'd3,   // one row, alternating direction
        P_BANK_STRIDE= 4'd4,   // step 2^COL_BITS words: bank and row both move
        P_RANDOM     = 4'd5,   // LFSR addresses
        P_BANK_ROT   = 4'd6;   // rotate all banks at one row

    // ------------------------------------------------------------------
    // ADDRESS MAPPING OF THE PART UNDER TEST
    //
    // Intel's core maps the Avalon WORD address as
    //
    //     bank = { addr[24], addr[10] }    row = addr[23:11]    col = addr[9:0]
    //
    // Note the bank bits are SPLIT: bank[0] sits directly above the column,
    // so a purely ascending address alternates bank every 1024 words and
    // advances the row every 2048. That matters - it means even a perfectly
    // sequential stream changes bank constantly, which a one-open-row design
    // pays for and a per-bank design does not.
    //
    // These constants describe the part, not the controller, so a different
    // geometry only changes them.
    // ------------------------------------------------------------------
    localparam int ROW_BITS   = 13;
    localparam int COL_BITS   = 10;              // addr[9:0]
    localparam int BANK0_BIT  = COL_BITS;        // addr[10]  - the low bank bit
    localparam int BANK1_BIT  = COL_BITS + 1 + ROW_BITS;   // addr[24]

    localparam logic [ADDR_W-1:0] BANK_STEP = (1 << BANK0_BIT);
    localparam logic [ADDR_W-1:0] COL_MASK  = ADDR_W'((1 << COL_BITS) - 1);

    // ------------------------------------------------------------------
    // Sequencing
    //
    // Two independent walkers over the same address sequence: `iss` for the
    // commands going out, `ret` for the read data coming back. Because the
    // controller returns read data in order, the retire walker reproduces the
    // expected value without needing a queue.
    // ------------------------------------------------------------------
    logic [31:0]       iss_i, ret_i;
    logic [22:0]       lfsr, lfsr_ret;
    logic              running, counting;

    /* verilator lint_off UNUSEDSIGNAL */
    function automatic logic [ADDR_W-1:0] addr_of(input logic [31:0] i,
                                                  input logic [22:0] rnd);
        logic [ADDR_W-1:0] a;
        case (pattern)
            P_ROW_RW:      // stay inside one row: only the column moves
                return (base_addr & ~COL_MASK) | ADDR_W'(i[COL_BITS-1:0]);
            P_BANK_STRIDE: // 2^COL_BITS words per step: bank and row both move
                return base_addr + ADDR_W'(i) * BANK_STEP;
            P_BANK_ROT: begin
                // Hold the row, move only the two bank bits, and advance the
                // column once all four banks have been visited. This is the
                // access a per-bank controller should absorb at full rate and
                // a one-open-row controller cannot.
                a = base_addr & ~(COL_MASK | (ADDR_W'(1) << BANK0_BIT)
                                           | (ADDR_W'(1) << BANK1_BIT));
                a = a | (ADDR_W'(i[0]) << BANK0_BIT)
                      | (ADDR_W'(i[1]) << BANK1_BIT)
                      | (ADDR_W'(i >> 2) & COL_MASK);
                return a;
            end
            P_RANDOM:
                return ADDR_W'(rnd);
            default:       // ascending
                return base_addr + ADDR_W'(i);
        endcase
    endfunction

    // Direction for operation i. SEQ_RW and ROW_RW alternate; the rest are
    // a single direction throughout.
    function automatic logic is_read(input logic [31:0] i);
        if (prime) return 1'b0;               // priming pass writes everything
        case (pattern)
            P_SEQ_RD:                 return 1'b1;
            P_SEQ_RW, P_ROW_RW:       return i[0];
            P_BANK_STRIDE, P_RANDOM,
            P_BANK_ROT:               return 1'b1;   // read-only walks
            P_SEQ_WR:                 return 1'b0;
            default:                  return 1'b0;
        endcase
    endfunction

    // The data a given address should hold. Address-derived so the check
    // needs no storage, and non-trivial so a stuck bus does not pass.
    function automatic logic [DATA_W-1:0] data_of(input logic [ADDR_W-1:0] a);
        return DATA_W'({a[14:0], 1'b1} ^ 16'hA5C3);
    endfunction
    /* verilator lint_on UNUSEDSIGNAL */

    logic [ADDR_W-1:0] cur_addr;
    logic              cur_read;
    logic              accept;

    assign cur_addr = addr_of(iss_i, lfsr);
    assign cur_read = is_read(iss_i);

    // A command is accepted when it is presented and the slave is not
    // stalling. This is the only place `iss_i` advances.
    assign accept = az_cs && !za_waitrequest && running && (iss_i < n_ops);

    always_comb begin
        az_cs   = running && (iss_i < n_ops);
        az_rd_n = !(az_cs &&  cur_read);
        az_wr_n = !(az_cs && !cur_read);
        az_addr = cur_addr;
        az_data = data_of(cur_addr);
        az_be_n = '0;                     // all bytes, active low
    end

    // Reads retire on rvalid; writes retire as they are accepted, because the
    // controller posts them. Mixed patterns therefore retire on both.
    logic ret_is_read;
    assign ret_is_read = is_read(ret_i);

    logic [ADDR_W-1:0] exp_addr;
    assign exp_addr = addr_of(ret_i, lfsr_ret);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            running     <= 1'b0;
            counting    <= 1'b0;
            iss_i       <= '0;
            ret_i       <= '0;
            cycles      <= '0;
            ops_issued  <= '0;
            ops_retired <= '0;
            errors      <= '0;
            done        <= 1'b0;
            lfsr        <= 23'h1;
            lfsr_ret    <= 23'h1;
        end else begin
            done <= 1'b0;

            if (start && !running) begin
                running     <= 1'b1;
                counting    <= 1'b0;
                iss_i       <= '0;
                ret_i       <= '0;
                cycles      <= '0;
                ops_issued  <= '0;
                ops_retired <= '0;
                errors      <= '0;
                lfsr        <= 23'h1;
                lfsr_ret    <= 23'h1;
            end

            if (running) begin
                // The clock starts on the FIRST accepted command, so the
                // controller's power-on initialisation is not charged to it.
                if (accept) counting <= 1'b1;
                if (counting) cycles <= cycles + 1'b1;

                if (accept) begin
                    iss_i      <= iss_i + 1'b1;
                    ops_issued <= ops_issued + 1'b1;
                    if (pattern == P_RANDOM)
                        lfsr <= {lfsr[21:0], lfsr[22] ^ lfsr[17]};
                end

                // ---- retire ----
                if (za_valid && ret_is_read) begin
                    ret_i       <= ret_i + 1'b1;
                    ops_retired <= ops_retired + 1'b1;
                    if (za_data !== data_of(exp_addr))
                        errors <= errors + 1'b1;
                    if (pattern == P_RANDOM)
                        lfsr_ret <= {lfsr_ret[21:0], lfsr_ret[22] ^ lfsr_ret[17]};
                end else if (!ret_is_read && (ret_i < iss_i)) begin
                    // a posted write is retired once it has been accepted
                    ret_i       <= ret_i + 1'b1;
                    ops_retired <= ops_retired + 1'b1;
                    if (pattern == P_RANDOM)
                        lfsr_ret <= {lfsr_ret[21:0], lfsr_ret[22] ^ lfsr_ret[17]};
                end

                if (ops_retired == n_ops) begin
                    running  <= 1'b0;
                    counting <= 1'b0;
                    done     <= 1'b1;
                end
            end
        end
    end

    assign busy = running;

endmodule
