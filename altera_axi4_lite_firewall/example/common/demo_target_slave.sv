`timescale 1ns/1ps

// =============================================================================
// demo_target_slave.sv
//
// The peripheral being protected. A small AXI4-Lite scratchpad - MEM_WORDS
// 32-bit registers, byte-strobed - plus a switchable fault injector, because
// a demo of a fault-isolation firewall needs something that can actually
// fail on demand.
//
// FAILURE MODES. The firewall reports these through *different* STATUS bits,
// and the difference is the whole reason both exist here:
//
//   hang=0                normal. Every access completes in a few cycles.
//
//   hang=1, hang_late=0   never raise AWREADY/ARREADY. The command is never
//                         accepted, so the firewall is left holding a VALID
//                         nobody took: STATUS.WR_CMD_STUCK / RD_CMD_STUCK.
//                         Only RECOVERY.UNBLOCK can retract that VALID.
//
//   hang=1, hang_late=1   accept the command, then go silent. The peripheral
//                         now owes a response forever: STATUS.WR_RESP_BUSY /
//                         RD_RESP_BUSY. This is the case that makes an
//                         unbounded poll of the busy bits hang.
//
// W_DEAD/R_DEAD are trap states with no exit but `resetn`. That is deliberate
// and is the point being demonstrated: nothing the firewall does can revive a
// wedged peripheral, which is why v2.0 made resetting it step 4 of a software
// sequence rather than something the core does for you.
//
// TWO RESETS, and both are needed:
//
//   resetn        the system reset, like any other component's.
//   soft_resetn   the PERIPHERAL's own reset, under software control. In a
//                 real system this is a reset bridge or a PIO bit; here the
//                 RTL demo's sequencer drives it and the Nios demo drives it
//                 from a PIO, both exactly as a driver would.
//
// They are ANDed internally. Platform Designer needs a genuine reset sink to
// tie into the system reset network, so the software-controlled one cannot
// simply BE `resetn` - that is why there are two rather than one.
//
// Either reset clears the scratchpad, which is what lets scenarios b and C
// tell "no stale write landed" (reads back 0) from "a stale write landed"
// (reads back the orphaned data) with no ambiguity.
// =============================================================================

module demo_target_slave #(
    parameter int ADDR_WIDTH = 32,
    parameter int DATA_WIDTH = 32,
    parameter int MEM_WORDS  = 16
) (
    input  logic                    clk,
    input  logic                    resetn,      // system reset
    input  logic                    soft_resetn, // peripheral reset, software-driven
    input  logic                    hang,        // stop responding
    input  logic                    hang_late,   // 0: refuse the command, 1: accept then go silent

    input  logic [ADDR_WIDTH-1:0]   s_awaddr,
    input  logic [2:0]              s_awprot,
    input  logic                    s_awvalid,
    output logic                    s_awready,
    input  logic [DATA_WIDTH-1:0]   s_wdata,
    input  logic [DATA_WIDTH/8-1:0] s_wstrb,
    input  logic                    s_wvalid,
    output logic                    s_wready,
    output logic [1:0]              s_bresp,
    output logic                    s_bvalid,
    input  logic                    s_bready,
    input  logic [ADDR_WIDTH-1:0]   s_araddr,
    input  logic [2:0]              s_arprot,
    input  logic                    s_arvalid,
    output logic                    s_arready,
    output logic [DATA_WIDTH-1:0]   s_rdata,
    output logic [1:0]              s_rresp,
    output logic                    s_rvalid,
    input  logic                    s_rready
);

    localparam int IDX_BITS = $clog2(MEM_WORDS);

    // Either reset holds the peripheral down.
    logic rst_n;
    assign rst_n = resetn && soft_resetn;

    typedef enum logic [1:0] { W_IDLE, W_EXEC, W_RESP, W_DEAD } w_state_e;
    typedef enum logic [1:0] { R_IDLE, R_EXEC, R_RESP, R_DEAD } r_state_e;

    // Refuse to accept a command at all. The "accept then go silent" mode
    // still takes the command, so it is not gated here.
    logic refuse_cmd;
    assign refuse_cmd = hang && !hang_late;

    logic [DATA_WIDTH-1:0] mem [MEM_WORDS];

    // The peripheral decodes only the low address bits and ignores the rest.
    // Every address the firewall forwards therefore lands somewhere valid -
    // which is the point: in this demo the firewall is the *only* thing that
    // ever says no, so a DECERR is unambiguously the firewall's doing and not
    // the peripheral running out of decode.
    function automatic logic [IDX_BITS-1:0] word_index(input logic [ADDR_WIDTH-1:0] a);
        return a[IDX_BITS+1:2];
    endfunction

    // ------------------------------------------------------------------
    // Write channel
    // ------------------------------------------------------------------
    w_state_e              w_state;
    logic [ADDR_WIDTH-1:0] w_addr_r;
    logic [DATA_WIDTH-1:0] w_data_r;
    logic [DATA_WIDTH/8-1:0] w_strb_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            w_state   <= W_IDLE;
            s_awready <= 1'b0;
            s_wready  <= 1'b0;
            s_bvalid  <= 1'b0;
            s_bresp   <= 2'b00;
            w_addr_r  <= '0;
            w_data_r  <= '0;
            w_strb_r  <= '0;
            for (int i = 0; i < MEM_WORDS; i++) mem[i] <= '0;
        end else begin
            s_awready <= 1'b0;
            s_wready  <= 1'b0;

            case (w_state)
                W_IDLE: begin
                    if (!refuse_cmd && s_awvalid && s_wvalid && !s_bvalid) begin
                        s_awready <= 1'b1;
                        s_wready  <= 1'b1;
                        w_addr_r  <= s_awaddr;
                        w_data_r  <= s_wdata;
                        w_strb_r  <= s_wstrb;
                        w_state   <= W_EXEC;
                    end
                end

                W_EXEC: begin
                    if (hang && hang_late) begin
                        w_state <= W_DEAD;      // accepted, and now owes a response forever
                    end else begin
                        for (int b = 0; b < DATA_WIDTH/8; b++)
                            if (w_strb_r[b])
                                mem[word_index(w_addr_r)][b*8 +: 8] <= w_data_r[b*8 +: 8];
                        s_bresp <= 2'b00;       // OKAY
                        w_state <= W_RESP;
                    end
                end

                W_RESP: begin
                    s_bvalid <= 1'b1;
                    if (s_bvalid && s_bready) begin
                        s_bvalid <= 1'b0;
                        w_state  <= W_IDLE;
                    end
                end

                W_DEAD: ;   // no exit but resetn

                default: w_state <= W_IDLE;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Read channel
    // ------------------------------------------------------------------
    r_state_e              r_state;
    logic [ADDR_WIDTH-1:0] r_addr_r;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            r_state   <= R_IDLE;
            s_arready <= 1'b0;
            s_rvalid  <= 1'b0;
            s_rresp   <= 2'b00;
            s_rdata   <= '0;
            r_addr_r  <= '0;
        end else begin
            s_arready <= 1'b0;

            case (r_state)
                R_IDLE: begin
                    if (!refuse_cmd && s_arvalid && !s_rvalid) begin
                        s_arready <= 1'b1;
                        r_addr_r  <= s_araddr;
                        r_state   <= R_EXEC;
                    end
                end

                R_EXEC: begin
                    if (hang && hang_late) begin
                        r_state <= R_DEAD;
                    end else begin
                        s_rdata <= mem[word_index(r_addr_r)];
                        s_rresp <= 2'b00;       // OKAY
                        r_state <= R_RESP;
                    end
                end

                R_RESP: begin
                    s_rvalid <= 1'b1;
                    if (s_rvalid && s_rready) begin
                        s_rvalid <= 1'b0;
                        r_state  <= R_IDLE;
                    end
                end

                R_DEAD: ;

                default: r_state <= R_IDLE;
            endcase
        end
    end

    // AWPROT/ARPROT are accepted and ignored - this peripheral has no
    // privilege model. The firewall forwards them unchanged; per-rule PROT
    // qualification is on the core's roadmap, not implemented here.
    logic unused_prot;
    assign unused_prot = ^{s_awprot, s_arprot};

endmodule
