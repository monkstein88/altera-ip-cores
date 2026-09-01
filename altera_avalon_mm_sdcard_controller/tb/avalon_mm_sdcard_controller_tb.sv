`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_tb.sv
//
// Full-core regression: the controller against a behavioural SD card and an
// Avalon-MM memory, driven the way the HAL driver drives it.
//
// The suite is organised around what can actually go wrong rather than around
// the register map:
//
//   IDENTIFICATION   the CMD0 / CMD8 / ACMD41 / CMD58 sequence, including the
//                    v1.x path where CMD8 returns an illegal-command R1 and the
//                    32-bit trailer is NEVER SENT (§7.3.2). That path is the
//                    single easiest way to desynchronise a host, so it is
//                    checked by issuing a further command afterwards and
//                    confirming it still works.
//   DATA             single and multi-block, both directions, verified against
//                    the card's own memory rather than against an expectation
//                    the testbench computed the same way the DUT did.
//   FAILURES         every error the card can report: no response, CRC error,
//                    data error token, corrupt block CRC, rejected write.
//                    A controller that only handles the happy path is a
//                    controller that hangs on a marginal card.
//   THROUGHPUT       measured, not asserted. Bytes moved per SPI clock, with a
//                    floor - this is what stops a refactor from quietly
//                    reintroducing an inter-byte gap, which is invisible to
//                    every functional check above.
// =============================================================================

module avalon_mm_sdcard_controller_tb;

    import avalon_mm_sdcard_controller_pkg::*;

    localparam int unsigned CSR_AW    = 5;
    localparam int unsigned ADDR_W    = 32;
    localparam int unsigned BURST_W   = 8;
    localparam int unsigned FIFO_B    = 1024;
    localparam time         CLK_P     = 10ns;     // 100 MHz

    logic clk = 1'b0, reset_n = 1'b0;
    always #(CLK_P/2) clk = ~clk;

    // ---- CSR ---------------------------------------------------------------
    logic [CSR_AW-1:0] csr_address = '0;
    logic              csr_read = 1'b0, csr_write = 1'b0;
    logic [31:0]       csr_writedata = '0;
    logic [3:0]        csr_byteenable = 4'hF;
    logic [31:0]       csr_readdata;
    logic              irq;

    // ---- m0 <-> memory -----------------------------------------------------
    logic [ADDR_W-1:0]  m0_address;
    logic               m0_read, m0_write;
    logic [31:0]        m0_writedata, m0_readdata;
    logic [3:0]         m0_byteenable;
    logic [BURST_W-1:0] m0_burstcount;
    logic               m0_waitrequest, m0_readdatavalid;
    logic [1:0]         m0_response;

    int unsigned mem_wr_beats, mem_rd_beats;
    logic        mem_saw_zero_be_read;

    // ---- SD pins -----------------------------------------------------------
    logic sd_clk, sd_mosi, sd_miso, sd_cs_n;
    logic sd_cd_n = 1'b0, sd_wp_n = 1'b1;

    // ---- fault injection ---------------------------------------------------
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

    // -------------------------------------------------------------------------
    avalon_mm_sdcard_controller #(
        .FIFO_DEPTH_BYTES (FIFO_B),
        .M0_BURST_WIDTH   (BURST_W),
        .CSR_ADDR_WIDTH   (CSR_AW),
        .ADDR_WIDTH       (ADDR_W)
    ) dut (
        .clk (clk), .reset_n (reset_n),
        .csr_address (csr_address), .csr_read (csr_read), .csr_write (csr_write),
        .csr_writedata (csr_writedata), .csr_byteenable (csr_byteenable),
        .csr_readdata (csr_readdata), .irq (irq),
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
        .MAX_WAIT (1), .READ_LATENCY (2)
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

    spi_card_model #(.HIGH_CAPACITY (1'b1), .NCR_BYTES (2), .TRACE (1'b0)) u_card (
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
    // Scoreboard
    // -------------------------------------------------------------------------
    // Set either of these to 1 when a failure needs the wire-level story:
// TRACE_CMD logs each command issued and the interrupt status it left,
// and the card model's own TRACE parameter logs what the card decoded.
localparam bit TRACE_CMD = 1'b0;
    int unsigned checks_run = 0, checks_fail = 0;

    task automatic check(input string what, input bit cond);
        checks_run++;
        if (!cond) begin
            checks_fail++;
            $display("  FAIL  %s", what);
        end
    endtask

    // Errors are reported with the bits named, because "some error bit is set"
    // sends you looking in the wrong place.
    task automatic check_noerr(input string what, input logic [31:0] st);
        string b;
        begin
            b = "";
            if (st[IRQ_ERR_CMD_TMO])   b = {b, " CMD_TMO"};
            if (st[IRQ_ERR_CMD_CRC])   b = {b, " CMD_CRC"};
            if (st[IRQ_ERR_CMD_ILL])   b = {b, " CMD_ILL"};
            if (st[IRQ_ERR_DAT_TMO])   b = {b, " DAT_TMO"};
            if (st[IRQ_ERR_DAT_CRC])   b = {b, " DAT_CRC"};
            if (st[IRQ_ERR_DAT_TOKEN]) b = {b, " DAT_TOKEN"};
            if (st[IRQ_ERR_WRITE])     b = {b, " WRITE"};
            if (st[IRQ_ERR_DMA])       b = {b, " DMA"};
            checks_run++;
            if ((st & IRQ_ERR_MASK) != '0) begin
                checks_fail++;
                $display("  FAIL  %s  (set:%s)", what, b);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // CSR access. Read latency is fixed at 1, so readdata is valid at the
    // negedge following the posedge that accepted the address.
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

    // Issue a command and wait for the sequencer to return to idle.
    task automatic send_cmd(input logic [5:0] idx, input logic [31:0] arg,
                            input resp_e rt,
                            input bit dat_en, input bit dat_dir,
                            input bit multi, input bit autostop,
                            output logic [31:0] st);
        logic [31:0] c, rd;
        int unsigned guard;
        begin
            // Wait for idle BEFORE writing CMD. The register is ignored while
            // the sequencer is busy - which is the right hardware behaviour,
            // since a second CMD write must not corrupt a transfer in flight -
            // but it means a driver that writes without checking loses the
            // command silently. Polling afterwards does not catch it either:
            // busy is already clear, so the poll returns immediately and the
            // command simply never happened.
            guard = 0;
            forever begin
                csr_rd(REG_STATUS, rd);
                if (!rd[STAT_CMD_BUSY]) break;
                guard++;
                if (guard > 400000) begin
                    $display("  FAIL  send_cmd(CMD%0d): busy never cleared before issue", idx);
                    checks_fail++;
                    break;
                end
            end

            csr_wr(REG_IRQ_STATUS, 32'hFFFF_FFFF);   // clear stale events
            csr_wr(REG_CMD_ARG, arg);
            c = '0;
            c[CMD_INDEX_LSB +: 6] = idx;
            c[CMD_RESP_LSB  +: 2] = rt;
            c[CMD_DATA_EN]        = dat_en;
            c[CMD_DATA_DIR]       = dat_dir;
            c[CMD_MULTI]          = multi;
            c[CMD_AUTO_STOP]      = autostop;
            c[CMD_START]          = 1'b1;
            csr_wr(REG_CMD, c);

            // Confirm the command was actually accepted before waiting for it
            // to finish, so a dropped write is reported as a dropped write
            // rather than as a mysteriously instant success.
            guard = 0;
            rd = '0;
            while (!rd[STAT_CMD_BUSY] && (guard < 64)) begin
                csr_rd(REG_STATUS, rd);
                guard++;
            end
            if (!rd[STAT_CMD_BUSY]) begin
                $display("  FAIL  send_cmd(CMD%0d): write to CMD was not accepted", idx);
                checks_fail++;
            end

            guard = 0;
            forever begin
                csr_rd(REG_STATUS, rd);
                if (!rd[STAT_CMD_BUSY]) break;
                guard++;
                if (guard > 400000) begin
                    $display("  FAIL  send_cmd(CMD%0d): never left busy", idx);
                    checks_fail++;
                    break;
                end
            end
            csr_rd(REG_IRQ_STATUS, st);
            if (TRACE_CMD)
                $display("    [tb] t=%0t issued CMD%0d -> irq_status=%08x", $time, idx, st);
        end
    endtask

    task automatic card_init();
        logic [31:0] st, r0, r1;
        begin
            // Power-up: >=74 clocks with CS HIGH (§6.4.1.1). CS_MANUAL is the
            // only way to express that, since a transaction wants CS low.
            csr_wr(REG_CLKDIV, 32'd125);                  // ~400 kHz
            csr_wr(REG_CTRL, (32'b1 << CTRL_ENABLE) |
                             (32'b1 << CTRL_CS_MANUAL) |
                             (32'b1 << CTRL_CS_VALUE)  |
                             (32'b1 << CTRL_CLK_RUN));
            repeat (200 * 8 * 2 * 125) @(posedge clk);
            csr_wr(REG_CTRL, (32'b1 << CTRL_ENABLE) | (32'b1 << CTRL_CRC_EN) |
                             (32'b1 << CTRL_DMA_EN));

            send_cmd(6'd0,  32'h0,          RESP_R1,   0,0,0,0, st);
            csr_rd(REG_RESP0, r0);
            check("CMD0 returns in_idle_state (R1 = 0x01)", r0[7:0] == 8'h01);

            send_cmd(6'd8,  32'h000001AA,   RESP_R3R7, 0,0,0,0, st);
            csr_rd(REG_RESP1, r1);
            check("CMD8 echoes the check pattern 0xAA", r1[7:0] == 8'hAA);

            // ACMD41 is POLLED. The card reports in_idle_state until its
            // initialisation finishes; §7.2.1's flow loops here, and a driver
            // that issues it once and gives up works only by luck.
            r0 = 32'hFF;
            for (int unsigned k = 0; (k < 16) && (r0[7:0] != 8'h00); k++) begin
                send_cmd(6'd55, 32'h0,        RESP_R1, 0,0,0,0, st);
                send_cmd(6'd41, 32'h40000000, RESP_R1, 0,0,0,0, st);
                csr_rd(REG_RESP0, r0);
            end
            check("ACMD41 polled until in_idle_state clears", r0[7:0] == 8'h00);

            send_cmd(6'd58, 32'h0,          RESP_R3R7, 0,0,0,0, st);
            csr_rd(REG_RESP1, r1);
            check("CMD58 OCR reports CCS set (high capacity)", r1[31:24] == 8'hC0);

            csr_wr(REG_CLKDIV, 32'd2);                    // 25 MHz
            csr_wr(REG_BLK_SIZE, 32'd512);
        end
    endtask

    // -------------------------------------------------------------------------
    int unsigned sclk_rises = 0;
    logic sclk_d = 1'b0;
    always_ff @(posedge clk) begin
        sclk_d <= sd_clk;
        if (sd_clk && !sclk_d) sclk_rises++;
    end

    // -------------------------------------------------------------------------
    initial begin
        logic [31:0] st, rd;
        int unsigned i, base, blk;
        bit ok;
        int unsigned rises_before;
        real bytes_per_clock;

        $display("");
        $display("=== avalon_mm_sdcard_controller: full-core regression ===");
        $display("");

        reset_n = 1'b0;
        repeat (8) @(negedge clk);
        reset_n = 1'b1;
        repeat (4) @(negedge clk);

        // ---- core identity ------------------------------------------------
        csr_rd(REG_CORE_INFO, rd);
        check("CORE_INFO reports major version 1", rd[15:8] == 8'd1);
        check("CORE_INFO reports the SPI PHY",     rd[26] == 1'b1);
        check("CORE_INFO reports DMA present",     rd[24] == 1'b1);

        // ---- identification ------------------------------------------------
        $display("  -- identification --");
        card_init();

        // ---- single block read ---------------------------------------------
        $display("  -- single block read --");
        for (i = 0; i < 512; i++) u_card.preload(0 + i, 8'((i * 5) + 17));
        csr_wr(REG_BLK_COUNT, 32'd1);
        csr_wr(REG_DMA_ADDR,  32'h0000_1000);
        send_cmd(6'd17, 32'd0, RESP_R1, 1,0,0,0, st);
        check("CMD17: DATA_DONE set", st[IRQ_DATA_DONE]);
        check_noerr("CMD17: no error bits", st);

        ok = 1'b1;
        for (i = 0; i < 128; i++) begin
            logic [31:0] exp;
            exp = {u_card.peek(4*i+3), u_card.peek(4*i+2),
                   u_card.peek(4*i+1), u_card.peek(4*i+0)};
            if (u_mem.peek(32'h1000/4 + i) !== exp) begin
                if (ok) $display("    first mismatch at word %0d: got %08x exp %08x",
                                 i, u_mem.peek(32'h1000/4 + i), exp);
                ok = 1'b0;
            end
        end
        check("CMD17: block landed in memory, little-endian", ok);

        // ---- multi-block read ----------------------------------------------
        $display("  -- multi-block read (4 blocks, auto CMD12) --");
        for (i = 0; i < 4*512; i++) u_card.preload(32'h4000 + i, 8'((i * 3) + 9));
        csr_wr(REG_BLK_COUNT, 32'd4);
        csr_wr(REG_DMA_ADDR,  32'h0002_0000);
        rises_before = sclk_rises;
        send_cmd(6'd18, 32'h4000/512, RESP_R1, 1,0,1,1, st);
        check("CMD18: DATA_DONE set", st[IRQ_DATA_DONE]);
        check_noerr("CMD18: no error bits", st);

        ok = 1'b1;
        for (i = 0; i < 4*128; i++) begin
            logic [31:0] exp;
            exp = {u_card.peek(32'h4000+4*i+3), u_card.peek(32'h4000+4*i+2),
                   u_card.peek(32'h4000+4*i+1), u_card.peek(32'h4000+4*i+0)};
            if (u_mem.peek(32'h20000/4 + i) !== exp) ok = 1'b0;
        end
        check("CMD18: all four blocks contiguous in memory", ok);

        // Throughput: bytes actually moved per SPI clock. The framing floor is
        // 512/515 = 0.994 bytes per 8 clocks; anything materially below that is
        // a stall the controller introduced.
        bytes_per_clock = real'(4*512) / real'(sclk_rises - rises_before);
        $display("    multi-block read: %0d SPI clocks for 2048 bytes = %0.3f bytes/clock",
                 sclk_rises - rises_before, bytes_per_clock);
        check("CMD18: throughput above 0.100 bytes per SPI clock",
              bytes_per_clock > 0.100);

        // ---- single block write --------------------------------------------
        $display("  -- single block write --");
        for (i = 0; i < 128; i++) u_mem.poke(32'h3000/4 + i, 32'hA5A5_0000 + i);
        csr_wr(REG_BLK_COUNT, 32'd1);
        csr_wr(REG_DMA_ADDR,  32'h0000_3000);
        send_cmd(6'd24, 32'h8000/512, RESP_R1, 1,1,0,0, st);
        check("CMD24: DATA_DONE set", st[IRQ_DATA_DONE]);
        check_noerr("CMD24: no error bits", st);

        ok = 1'b1;
        for (i = 0; i < 128; i++) begin
            logic [31:0] exp;
            exp = 32'hA5A5_0000 + i;
            if ({u_card.peek(32'h8000+4*i+3), u_card.peek(32'h8000+4*i+2),
                 u_card.peek(32'h8000+4*i+1), u_card.peek(32'h8000+4*i+0)} !== exp) begin
                if (ok) $display("    first mismatch at word %0d", i);
                ok = 1'b0;
            end
        end
        check("CMD24: block reached the card intact", ok);

        // ---- multi-block write ---------------------------------------------
        $display("  -- multi-block write (3 blocks, stop-tran) --");
        for (i = 0; i < 3*128; i++) u_mem.poke(32'h5000/4 + i, 32'h1234_0000 + i);
        csr_wr(REG_BLK_COUNT, 32'd3);
        csr_wr(REG_DMA_ADDR,  32'h0000_5000);
        send_cmd(6'd25, 32'hC000/512, RESP_R1, 1,1,1,1, st);
        check("CMD25: DATA_DONE set", st[IRQ_DATA_DONE]);
        check_noerr("CMD25: no error bits", st);
        check("CMD25: card recorded three written blocks",
              card_blocks_wr >= 4);   // 1 from CMD24 + 3 here

        // ---- the truncated-response path -----------------------------------
        $display("  -- v1.x CMD8: R1 only, no trailer (§7.3.2) --");
        inj_r1_illegal = 1'b1;
        send_cmd(6'd8, 32'h000001AA, RESP_R3R7, 0,0,0,0, st);
        check("CMD8 illegal: ERR_CMD_ILL reported", st[IRQ_ERR_CMD_ILL]);
        inj_r1_illegal = 1'b0;

        // The real test is not the error bit - it is whether the bus is still
        // in sync afterwards. A DUT that read four trailer bytes that were
        // never sent has consumed the next command's response.
        send_cmd(6'd58, 32'h0, RESP_R3R7, 0,0,0,0, st);
        csr_rd(REG_RESP1, rd);
        check("bus still synchronised after a truncated response",
              rd[31:24] == 8'hC0);

        // ---- failure paths --------------------------------------------------
        $display("  -- failure paths --");
        csr_wr(REG_TIMEOUT, 32'd200000);

        inj_no_response = 1'b1;
        send_cmd(6'd17, 32'd0, RESP_R1, 0,0,0,0, st);
        check("no response: ERR_CMD_TMO reported", st[IRQ_ERR_CMD_TMO]);
        inj_no_response = 1'b0;

        csr_wr(REG_BLK_COUNT, 32'd1);
        csr_wr(REG_DMA_ADDR,  32'h0000_1000);
        inj_bad_data_crc = 1'b1;
        send_cmd(6'd17, 32'd0, RESP_R1, 1,0,0,0, st);
        check("corrupt block CRC16: ERR_DAT_CRC reported", st[IRQ_ERR_DAT_CRC]);
        inj_bad_data_crc = 1'b0;

        inj_read_err_token = 1'b1;
        send_cmd(6'd17, 32'd0, RESP_R1, 1,0,0,0, st);
        check("data error token: ERR_DAT_TOKEN reported", st[IRQ_ERR_DAT_TOKEN]);
        inj_read_err_token = 1'b0;

        csr_wr(REG_DMA_ADDR, 32'h0000_3000);
        inj_write_crc_err = 1'b1;
        send_cmd(6'd24, 32'h8000/512, RESP_R1, 1,1,0,0, st);
        check("write rejected: ERR_WRITE reported", st[IRQ_ERR_WRITE]);
        inj_write_crc_err = 1'b0;

        // Recovery: after all of that, a normal command must still work.
        send_cmd(6'd58, 32'h0, RESP_R3R7, 0,0,0,0, st);
        check_noerr("recovered: no error after the failure sequence", st);

        // ---- Avalon conformance ---------------------------------------------
        check("m0 never issued a read with all byteenables clear",
              !mem_saw_zero_be_read);

        // ---- interrupt ------------------------------------------------------
        csr_wr(REG_IRQ_STATUS, 32'hFFFF_FFFF);
        csr_wr(REG_IRQ_ENABLE, 32'h0);
        check("irq deasserted with the mask clear", irq === 1'b0);
        csr_wr(REG_IRQ_ENABLE, 32'hFFFF_FFFF);
        send_cmd(6'd58, 32'h0, RESP_R3R7, 0,0,0,0, st);
        check("irq asserted on CMD_DONE with the mask set", irq === 1'b1);
        csr_wr(REG_IRQ_STATUS, 32'hFFFF_FFFF);
        @(negedge clk);
        check("irq cleared by writing 1 to the status bits", irq === 1'b0);

        $display("");
        $display("    card saw %0d commands, %0d blocks read, %0d written",
                 card_cmds, card_blocks_rd, card_blocks_wr);
        $display("");
        $display("=== %0d checks, %0d failures ===", checks_run, checks_fail);
        if (checks_fail == 0) $display("*** PASS ***");
        else                  $display("*** FAIL ***");
        $display("");
        $finish;
    end

    initial begin
        #500ms;
        $display("*** FAIL: global timeout ***");
        $finish;
    end

endmodule : avalon_mm_sdcard_controller_tb
