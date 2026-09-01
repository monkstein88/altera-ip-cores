`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_fifo_tb.sv
//
// Unit testbench for the block buffer.
//
// Three things are checked, and the first is the one that would otherwise be
// found by a filesystem behaving strangely rather than by a simulation:
//
//   1. BYTE ORDER. Byte 0 of a block must land in bits [7:0] of the first word.
//      Get this backwards and every string a filesystem reads still looks
//      correct while every 32-bit field is byte-swapped - a failure that
//      survives casual testing for a long time.
//   2. ROUND TRIP in both directions, since the two paths through this module
//      share only the memory: card->host packs bytes into words, host->card
//      unpacks words into bytes.
//   3. PARTIAL WORDS. A 512-byte data block is a multiple of four; a 16-byte
//      CSD read is too, but a partial-block read on a standard-capacity card
//      need not be. `flush` must commit the tail rather than strand it.
// =============================================================================

module avalon_mm_sdcard_controller_fifo_tb;

    localparam int unsigned DEPTH_BYTES = 1024;
    localparam time         CLK_PERIOD  = 10ns;

    logic clk = 1'b0;
    logic reset_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    logic        clear, dir_h2c, flush;
    logic        b_wr, b_rd, b_empty, b_full;
    logic [7:0]  b_wdata, b_rdata;
    logic        w_wr, w_rd, w_empty, w_full;
    logic [31:0] w_wdata, w_rdata;
    logic [15:0] level_bytes;

    avalon_mm_sdcard_controller_fifo #(.DEPTH_BYTES (DEPTH_BYTES)) dut (
        .clk (clk), .reset_n (reset_n), .clear (clear),
        .dir_host_to_card (dir_h2c),
        .b_wr (b_wr), .b_wdata (b_wdata), .b_rd (b_rd), .b_rdata (b_rdata),
        .b_empty (b_empty), .b_full (b_full), .flush (flush),
        .w_wr (w_wr), .w_wdata (w_wdata), .w_rd (w_rd), .w_rdata (w_rdata),
        .w_empty (w_empty), .w_full (w_full),
        .level_bytes (level_bytes)
    );

    int unsigned checks_run = 0, checks_fail = 0;

    task automatic check(input string what, input bit cond);
        checks_run++;
        if (!cond) begin
            checks_fail++;
            $display("  FAIL  %s", what);
        end
    endtask

    task automatic reset_dut(input bit h2c);
        begin
            reset_n = 1'b0;
            clear = 1'b0; dir_h2c = h2c; flush = 1'b0;
            b_wr = 1'b0; b_rd = 1'b0; b_wdata = '0;
            w_wr = 1'b0; w_rd = 1'b0; w_wdata = '0;
            repeat (4) @(negedge clk);
            reset_n = 1'b1;
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        int unsigned i, nbytes;
        logic [7:0]  src   [];
        logic [31:0] gotw  [];
        logic [7:0]  gotb  [];
        logic [31:0] expw;
        bit          ok;

        $display("");
        $display("=== avalon_mm_sdcard_controller_fifo ===");
        $display("");

        // ---------------------------------------------------------------------
        // 1. card -> host : bytes in, words out, little-endian
        // ---------------------------------------------------------------------
        reset_dut(1'b0);
        nbytes = 512;
        src = new[nbytes];
        foreach (src[i]) src[i] = 8'((i * 7) + 3);

        gotw = new[nbytes/4];
        // Each branch declares its OWN index. Sharing the enclosing `i` between
        // forked threads is the classic way to make a working DUT look broken:
        // both loops advance the same counter, so each runs a fraction of its
        // iterations and the data lands nowhere near where it is checked.
        fork
            begin : push_bytes
                int unsigned pi;
                for (pi = 0; pi < nbytes; pi++) begin
                    while (b_full) @(negedge clk);
                    b_wdata = src[pi]; b_wr = 1'b1;
                    @(negedge clk);
                    b_wr = 1'b0;
                    // The real sequencer delivers a byte every 8 SPI clocks;
                    // pushing back-to-back is strictly harder on the FIFO.
                end
            end
            begin : pop_words
                int unsigned qi;
                for (qi = 0; qi < nbytes/4; qi++) begin
                    while (w_empty) @(negedge clk);
                    gotw[qi] = w_rdata; w_rd = 1'b1;
                    @(negedge clk);
                    w_rd = 1'b0;
                end
            end
        join

        ok = 1'b1;
        for (i = 0; i < nbytes/4; i++) begin
            expw = {src[4*i+3], src[4*i+2], src[4*i+1], src[4*i+0]};
            if (gotw[i] !== expw) begin
                if (ok) $display("    first mismatch at word %0d: got %08x exp %08x",
                                 i, gotw[i], expw);
                ok = 1'b0;
            end
        end
        check("card->host: 512 bytes reassemble little-endian into 128 words", ok);
        $display("    card->host  512 bytes -> 128 words   %s", ok ? "OK" : "MISMATCH");

        // ---------------------------------------------------------------------
        // 2. host -> card : words in, bytes out
        // ---------------------------------------------------------------------
        reset_dut(1'b1);
        gotb = new[nbytes];
        fork
            begin : push_words
                int unsigned pi;
                for (pi = 0; pi < nbytes/4; pi++) begin
                    while (w_full) @(negedge clk);
                    w_wdata = {src[4*pi+3], src[4*pi+2], src[4*pi+1], src[4*pi+0]};
                    w_wr = 1'b1;
                    @(negedge clk);
                    w_wr = 1'b0;
                end
            end
            begin : pop_bytes
                int unsigned qi;
                for (qi = 0; qi < nbytes; qi++) begin
                    while (b_empty) @(negedge clk);
                    gotb[qi] = b_rdata; b_rd = 1'b1;
                    @(negedge clk);
                    b_rd = 1'b0;
                end
            end
        join

        ok = 1'b1;
        for (i = 0; i < nbytes; i++)
            if (gotb[i] !== src[i]) begin
                if (ok) $display("    first mismatch at byte %0d: got %02x exp %02x",
                                 i, gotb[i], src[i]);
                ok = 1'b0;
            end
        check("host->card: 128 words serialise back to the same 512 bytes", ok);
        $display("    host->card  128 words -> 512 bytes   %s", ok ? "OK" : "MISMATCH");

        // ---------------------------------------------------------------------
        // 3. partial word: 6 bytes then flush -> two words, tail zero-filled
        // ---------------------------------------------------------------------
        reset_dut(1'b0);
        for (i = 0; i < 6; i++) begin
            b_wdata = 8'hA0 + 8'(i); b_wr = 1'b1;
            @(negedge clk);
            b_wr = 1'b0;
        end
        flush = 1'b1; @(negedge clk); flush = 1'b0;
        @(negedge clk);

        check("partial: two words present after flush", !w_empty);
        ok = (w_rdata === 32'hA3A2A1A0);
        if (!ok) $display("    word0 got %08x exp A3A2A1A0", w_rdata);
        check("partial: first word packed", ok);
        w_rd = 1'b1; @(negedge clk); w_rd = 1'b0;
        @(negedge clk);
        ok = (w_rdata === 32'h0000A5A4);
        if (!ok) $display("    word1 got %08x exp 0000A5A4", w_rdata);
        check("partial: flushed tail zero-filled", ok);
        $display("    partial flush  6 bytes -> A3A2A1A0 0000A5A4   %s",
                 ok ? "OK" : "MISMATCH");

        $display("");
        $display("=== %0d checks, %0d failures ===", checks_run, checks_fail);
        if (checks_fail == 0) $display("*** PASS ***");
        else                  $display("*** FAIL ***");
        $display("");
        $finish;
    end

    initial begin
        #20ms;
        $display("*** FAIL: timeout ***");
        $finish;
    end

endmodule : avalon_mm_sdcard_controller_fifo_tb
