`timescale 1ns/1ps

// =============================================================================
// spi_card_model.sv
//
// A behavioural SD card in SPI mode. This is the thing every other testbench in
// the core is measured against, so it is written to the specification rather
// than to the DUT: if the two disagree, the model is the one holding the
// specification's position.
//
// Implements, per the SD Physical Layer Simplified Specification v4.10 ch. 7:
//
//   commands   CMD0 CMD8 CMD9 CMD10 CMD12 CMD13 CMD16 CMD17 CMD18
//              CMD24 CMD25 CMD55 CMD58 CMD59, ACMD41
//   responses  R1, R1b (with busy), R2, R3, R7
//   tokens     0xFE start, 0xFC multi-write start, 0xFD stop tran,
//              data response xxx0sss1, data error token 0000xxxx
//   CRC        CRC7 on commands (checked), CRC16 on data (checked and generated)
//   timing     N_CR of 0-8 byte-times, busy on MISO after a write
//   capacity   SDSC byte addressing and SDHC/SDXC block addressing
//   power-up   removable: >=74 clocks with CS high before it listens
//              (§6.4.1.1), SD mode until CMD0 selects SPI (§7.2.1), and
//              only the identification commands while in idle state
//
// -----------------------------------------------------------------------------
// IT MUST BE ABLE TO MISBEHAVE
// -----------------------------------------------------------------------------
// A card model that only ever works correctly proves that the DUT handles the
// happy path, which is the part that was never in doubt. The `inj_*` inputs
// make it produce, on demand: no response at all, a response with the CRC error
// or illegal command bit set, a read that returns a data error token instead of
// a block, a block whose CRC16 is wrong, a write rejected with a CRC or write
// error token, and busy that outlasts any timeout.
//
// The truncated-response behaviour of §7.3.2 is NOT an injected fault - it is
// modelled unconditionally, because it is what a real v1.x card does to CMD8:
// when R1 carries Illegal Command or Command CRC Error, the 32-bit trailer of
// an R3 or R7 is never sent. A DUT that reads it anyway desynchronises, and
// this model is what catches that.
//
// -----------------------------------------------------------------------------
// TIMING
// -----------------------------------------------------------------------------
// SPI mode 0 from the card's side: MOSI is sampled on the rising edge of
// sd_clk, MISO changes on the falling edge. MISO is driven combinationally from
// a registered byte and bit index so it is valid before the first rising edge,
// which CPHA=0 requires and which a negedge-only driver would get wrong for
// exactly one bit per transaction.
// =============================================================================

module spi_card_model #(
    parameter bit          HIGH_CAPACITY   = 1'b1,   // SDHC: block addressing
    parameter int unsigned NCR_BYTES       = 2,      // response latency, 0..8
    parameter bit          TRACE           = 1'b0,   // log every command handled
    // ACMD41 polls answered "still initialising" before the card reports
    // ready. A real card takes tens to hundreds; one keeps the RTL suites quick,
    // and the driver harness raises it so the driver's poll loop really loops.
    parameter int unsigned ACMD41_POLLS    = 1,
    // Clocks with CS high the card needs after power-up before it will listen.
    // §6.4.1.1 requires at least 74 of the host, and a card is entitled to
    // ignore everything until it has had them.
    parameter int unsigned POWER_UP_CLOCKS = 74,
    // Enforce the initialisation sequence at all: the power-up clocks, CMD0 to
    // leave SD mode, and ACMD41 before anything but identification. On for
    // every suite that verifies behaviour. Off only for the waveform capture,
    // which records the CONTROLLER's timing and sends CMD17 straight after
    // CMD0 to keep the figures short.
    parameter bit          ENFORCE_INIT    = 1'b1,
    // CID serial number, so two cards in one test can be told apart.
    parameter logic [31:0] CID_SERIAL      = 32'hDEAD_BEEF
) (
    input  logic sd_clk,
    input  logic sd_cs_n,
    input  logic sd_mosi,
    output logic sd_miso,

    // ---- the socket ---------------------------------------------------------
    // Low: no card. The line floats to its pull-up and nothing is decoded.
    // Removal is a power cycle - protocol state is lost and the next insertion
    // starts again from SD mode with no power-up clocks counted - but the
    // memory is flash, and survives it.
    input  logic inserted,

    // ---- fault injection ---------------------------------------------------
    input  logic inj_no_response,     // swallow the next command entirely
    input  logic inj_r1_illegal,      // set Illegal Command in the next R1
    input  logic inj_r1_crc,          // set Com CRC Error in the next R1
    input  logic inj_read_err_token,  // data error token instead of a block
    input  logic inj_bad_data_crc,    // corrupt the CRC16 of the next read block
    input  logic inj_write_crc_err,   // reject the next written block, CRC
    input  logic inj_write_err,       // reject the next written block, write error
    input  logic inj_busy_forever,    // never release busy

    // ---- observation -------------------------------------------------------
    output int unsigned cmds_seen,
    output int unsigned blocks_read,
    output int unsigned blocks_written,
    output logic [5:0]  last_cmd,
    output logic        last_cmd_crc_ok,
    // Incremented every time an inj_* input actually changes what the card
    // does, so a test can release a fault after exactly one use - and can tell
    // an injection that bit from one that was never consulted.
    output int unsigned faults_applied
);

    // -------------------------------------------------------------------------
    // Card state
    // -------------------------------------------------------------------------
    logic [7:0]  card_mem [int unsigned];   // sparse, byte addressed
    logic        is_idle;                   // in_idle_state, cleared by ACMD41
    logic        acmd_next;                 // CMD55 seen, next command is ACMD
    logic        crc_on;                    // CMD59
    logic [31:0] block_len;
    logic        spi_mode;                  // CMD0 with CS low seen since power-up
    int unsigned pwr_clocks;                // CS-high clocks since power-up
    int unsigned acmd41_polls;              // ACMD41s answered since CMD0

    // -------------------------------------------------------------------------
    // Byte-level plumbing
    // -------------------------------------------------------------------------
    logic [7:0] tx_byte;
    logic [2:0] tx_bit;
    logic [7:0] rx_sr;
    logic [2:0] rx_bit;

    logic [7:0] tx_q [$];      // bytes queued to send
    logic [7:0] cmd_buf [$];   // command bytes being collected

    // Busy is modelled as a byte-time count rather than a queue entry, because
    // it is unbounded in principle and the host must tolerate any length.
    int unsigned busy_bytes;

    // Response latency in byte-times, N_CR. Starts at the NCR_BYTES parameter
    // and is settable, so one card can be taken to both ends of the range the
    // specification allows - and one byte past it - in a single run.
    int unsigned ncr_bytes = NCR_BYTES;

    // How long the card holds busy after accepting a written block - its
    // internal programming time, §7.2.4, in byte-times.
    //
    // Settable rather than fixed, and defaulting to what it always was, so
    // nothing in the existing regression shifts. A real card takes 1-4 ms per
    // block, which at 25 MHz SPI is hundreds of byte-times; four is a token
    // value that keeps the functional tests quick and tells you nothing about
    // what the write path costs. set_prog_bytes() is for the one test that
    // actually wants to know.
    int unsigned prog_bytes = 4;

    always_comb sd_miso = (sd_cs_n || !inserted) ? 1'b1 : tx_byte[tx_bit];

    // -------------------------------------------------------------------------
    // CRC helpers - the same polynomials the RTL uses, written independently
    // -------------------------------------------------------------------------
    function automatic logic [6:0] crc7_of(input logic [7:0] d []);
        logic [6:0] c; logic fb; int i, b;
        begin
            c = '0;
            for (i = 0; i < d.size(); i++)
                for (b = 7; b >= 0; b--) begin
                    fb = d[i][b] ^ c[6];
                    c  = {c[5:0], 1'b0};
                    if (fb) c = c ^ 7'h09;
                end
            return c;
        end
    endfunction

    function automatic logic [15:0] crc16_of(input logic [7:0] d []);
        logic [15:0] c; logic fb; int i, b;
        begin
            c = '0;
            for (i = 0; i < d.size(); i++)
                for (b = 7; b >= 0; b--) begin
                    fb = d[i][b] ^ c[15];
                    c  = {c[14:0], 1'b0};
                    if (fb) c = c ^ 16'h1021;
                end
            return c;
        end
    endfunction

    // -------------------------------------------------------------------------
    // Transmit: MISO changes on the falling edge
    // -------------------------------------------------------------------------
    always @(negedge sd_clk or posedge sd_cs_n or negedge inserted) begin
        if (sd_cs_n || !inserted) begin
            // A card that is still programming does not stop being busy because
            // it was deselected. §7.2.4's programming is internal, so on
            // reselection the card resumes holding MISO low until it finishes.
            //
            // Resetting unconditionally to 0xFF made that busy invisible to the
            // host's PRE-EMPTIVE check, which is the one place it is meant to be
            // seen: the sequencer waits for busy immediately before the next
            // command rather than after the previous one, and every reselection
            // handed it a free 0xFF that said "ready". The whole mechanism was
            // being tested against a card that could not express the condition
            // it exists to absorb.
            tx_byte <= (inserted && (busy_bytes > 0)) ? 8'h00 : 8'hFF;
            tx_bit  <= 3'd7;
        end else begin
            if (tx_bit == 3'd0) begin
                tx_bit <= 3'd7;
                // Queued bytes take priority over busy, and the order matters:
                // §7.2.4 puts the data-response token BEFORE the busy period,
                // and states that internal programming only begins a byte after
                // it. Asserting busy first would put 0x00 where the host
                // expects the response, which a correct host reports as a write
                // error - blaming the controller for a fault in the model.
                if (tx_q.size() > 0) begin
                    tx_byte <= tx_q.pop_front();
                end else if (busy_bytes > 0) begin
                    // Busy: the card holds the line low. Any non-zero byte
                    // means ready, so zero is the only thing that means busy.
                    tx_byte    <= 8'h00;
                    if (!inj_busy_forever) busy_bytes <= busy_bytes - 1;
                end else begin
                    tx_byte <= 8'hFF;
                end
            end else begin
                tx_bit <= tx_bit - 3'd1;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Receive: MOSI sampled on the rising edge
    // -------------------------------------------------------------------------
    logic [7:0] rx_byte;

    // Byte assembly and byte HANDLING must happen on the same clock edge.
    //
    // Registering a "byte complete" strobe and acting on it in a separate
    // always block defers every byte by one clock edge - which is invisible
    // mid-transaction, and badly wrong at the end of one: the final byte is
    // then not processed until the NEXT transaction supplies a ninth edge. A
    // stop-tran token closing a multi-block write appears to arrive during the
    // following command, and the model reports the host as out of sync when it
    // is the model that is late.
    logic byte_done;
    always_comb byte_done = !sd_cs_n && inserted && (rx_bit == 3'd7);
    always_comb rx_byte   = {rx_sr[6:0], sd_mosi};

    always @(posedge sd_clk or posedge sd_cs_n or negedge inserted) begin
        if (sd_cs_n || !inserted) begin
            rx_bit <= 3'd0;
            rx_sr  <= '0;
        end else begin
            rx_sr  <= {rx_sr[6:0], sd_mosi};
            rx_bit <= rx_bit + 3'd1;
        end
    end

    // Power-up clocks. Counted only with CS HIGH, which is what §6.4.1.1 asks
    // for, and only while the card is in the socket.
    always @(posedge sd_clk) begin
        if (inserted && sd_cs_n && (pwr_clocks < POWER_UP_CLOCKS))
            pwr_clocks = pwr_clocks + 1;
    end

    // Removal is a power cycle. Everything but the flash goes.
    always @(negedge inserted) begin
        power_off();
    end

    // -------------------------------------------------------------------------
    // Protocol engine
    // -------------------------------------------------------------------------
    typedef enum { P_CMD, P_WAIT_WR_TOKEN, P_WR_DATA, P_WR_CRC } pstate_e;
    pstate_e     pstate;
    logic [7:0]  wr_buf [$];
    logic [31:0] wr_addr;
    logic        wr_multi;
    int unsigned wr_count;

    function automatic int unsigned byte_addr(input logic [31:0] arg);
        return HIGH_CAPACITY ? (arg * 512) : arg;
    endfunction

    // -------------------------------------------------------------------------
    // CSD and CID
    //
    // A real CSD, not filler, because the driver parses it for capacity and the
    // two layouts are genuinely different arithmetic:
    //
    //   v1 (SDSC):  capacity = (C_SIZE+1) * 2^(C_SIZE_MULT+2) * 2^READ_BL_LEN
    //   v2 (SDHC):  capacity = (C_SIZE+1) * 512 KB
    //
    // A model that returns arbitrary bytes lets a driver "parse" them and get a
    // plausible-looking wrong answer, which is exactly the bug this is meant to
    // catch. The values below are chosen so the expected block count is a round
    // number the testbench can assert against:
    //
    //   HIGH_CAPACITY=1  C_SIZE=7679  ->  7680 * 1024   = 7,864,320 blocks
    //   HIGH_CAPACITY=0  C_SIZE=4095, C_SIZE_MULT=7,
    //                    READ_BL_LEN=9 -> 4096 * 512    = 2,097,152 blocks
    //
    // Byte 15 carries the CSD's own CRC7 in bits [7:1], as a card sends it.
    // -------------------------------------------------------------------------
    localparam int unsigned CSD_V2_C_SIZE     = 7679;
    localparam int unsigned CSD_V1_C_SIZE     = 4095;
    localparam int unsigned CSD_BLOCKS_SDHC   = (CSD_V2_C_SIZE + 1) * 1024;
    localparam int unsigned CSD_BLOCKS_SDSC   = (CSD_V1_C_SIZE + 1) * 512;

    function automatic void build_csd(ref logic [7:0] c []);
        logic [7:0] head [];
        int k;
        begin
            for (k = 0; k < 16; k++) c[k] = 8'h00;

            if (HIGH_CAPACITY) begin
                c[0]  = 8'h40;                 // CSD_STRUCTURE = 01 (v2)
                c[1]  = 8'h0E;                 // TAAC
                c[2]  = 8'h00;                 // NSAC
                c[3]  = 8'h32;                 // TRAN_SPEED = 25 MHz
                c[4]  = 8'h5B;                 // CCC high
                c[5]  = 8'h59;                 // CCC low | READ_BL_LEN = 9
                c[6]  = 8'h00;
                c[7]  = 8'((CSD_V2_C_SIZE >> 16) & 8'h3F);   // C_SIZE[21:16]
                c[8]  = 8'((CSD_V2_C_SIZE >> 8)  & 8'hFF);   // C_SIZE[15:8]
                c[9]  = 8'( CSD_V2_C_SIZE        & 8'hFF);   // C_SIZE[7:0]
                c[10] = 8'h7F;
                c[11] = 8'h80;
                c[12] = 8'h0A;
                c[13] = 8'h40;
                c[14] = 8'h00;
            end else begin
                c[0]  = 8'h00;                 // CSD_STRUCTURE = 00 (v1)
                c[1]  = 8'h26;
                c[2]  = 8'h00;
                c[3]  = 8'h32;
                c[4]  = 8'h5F;
                c[5]  = 8'h59;                 // READ_BL_LEN = 9 in [3:0]
                c[6]  = 8'h83;                 // C_SIZE[11:10] in [1:0]
                c[7]  = 8'hFF;                 // C_SIZE[9:2]
                c[8]  = 8'hFF;                 // C_SIZE[1:0] in [7:6]
                c[9]  = 8'h9F;                 // C_SIZE_MULT[2:1] in [1:0]
                c[10] = 8'hFA;                 // C_SIZE_MULT[0]   in [7]
                c[11] = 8'h7F;
                c[12] = 8'h00;
                c[13] = 8'h0A;
                c[14] = 8'h40;
            end

            head = new[15];
            for (k = 0; k < 15; k++) head[k] = c[k];
            c[15] = {crc7_of(head), 1'b1};
        end
    endfunction

    function automatic void build_cid(ref logic [7:0] c []);
        logic [7:0] head [];
        int k;
        begin
            c[0]  = 8'h02;                     // manufacturer ID
            c[1]  = 8'h54; c[2] = 8'h4D;       // OEM "TM"
            c[3]  = 8'h53; c[4] = 8'h44;       // product name "SDMDL"
            c[5]  = 8'h4D; c[6] = 8'h44; c[7] = 8'h4C;
            c[8]  = 8'h10;                     // revision
            c[9]  = CID_SERIAL[31:24];         // serial
            c[10] = CID_SERIAL[23:16];
            c[11] = CID_SERIAL[15:8];
            c[12] = CID_SERIAL[7:0];
            c[13] = 8'h01; c[14] = 8'h5A;      // manufacturing date
            head = new[15];
            for (k = 0; k < 15; k++) head[k] = c[k];
            c[15] = {crc7_of(head), 1'b1};
        end
    endfunction

    task automatic push_r1(input logic [7:0] r1);
        int k;
        begin
            for (k = 0; k < int'(ncr_bytes); k++) tx_q.push_back(8'hFF);
            tx_q.push_back(r1);
        end
    endtask

    // R1 as the card would report it right now, plus any injected error bits.
    function automatic logic [7:0] make_r1();
        logic [7:0] r;
        begin
            r = 8'h00;
            if (is_idle)        r[0] = 1'b1;
            if (inj_r1_illegal) r[2] = 1'b1;
            if (inj_r1_crc)     r[3] = 1'b1;
            if (inj_r1_illegal || inj_r1_crc) faults_applied++;
            return r;
        end
    endfunction

    task automatic send_block(input int unsigned addr, input int unsigned len);
        logic [7:0] blk [];
        logic [15:0] c;
        int k;
        begin
            if (inj_read_err_token) begin
                // §7.3.3.3: upper nibble zero. Sent INSTEAD of a data packet.
                tx_q.push_back(8'h01);
                faults_applied++;
                return;
            end
            blk = new[len];
            for (k = 0; k < len; k++)
                blk[k] = card_mem.exists(addr + k) ? card_mem[addr + k] : 8'hFF;
            c = crc16_of(blk);
            if (inj_bad_data_crc) begin
                c = c ^ 16'hFFFF;
                faults_applied++;
            end

            tx_q.push_back(8'hFE);
            for (k = 0; k < len; k++) tx_q.push_back(blk[k]);
            tx_q.push_back(c[15:8]);
            tx_q.push_back(c[7:0]);
            blocks_read++;
        end
    endtask

    task automatic handle_command(input logic [7:0] c []);
        logic [5:0]  idx;
        logic [31:0] arg;
        logic        crc_ok;
        logic [7:0]  r1;
        logic [7:0]  reg16 [];
        logic [15:0] rc;
        logic [7:0]  stuff;
        int k;
        begin
            idx    = c[0][5:0];
            arg    = {c[1], c[2], c[3], c[4]};
            crc_ok = ({crc7_of('{c[0], c[1], c[2], c[3], c[4]}), 1'b1} == c[5]);

            last_cmd        = idx;
            last_cmd_crc_ok = crc_ok;
            cmds_seen++;
            if (TRACE)
                $display("    [card] t=%0t CMD%0d arg=%08x crc_ok=%b idle=%b inj_ill=%b",
                         $time, idx, arg, crc_ok, is_idle, inj_r1_illegal);

            if (inj_no_response) begin
                faults_applied++;
                return;
            end

            // Not yet listening: fewer than POWER_UP_CLOCKS since insertion.
            // The frame is not received at all, so there is nothing to answer.
            if (ENFORCE_INIT && (pwr_clocks < POWER_UP_CLOCKS)) return;

            // SD mode. A card answers SD-mode commands on CMD, which is MOSI
            // in this wiring, so nothing ever appears on MISO. The one thing
            // that gets it out is CMD0 with CS asserted - which every frame
            // here has - and a valid CRC, since CRC checking cannot be turned
            // off in SD mode (§7.2.2).
            //
            // This is what makes a card swapped in behind the driver's back
            // look like what it is: silence, not a card that happens to be
            // ready for block access.
            if (ENFORCE_INIT && !spi_mode) begin
                if ((idx == 6'd0) && crc_ok) begin
                    spi_mode     = 1'b1;
                    is_idle      = 1'b1;
                    acmd41_polls = 0;
                    push_r1(8'h01);
                end
                return;
            end

            // CMD8's CRC is always verified, and CMD0's must be valid because
            // the card is still in SD mode when it arrives (§7.2.2).
            if (!crc_ok && (crc_on || idx == 6'd0 || idx == 6'd8)) begin
                acmd_next = 1'b0;
                push_r1(make_r1() | 8'h08);   // Com CRC Error
                return;
            end

            r1 = make_r1();

            // A command the card rejects is a command it does not execute:
            // only the R1 goes out - no trailer (§7.3.2), no data packet, no
            // state change. Queueing a block behind a rejected CMD17 left it
            // for the next command's response to be read out of.
            if (r1[2] || r1[3]) begin
                acmd_next = 1'b0;
                push_r1(r1);
                return;
            end

            if (acmd_next) begin
                acmd_next = 1'b0;
                unique case (idx)
                    6'd41: begin                       // ACMD41
                        push_r1(r1);
                        acmd41_polls++;
                        if (acmd41_polls >= ACMD41_POLLS) is_idle = 1'b0;
                    end
                    default: push_r1(r1 | 8'h04);      // illegal
                endcase
                return;
            end

            // In idle state only the identification commands are accepted
            // (§7.2.1). Anything else - a block read before ACMD41 has
            // finished, say - is illegal, and is not executed.
            if (ENFORCE_INIT && is_idle &&
                !(idx inside {6'd0, 6'd8, 6'd55, 6'd58, 6'd59})) begin
                push_r1(r1 | 8'h04);
                return;
            end

            unique case (idx)
                6'd0:  begin is_idle = 1'b1; acmd41_polls = 0; push_r1(8'h01); end
                6'd55: begin acmd_next = 1'b1; push_r1(r1); end
                6'd59: begin crc_on = arg[0]; push_r1(r1); end

                6'd8: begin                            // R7
                    push_r1(r1);
                    // §7.3.2: when R1 reports Illegal Command or Com CRC Error
                    // the card sends ONLY that byte. Modelled unconditionally,
                    // because it is what a v1.x card does to CMD8 and it is the
                    // single easiest way to desynchronise a host.
                    if (!r1[2] && !r1[3]) begin
                        tx_q.push_back(8'h00);
                        tx_q.push_back(8'h00);
                        tx_q.push_back(8'h01);          // voltage accepted
                        tx_q.push_back(arg[7:0]);       // check pattern echo
                    end
                end

                6'd58: begin                            // R3, OCR
                    push_r1(r1);
                    if (!r1[2] && !r1[3]) begin
                        tx_q.push_back(HIGH_CAPACITY ? 8'hC0 : 8'h80);
                        tx_q.push_back(8'hFF);
                        tx_q.push_back(8'h80);
                        tx_q.push_back(8'h00);
                    end
                end

                6'd13: begin                            // R2
                    push_r1(r1);
                    if (!r1[2] && !r1[3]) tx_q.push_back(8'h00);
                end

                6'd16: begin block_len = arg; push_r1(r1); end

                6'd9, 6'd10: begin                      // CSD / CID, 16 bytes
                    push_r1(r1);
                    reg16 = new[16];
                    if (idx == 6'd9) build_csd(reg16);
                    else             build_cid(reg16);
                    rc = crc16_of(reg16);
                    if (inj_bad_data_crc) begin
                        rc = rc ^ 16'hFFFF;
                        faults_applied++;
                    end
                    tx_q.push_back(8'hFE);
                    for (k = 0; k < 16; k++) tx_q.push_back(reg16[k]);
                    tx_q.push_back(rc[15:8]);
                    tx_q.push_back(rc[7:0]);
                end

                6'd17: begin                            // single block read
                    push_r1(r1);
                    send_block(byte_addr(arg), int'(block_len));
                end

                6'd18: begin                            // multi-block read
                    push_r1(r1);
                    // The host stops this with CMD12; queue several blocks and
                    // let it. Any not consumed are flushed when CMD12 arrives.
                    for (k = 0; k < 8; k++)
                        send_block(byte_addr(arg) + k * int'(block_len),
                                   int'(block_len));
                end

                6'd12: begin                            // STOP_TRANSMISSION
                    // §7.2.3: one stuff byte, then the response. A card that
                    // was streaming does not stop on a byte boundary of the
                    // host's choosing, and the stuff byte carries whatever it
                    // was about to send - Linux's mmc_spi notes it "may include
                    // two data bits". Modelled as the whole next byte of the
                    // stream, which is the harder case: a host that reads the
                    // stuff byte as a candidate response sees data, and data
                    // with bit 7 clear is a plausible R1.
                    //
                    // It used to be 0xFF unconditionally, which let exactly
                    // that host pass.
                    stuff = (tx_q.size() > 0) ? tx_q[0] : 8'hFF;
                    tx_q.delete();
                    tx_q.push_back(stuff);
                    push_r1(r1);
                    busy_bytes = 2;
                end

                6'd24, 6'd25: begin                     // writes
                    push_r1(r1);
                    wr_addr  = byte_addr(arg);
                    wr_multi = (idx == 6'd25);
                    wr_count = 0;
                    pstate   = P_WAIT_WR_TOKEN;
                end

                default: push_r1(r1 | 8'h04);           // illegal command
            endcase
        end
    endtask

    task automatic finish_write_block();
        logic [7:0] dr;
        int k;
        begin
            if (inj_write_crc_err)      dr = 8'h0B;     // sss = 101
            else if (inj_write_err)     dr = 8'h0D;     // sss = 110
            else                        dr = 8'h05;     // sss = 010, accepted
            if (dr != 8'h05) faults_applied++;

            if (dr == 8'h05) begin
                for (k = 0; k < wr_buf.size(); k++)
                    card_mem[wr_addr + k] = wr_buf[k];
                wr_addr = wr_addr + 32'(wr_buf.size());
                blocks_written++;
            end
            tx_q.push_back(dr);
            // §7.2.4: programming starts a byte AFTER the data response, so
            // busy cannot appear immediately.
            busy_bytes = prog_bytes;
            wr_buf.delete();
        end
    endtask

    // pstate is assigned with BLOCKING assignments throughout, including inside
    // handle_command. That is deliberate and has to stay consistent: the task
    // sets pstate itself for CMD24 and CMD25, so a nonblocking assignment
    // anywhere else in this block would be applied afterwards and quietly undo
    // it. Driving one variable both ways in a single block is the kind of thing
    // that works until the day it does not.
    always @(posedge sd_clk) begin
        if (byte_done) begin
            unique case (pstate)

                P_CMD: begin
                    // A command byte has its top two bits '01'. Everything else
                    // on MOSI between commands is 0xFF padding.
                    if ((cmd_buf.size() > 0) || (rx_byte[7:6] == 2'b01)) begin
                        cmd_buf.push_back(rx_byte);
                        if (cmd_buf.size() == 6) begin
                            handle_command(cmd_buf);
                            cmd_buf.delete();
                        end
                    end
                end

                P_WAIT_WR_TOKEN: begin
                    if (rx_byte == 8'hFE || rx_byte == 8'hFC) begin
                        wr_buf.delete();
                        pstate = P_WR_DATA;
                    end else if (rx_byte == 8'hFD) begin
                        busy_bytes = 2;
                        pstate     = P_CMD;
                    end else if ((cmd_buf.size() > 0) ||
                                 (rx_byte[7:6] == 2'b01)) begin
                        // §7.3.3.1: a multi-block write that FAILED is stopped
                        // with CMD12, NOT with the stop-tran token - the
                        // sequencer's own header says so, and its abort path
                        // depends on the host being able to do it. So a command
                        // frame is a legitimate thing to see here.
                        //
                        // Accepting only tokens left the card unresynchronisable
                        // after any aborted multi-block write: every command
                        // that followed was swallowed as if it were data, got no
                        // response, and came back as a command timeout. Tests
                        // downstream of such an abort were then all passing or
                        // failing for reasons that had nothing to do with what
                        // they meant to check.
                        //
                        // pstate is set BEFORE handle_command and with a
                        // blocking assignment, so a command that wants its own
                        // state - CMD24 and CMD25 do - still overrides it.
                        cmd_buf.push_back(rx_byte);
                        if (cmd_buf.size() == 6) begin
                            pstate = P_CMD;
                            handle_command(cmd_buf);
                            cmd_buf.delete();
                        end
                    end
                end

                P_WR_DATA: begin
                    wr_buf.push_back(rx_byte);
                    if (wr_buf.size() == int'(block_len)) begin
                        wr_count <= 0;
                        pstate   = P_WR_CRC;
                    end
                end

                P_WR_CRC: begin
                    if (wr_count == 1) begin
                        finish_write_block();
                        pstate = wr_multi ? P_WAIT_WR_TOKEN : P_CMD;
                    end else begin
                        wr_count <= wr_count + 1;
                    end
                end

                default: pstate = P_CMD;
            endcase

            if (TRACE && (pstate == P_WAIT_WR_TOKEN) &&
                ((rx_byte == 8'hFE) || (rx_byte == 8'hFC) || (rx_byte == 8'hFD)))
                $display("    [card] t=%0t token %02x in P_WAIT_WR_TOKEN", $time, rx_byte);
        end
    end

    initial begin
        is_idle        = 1'b1;
        acmd_next      = 1'b0;
        crc_on         = 1'b0;
        block_len      = 32'd512;
        busy_bytes     = 0;
        spi_mode       = 1'b0;
        pwr_clocks     = 0;
        acmd41_polls   = 0;
        faults_applied = 0;
        pstate         = P_CMD;
        cmds_seen      = 0;
        blocks_read    = 0;
        blocks_written = 0;
        last_cmd       = '0;
        last_cmd_crc_ok= 1'b0;
        wr_addr        = '0;
        wr_multi       = 1'b0;
        wr_count       = 0;
    end

    // -------------------------------------------------------------------------
    // Test hooks
    // -------------------------------------------------------------------------

    // Set the internal programming time, in byte-times. Only the post-write busy
    // uses it; the busy that follows CMD12 or a stop-tran token is response
    // timing rather than programming and is unaffected.
    task automatic set_prog_bytes(input int unsigned n);
        begin
            prog_bytes = n;
        end
    endtask

    // Set N_CR, in byte-times, for every response from here on.
    task automatic set_ncr_bytes(input int unsigned n);
        begin
            ncr_bytes = n;
        end
    endtask

    // Put the protocol machine back to "waiting for a command", discarding any
    // partially received block.
    //
    // This is a TESTBENCH utility, not card behaviour, and the distinction
    // matters. A host that abandons a write part-way through a block leaves a
    // real card still waiting for the rest of it, and no command can be issued
    // until the block is completed or the card is power-cycled - the core's own
    // data-path reset clears the controller, not the card. A test that
    // deliberately starves a write therefore has to put the MODEL straight
    // again, or every command after it is swallowed as write data.
    task automatic resync();
        begin
            // tx_q matters as much as the receive side. A card interrupted
            // part-way through sending a block still has the rest of it queued,
            // and the next command's response then arrives behind all of it. The
            // sequencer takes the first byte with bit 7 clear as R1, so a stale
            // payload byte is read as a response - and a plausible one, which
            // came back as a CRC or illegal-command error from a card that had
            // reported neither.
            tx_q.delete();
            cmd_buf.delete();
            wr_buf.delete();
            wr_count = 0;
            wr_multi = 1'b0;
            pstate   = P_CMD;
        end
    endtask

    // What removal does to a card: everything but the flash is lost.
    task automatic power_off();
        begin
            tx_q.delete();
            cmd_buf.delete();
            wr_buf.delete();
            wr_count     = 0;
            wr_multi     = 1'b0;
            pstate       = P_CMD;
            busy_bytes   = 0;
            is_idle      = 1'b1;
            acmd_next    = 1'b0;
            crc_on       = 1'b0;
            block_len    = 32'd512;
            spi_mode     = 1'b0;
            pwr_clocks   = 0;
            acmd41_polls = 0;
        end
    endtask

    function automatic void preload(input int unsigned addr, input logic [7:0] d);
        card_mem[addr] = d;
    endfunction

    function automatic logic [7:0] peek(input int unsigned addr);
        return card_mem.exists(addr) ? card_mem[addr] : 8'hFF;
    endfunction

endmodule : spi_card_model
