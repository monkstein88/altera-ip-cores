`timescale 1ns/1ps

// =============================================================================
// wave_capture_tb.sv
//
// Drives the four scenarios the user guide's timing figures are rendered from,
// and dumps a VCD. It is NOT part of the regression - it checks nothing. Its
// only job is to produce a recording that doc/tools/waveforms/mkwaves.py cuts
// figures out of.
//
// The point of generating figures from a real VCD rather than drawing them is
// that they cannot drift away from the RTL. Change the design and either the
// figure changes with it, or the scenario stops matching and mkwaves.py fails
// loudly. A hand-drawn timing diagram just quietly becomes fiction - and for a
// protocol core that is a real hazard, because SPI-mode SD is full of details
// (N_CR is a RANGE, the data-response token is five bits of payload in eight,
// CRC16 is seeded with zero and not 0xFFFF) that a plausible-looking hand
// drawing gets wrong in a way no reader can catch.
//
// `marker` tags the windows the renderer cuts:
//   1  a command frame and its R1 response       - CMD0, no data phase
//   2  a single-block read                       - token, data, CRC16
//   3  a single-block write                      - token, data, CRC, response, busy
//   4  a read whose CRC16 is wrong               - detection and abort
//
// Blocks are the real 512 bytes - see the note on BLK_SIZE below for why a
// shrunken block was tried first and does not work. The figures are narrow
// windows cut out of a full block rather than a whole block drawn end to end.
// CLKDIV is 1, the fastest the core supports, so sd_clk is clk/2 and one SPI
// bit is two host cycles.
//
// Build and run it with the script next to it:
//
//   ./capture.sh                        # writes wave.vcd
//
// (A comment line here must not begin with the tool's own name - the lexer
// reads such a comment as a pragma and rejects the line that follows.)
// =============================================================================

module wave_capture_tb;

    import avalon_mm_sdcard_controller_pkg::*;

    localparam int unsigned CSR_AW  = 5;
    localparam int unsigned ADDR_W  = 32;
    localparam int unsigned BURST_W = 8;

    // A real 512-byte block, not a shrunken one.
    //
    // The first version of this bench used 8 bytes so a whole block would fit
    // across a figure, and it did not work: the card model - like a real card -
    // keeps its own block length, 512 until CMD16 changes it, so the controller
    // stopped after 8 bytes while the card was still sending. The read failed
    // its CRC16, the write never got a data-response token, and the next
    // command was swallowed as data. Shrinking the block was not a harmless
    // simplification, it was a different protocol.
    //
    // The alternative - issue CMD16 to set 8 - would work against this model but
    // would put a figure in the user guide implying something false: high
    // capacity cards fix the read/write block length at 512 and CMD16 does not
    // change it. So the block is 512 and the figures are narrow windows cut out
    // of it. Nobody wants to look at 512 bytes drawn end to end anyway.
    localparam int unsigned BLK_SIZE = 512;
    localparam logic [31:0] DMA_BASE = 32'h0000_1000;

    int marker = 0;

    logic clk = 0, reset_n = 0;
    always #5 clk = ~clk;                      // 100 MHz host clock

    // ---- csr, driven as the Nios II would ----
    logic [CSR_AW-1:0] csr_address   = '0;
    logic              csr_read      = 1'b0;
    logic              csr_write     = 1'b0;
    logic [31:0]       csr_writedata = '0;
    logic [3:0]        csr_byteenable = 4'hF;
    logic [31:0]       csr_readdata;
    logic              irq;

    // ---- m0, toward the memory model ----
    logic [ADDR_W-1:0]  m0_address;
    logic               m0_read, m0_write;
    logic [31:0]        m0_writedata;
    logic [3:0]         m0_byteenable;
    logic [BURST_W-1:0] m0_burstcount;
    logic               m0_waitrequest;
    logic [31:0]        m0_readdata;
    logic               m0_readdatavalid;
    logic [1:0]         m0_response;

    // ---- the SPI wires ----
    logic sd_clk, sd_mosi, sd_miso, sd_cs_n;
    logic sd_cd_n = 1'b0;                      // card present
    logic sd_wp_n = 1'b0;                      // not write protected

    // ---- fault injection into the card model ----
    logic inj_no_response    = 1'b0;
    logic inj_r1_illegal     = 1'b0;
    logic inj_r1_crc         = 1'b0;
    logic inj_read_err_token = 1'b0;
    logic inj_bad_data_crc   = 1'b0;
    logic inj_write_crc_err  = 1'b0;
    logic inj_write_err      = 1'b0;
    logic inj_busy_forever   = 1'b0;

    int unsigned card_cmds, card_blocks_rd, card_blocks_wr;
    logic [5:0]  card_last_cmd;
    logic        card_last_crc_ok;

    int unsigned mem_wr_beats, mem_rd_beats;
    logic        mem_saw_zero_be_read;

    // -------------------------------------------------------------------------
    // The design under test.
    //
    // Real parameters, not a cut-down configuration: the figures are only worth
    // anything if they were recorded from the core as it ships. FIFO_DEPTH_BYTES
    // is the default 1024, two 512-byte blocks, so the DMA drains the buffer
    // while the shifter is still filling it - which is the overlap the read
    // figure exists to show.
    // -------------------------------------------------------------------------
    avalon_mm_sdcard_controller #(
        .FIFO_DEPTH_BYTES (1024),
        .M0_BURST_WIDTH   (BURST_W),
        .CLKDIV_WIDTH     (8),
        .TIMEOUT_WIDTH    (26),
        .MAX_BLOCK_BYTES  (512),
        .CSR_ADDR_WIDTH   (CSR_AW),
        .ADDR_WIDTH       (ADDR_W),
        .USE_DMA          (1'b1),
        .USE_CARD_DETECT  (1'b1),
        .USE_CRC          (1'b1)
    ) dut (
        .clk (clk), .reset_n (reset_n),
        .csr_address (csr_address), .csr_read (csr_read),
        .csr_write (csr_write), .csr_writedata (csr_writedata),
        .csr_byteenable (csr_byteenable), .csr_readdata (csr_readdata),
        .irq (irq),
        .m0_address (m0_address), .m0_read (m0_read), .m0_write (m0_write),
        .m0_writedata (m0_writedata), .m0_byteenable (m0_byteenable),
        .m0_burstcount (m0_burstcount), .m0_waitrequest (m0_waitrequest),
        .m0_readdata (m0_readdata), .m0_readdatavalid (m0_readdatavalid),
        .m0_response (m0_response),
        .sd_clk (sd_clk), .sd_mosi (sd_mosi), .sd_miso (sd_miso),
        .sd_cs_n (sd_cs_n), .sd_cd_n (sd_cd_n), .sd_wp_n (sd_wp_n)
    );

    avalon_mm_mem_model #(
        .ADDR_WIDTH (ADDR_W), .BURST_WIDTH (BURST_W),
        .MAX_WAIT (0), .READ_LATENCY (2)
    ) u_mem (
        .clk (clk), .reset_n (reset_n),
        .address (m0_address), .read (m0_read), .write (m0_write),
        .writedata (m0_writedata), .byteenable (m0_byteenable),
        .burstcount (m0_burstcount), .waitrequest (m0_waitrequest),
        .readdata (m0_readdata), .readdatavalid (m0_readdatavalid),
        .response (m0_response),
        .wr_beats (mem_wr_beats), .rd_beats (mem_rd_beats),
        .saw_zero_byteenable_read (mem_saw_zero_be_read)
    );

    // NCR_BYTES = 2 puts the response two byte-times after the command, which
    // is in the middle of the 0..8 the specification permits. A card that
    // answered immediately would make the N_CR wait invisible in the figure,
    // and one that took the full 8 would make the figure too wide.
    spi_card_model #(.HIGH_CAPACITY (1'b1), .NCR_BYTES (2), .TRACE (1'b0))
    u_card (
        .sd_clk (sd_clk), .sd_cs_n (sd_cs_n),
        .sd_mosi (sd_mosi), .sd_miso (sd_miso),
        .inj_no_response (inj_no_response), .inj_r1_illegal (inj_r1_illegal),
        .inj_r1_crc (inj_r1_crc), .inj_read_err_token (inj_read_err_token),
        .inj_bad_data_crc (inj_bad_data_crc),
        .inj_write_crc_err (inj_write_crc_err), .inj_write_err (inj_write_err),
        .inj_busy_forever (inj_busy_forever),
        .cmds_seen (card_cmds), .blocks_read (card_blocks_rd),
        .blocks_written (card_blocks_wr),
        .last_cmd (card_last_cmd), .last_cmd_crc_ok (card_last_crc_ok)
    );

    // -------------------------------------------------------------------------
    // Register access
    // -------------------------------------------------------------------------
    task automatic csr_wr(input int unsigned a, input logic [31:0] d);
        begin
            @(negedge clk);
            csr_address = CSR_AW'(a); csr_writedata = d;
            csr_byteenable = 4'hF;    csr_write = 1'b1;
            @(negedge clk);
            csr_write = 1'b0;
        end
    endtask

    task automatic csr_rd(input int unsigned a, output logic [31:0] d);
        begin
            @(negedge clk);
            csr_address = CSR_AW'(a); csr_read = 1'b1;
            @(negedge clk);
            csr_read = 1'b0;
            d = csr_readdata;
        end
    endtask

    task automatic cmd_issue(input logic [5:0] idx, input logic [31:0] arg,
                             input resp_e rt, input bit dat_en,
                             input bit dat_dir);
        logic [31:0] c, rd;
        int unsigned guard;
        begin
            guard = 0;
            forever begin
                csr_rd(REG_STATUS, rd);
                if (!rd[STAT_CMD_BUSY]) break;
                guard++;
                if (guard > 100000) begin
                    $display("wave_capture: stuck busy before CMD%0d", idx);
                    $finish;
                end
            end
            csr_wr(REG_IRQ_STATUS, 32'hFFFF_FFFF);
            csr_wr(REG_CMD_ARG, arg);
            c = '0;
            c[CMD_INDEX_LSB +: 6] = idx;
            c[CMD_RESP_LSB  +: 2] = rt;
            c[CMD_DATA_EN]        = dat_en;
            c[CMD_DATA_DIR]       = dat_dir;
            c[CMD_START]          = 1'b1;
            csr_wr(REG_CMD, c);

            // Confirm the write was accepted before returning. Without this the
            // caller's wait_idle() can run before the sequencer has left idle
            // and return instantly, so the next scenario's command is written
            // on top of this one - which loses a command silently and produces
            // a VCD in which one of the figures simply is not there.
            guard = 0;
            rd = '0;
            while (!rd[STAT_CMD_BUSY] && (guard < 64)) begin
                csr_rd(REG_STATUS, rd);
                guard++;
            end
            if (!rd[STAT_CMD_BUSY])
                $display("wave_capture: CMD%0d was not accepted", idx);
        end
    endtask

    // Wait for the whole operation to retire. Polling STATUS rather than
    // waiting a fixed time, so a change that makes an operation longer shows up
    // as a wider figure rather than as a truncated one.
    task automatic wait_idle();
        logic [31:0] rd, rd2;
        int unsigned guard;
        begin
            guard = 0;
            forever begin
                csr_rd(REG_STATUS, rd);
                if (!rd[STAT_CMD_BUSY] && !rd[STAT_DAT_BUSY] &&
                    !rd[STAT_DMA_BUSY]) break;
                guard++;
                if (guard > 200000) begin
                    $display("wave_capture: operation never retired");
                    $finish;
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // The scenarios
    // -------------------------------------------------------------------------
    logic [31:0] rd, rd2;

    initial begin
        // Depth 1 at each level rather than $dumpvars(0, ...) on the whole
        // hierarchy. A 512-byte block is about 8,200 host cycles, four
        // scenarios is a third of a millisecond, and dumping every net in the
        // card model and the memory model as well produces a VCD of tens of
        // megabytes to render four small figures from. These are the signals
        // mkwaves.py actually reads.
        $dumpfile("wave.vcd");
        $dumpvars(1, wave_capture_tb);
        $dumpvars(1, dut);
        $dumpvars(1, dut.u_seq);
        $dumpvars(1, dut.u_phy);
        $dumpvars(1, dut.u_fifo);

        // Give the card's block 0 a recognisable pattern before reading it.
        // Without this the model returns 0xFF for every unwritten byte, and the
        // read figure shows a data phase indistinguishable from an idle line -
        // which is the one thing a reader needs to be able to tell apart.
        for (int k = 0; k < BLK_SIZE; k++)
            u_card.preload(k, 8'(8'hA0 + k[7:0]));

        repeat (4) @(negedge clk);
        reset_n = 1'b1;
        repeat (4) @(negedge clk);

        // CLKDIV=1 gives sd_clk = clk/2, the fastest the core runs. TIMEOUT is
        // deliberately generous: this bench records normal behaviour, and a
        // timeout firing inside a figure would be recording a different core.
        csr_wr(REG_CLKDIV,    32'd1);
        csr_wr(REG_TIMEOUT,   32'd200000);
        csr_wr(REG_BLK_SIZE,  BLK_SIZE);
        csr_wr(REG_BLK_COUNT, 32'd1);
        csr_wr(REG_DMA_ADDR,  DMA_BASE);
        // Unmask every interrupt source, so the figures show irq rising where a
        // driver would see it. With the mask left at reset the irq row records
        // a flat zero, which tells the reader nothing and quietly implies the
        // core does not raise one.
        csr_wr(REG_IRQ_ENABLE, 32'hFFFF_FFFF);
        csr_wr(REG_CTRL, (32'd1 << CTRL_ENABLE) |
                         (32'd1 << CTRL_CRC_EN) |
                         (32'd1 << CTRL_DMA_EN));
        repeat (8) @(negedge clk);

        $display("");
        $display("recorded scenarios:");
        // ---- 1. a command frame and its R1 response -------------------------
        // CMD0 GO_IDLE_STATE. Six bytes out - 0x40, four argument bytes, CRC7
        // with the stop bit - then 0xFF until the card answers, which by the
        // specification is anywhere from 0 to 8 byte-times later.
        marker = 1;
        cmd_issue(6'd0, 32'h0000_0000, RESP_R1, 1'b0, 1'b0);
        wait_idle();
        csr_rd(REG_IRQ_STATUS, rd);
        $display("  1  command + R1        IRQ_STATUS=%08h  (expect CMD_DONE)", rd);
        repeat (20) @(negedge clk);

        // ---- 2. a single-block read -----------------------------------------
        // CMD17 READ_SINGLE_BLOCK. R1, then the card is free to think for as
        // long as it likes before the 0xFE start token; then BLK_SIZE bytes and
        // a two-byte CRC16. The DMA drains the buffer to memory as it fills.
        marker = 2;
        cmd_issue(6'd17, 32'h0000_0000, RESP_R1, 1'b1, 1'b0);
        wait_idle();
        csr_rd(REG_IRQ_STATUS, rd);
        $display("  2  single-block read   IRQ_STATUS=%08h  (expect CMD+DATA+DMA done)", rd);
        repeat (20) @(negedge clk);

        // ---- 3. a single-block write ----------------------------------------
        // CMD24 WRITE_BLOCK. R1, one byte gap, 0xFE, the data, CRC16, then the
        // card's data-response token - five bits of payload in eight, xxx0sss1 -
        // and then it holds MISO low for as long as the write takes.
        marker = 3;
        csr_wr(REG_DMA_ADDR, DMA_BASE);
        cmd_issue(6'd24, 32'h0000_0000, RESP_R1, 1'b1, 1'b1);
        wait_idle();
        csr_rd(REG_IRQ_STATUS, rd);
        csr_rd(REG_ERR_INFO, rd2);
        // ERR_INFO[7:0] is the data-response token. 0x05 is xxx0sss1 with
        // sss=010, "data accepted" - the only value that means the block landed.
        $display("  3  single-block write  IRQ_STATUS=%08h  data-response=%02h", rd, rd2[7:0]);
        repeat (20) @(negedge clk);

        // ---- 4. a read whose CRC16 does not match ---------------------------
        // The same read as scenario 2, with the card corrupting the CRC. The
        // core folds the last received byte into the running CRC16 combinatorially
        // and checks for zero, so the mismatch is known at the end of the final
        // CRC byte rather than a byte later - which is the whole reason the check
        // is written that way, and what this figure exists to show.
        marker = 4;
        inj_bad_data_crc = 1'b1;
        csr_wr(REG_DMA_ADDR, DMA_BASE + 32'h100);
        cmd_issue(6'd17, 32'h0000_0000, RESP_R1, 1'b1, 1'b0);

        // Acknowledge CMD_DONE as soon as the command phase retires, which is
        // what a driver's interrupt handler does. Write-1-to-clear, and only
        // that bit: clearing the whole word here would discard the CRC error
        // this scenario exists to record.
        forever begin
            csr_rd(REG_STATUS, rd);
            if (!rd[STAT_CMD_BUSY]) break;
        end
        csr_wr(REG_IRQ_STATUS, 32'd1 << IRQ_CMD_DONE);

        wait_idle();
        inj_bad_data_crc = 1'b0;
        csr_rd(REG_IRQ_STATUS, rd);
        $display("  4  read, bad CRC16     IRQ_STATUS=%08h  (expect ERR_DAT_CRC, bit 12)", rd);
        repeat (20) @(negedge clk);

        marker = 0;
        repeat (10) @(negedge clk);
        $display("card saw %0d commands, %0d blocks read, %0d written",
                 card_cmds, card_blocks_rd, card_blocks_wr);
        $finish;
    end

    // A hard stop, so a design change that hangs the bench fails the capture
    // instead of filling the disk with a VCD nobody wants.
    initial begin
        #20_000_000;
        $display("wave_capture: TIMED OUT - no VCD worth rendering");
        $finish;
    end

endmodule
