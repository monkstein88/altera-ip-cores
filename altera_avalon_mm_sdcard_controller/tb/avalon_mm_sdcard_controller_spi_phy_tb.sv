`timescale 1ns/1ps

// =============================================================================
// avalon_mm_sdcard_controller_spi_phy_tb.sv
//
// Unit testbench for the shifter. Focused, and deliberately separate from the
// full-core regression in avalon_mm_sdcard_controller_tb.sv.
//
// It exists because the core's whole performance argument reduces to one
// number - SPI clocks consumed per byte, which must be exactly 8.00 - and that
// number is not observable in a functional test. A shifter that inserts one
// idle clock per byte transfers every byte correctly, passes every data
// integrity check, and quietly runs at 8/9 of the rate. Over a 512-byte block
// that is the difference between 99% and 88% of line rate.
//
// So this testbench counts edges as well as checking data, and it does so
// across every divisor the core supports - including CLKDIV=1, where two
// system clocks per SPI bit leaves the design no slack at all and where an
// earlier revision was found to advance the clock one edge before the first
// byte was loaded, shifting the bit alignment of an entire transfer.
//
// Run:  see simulation/verilator/run_sim.sh
// =============================================================================

module avalon_mm_sdcard_controller_spi_phy_tb;

    import avalon_mm_sdcard_controller_pkg::*;

    localparam int unsigned CLKDIV_WIDTH = 8;
    localparam time         CLK_PERIOD   = 10ns;      // 100 MHz system clock

    logic clk = 1'b0;
    logic reset_n = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    // ---- DUT connections ----------------------------------------------------
    logic [CLKDIV_WIDTH-1:0] clkdiv;
    logic [2:0]              sample_dly;
    logic                    run, tx_idle, idle;
    logic [7:0]              tx_data;
    logic                    tx_we, tx_ready;
    logic [7:0]              rx_data;
    logic                    rx_valid;
    logic                    sd_clk, sd_mosi, sd_miso;

    // The card model for this unit test is a wire: MISO echoes MOSI. That is
    // enough to prove byte framing, bit ordering and alignment, which is all
    // this testbench claims to prove. Protocol behaviour belongs to the card
    // model in the full regression.
    assign sd_miso = sd_mosi;

    avalon_mm_sdcard_controller_spi_phy #(
        .CLKDIV_WIDTH (CLKDIV_WIDTH)
    ) dut (
        .clk (clk), .reset_n (reset_n),
        .clkdiv (clkdiv), .sample_dly (sample_dly),
        .run (run), .tx_idle (tx_idle), .idle (idle),
        .tx_data (tx_data), .tx_we (tx_we), .tx_ready (tx_ready),
        .rx_data (rx_data), .rx_valid (rx_valid),
        .sd_clk (sd_clk), .sd_mosi (sd_mosi), .sd_miso (sd_miso)
    );

    // ---- scoreboard ---------------------------------------------------------
    int unsigned checks_run  = 0;
    int unsigned checks_fail = 0;

    task automatic check(input string what, input bit cond);
        checks_run++;
        if (!cond) begin
            checks_fail++;
            $display("  FAIL  %s", what);
        end
    endtask

    // Count SPI rising edges seen at the pin. This is the measurement the whole
    // testbench exists for.
    int unsigned sclk_rises = 0;
    logic        sclk_d = 1'b0;
    always_ff @(posedge clk) begin
        sclk_d <= sd_clk;
        if (sd_clk && !sclk_d) sclk_rises++;
    end

    // Collect received bytes.
    logic [7:0] rx_q [$];
    always_ff @(posedge clk) if (rx_valid) rx_q.push_back(rx_data);

    // -------------------------------------------------------------------------
    // Drive one stream of bytes through the shifter and report clocks per byte.
    // -------------------------------------------------------------------------
    task automatic stream(input logic [7:0] bytes [], input int unsigned div,
                          input logic [2:0] dly, output int unsigned rises);
        int unsigned i;
        begin
            // Reset between cases so each measurement starts from a known state.
            reset_n = 1'b0;
            run = 1'b0; tx_we = 1'b0; tx_idle = 1'b0; tx_data = '0;
            clkdiv = div[CLKDIV_WIDTH-1:0];
            sample_dly = dly;
            rx_q.delete();
            repeat (4) @(posedge clk);
            reset_n = 1'b1;
            repeat (2) @(posedge clk);

            sclk_rises = 0;
            i = 0;

            // Everything is driven on the negedge and sampled on the negedge,
            // so the DUT's posedge always sees stable inputs and every value
            // read back is the settled result of the previous posedge. Driving
            // and sampling on the same edge as the DUT would make tx_ready
            // ambiguous - it changes on the very edge that consumes the write.
            @(negedge clk);

            // Queue the first byte BEFORE asserting run. With tx_idle low the
            // shifter will not invent a leading 0xFF, so the byte stream on the
            // wire is exactly the byte stream requested.
            tx_data = bytes[0];
            tx_we   = 1'b1;
            @(negedge clk);            // the intervening posedge took it
            tx_we   = 1'b0;
            i       = 1;
            run     = 1'b1;

            while (i < bytes.size()) begin
                if (tx_ready) begin
                    tx_data = bytes[i];
                    tx_we   = 1'b1;
                    i++;
                end else begin
                    tx_we   = 1'b0;
                end
                @(negedge clk);
            end
            tx_we = 1'b0;

            // Hold run until the prefetch has drained AND the shifter has
            // finished the byte in flight. Dropping run at either point alone
            // would strand a queued byte, since with tx_idle low nothing loads
            // without run.
            while (!(dut.idle && !dut.hold_v)) @(negedge clk);
            run = 1'b0;
            repeat (20) @(negedge clk);

            rises = sclk_rises;
        end
    endtask

    // -------------------------------------------------------------------------
    initial begin
        logic [7:0] pat [];
        int unsigned rises;
        real         per_byte;
        int unsigned divs [4];
        logic [2:0]  dlys [2];
        int unsigned di, si, k, max_dly;
        bit          echo_ok;

        divs = '{1, 2, 4, 125};

        $display("");
        $display("=== avalon_mm_sdcard_controller_spi_phy: SPI clocks consumed per byte ===");
        $display("    exactly 8.00 is the requirement; above it is bus thrown away");
        $display("");

        pat = new[32];
        foreach (pat[k]) pat[k] = 8'hA5 ^ k[7:0];

        for (di = 0; di < 4; di++) begin

            // sample_dly is bounded by the SPI half-period, which is `clkdiv`
            // system clocks wide. Tap 0 already sits one clock past the rising
            // edge, so the capture point stays inside the bit only while
            //
            //     sample_dly <= clkdiv - 2
            //
            // Beyond that the sample lands on the NEXT bit and every byte is
            // shifted by one - which is a misconfiguration, not a defect, and
            // is rejected by the _hw.tcl validation callback. At CLKDIV=1 and 2
            // the only legal delay is therefore zero: at 50 MHz there is no
            // room to trade setup margin for hold margin, which is worth
            // knowing before wiring a card onto flying leads.
            max_dly = (divs[di] >= 3) ? ((divs[di] - 2 > 7) ? 7 : divs[di] - 2) : 0;

            // Test the two ends of the legal range: no delay, and the largest
            // delay this divisor permits.
            dlys = '{3'd0, max_dly[2:0]};

            for (si = 0; si < ((max_dly > 0) ? 2 : 1); si++) begin
                stream(pat, divs[di], dlys[si], rises);
                per_byte = real'(rises) / real'(pat.size());

                $display("    CLKDIV=%0d  sample_dly=%0d (max %0d)   %0d clocks / %0d bytes = %0.2f",
                         divs[di], dlys[si], max_dly, rises, pat.size(), per_byte);

                check($sformatf("CLKDIV=%0d dly=%0d: exactly 8 clocks/byte",
                                divs[di], dlys[si]),
                      rises == 8 * pat.size());

                // Loopback must return the transmitted stream bit-exactly. This
                // is what catches the alignment failure that a pure clock count
                // would miss.
                echo_ok = (rx_q.size() >= pat.size());
                if (echo_ok)
                    for (k = 0; k < pat.size(); k++)
                        if (rx_q[k] !== pat[k]) echo_ok = 1'b0;

                check($sformatf("CLKDIV=%0d dly=%0d: loopback bit-exact",
                                divs[di], dlys[si]), echo_ok);
            end
        end

        $display("");
        $display("=== %0d checks, %0d failures ===", checks_run, checks_fail);
        if (checks_fail == 0) $display("*** PASS ***");
        else                  $display("*** FAIL ***");
        $display("");
        $finish;
    end

    // A stuck shifter must not hang the regression.
    initial begin
        #5ms;
        $display("*** FAIL: timeout ***");
        $finish;
    end

endmodule : avalon_mm_sdcard_controller_spi_phy_tb
