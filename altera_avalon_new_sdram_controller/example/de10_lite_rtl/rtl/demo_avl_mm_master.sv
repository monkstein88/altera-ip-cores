`timescale 1ns/1ps

// =============================================================================
// demo_avl_mm_master.sv
//
// A minimal Avalon-MM master for the SDRAM controller's `s1` port. It is a
// protocol shim and nothing more: it owns no addresses, generates no patterns
// and makes no decisions. The sequencer above it does all of that.
//
// -----------------------------------------------------------------------------
// WHAT THE SLAVE ACTUALLY LOOKS LIKE
// -----------------------------------------------------------------------------
// The SDRAM controller's slave is an old-style Avalon port and three of its
// signals are ACTIVE LOW - `read_n`, `write_n` and `byteenable_n`. Qsys hides
// that when it wires the interconnect for you; here the connection is made by
// hand, so this module does the inversion in one place and presents an
// ordinary active-high command interface upwards.
//
// Two things about the controller are worth stating, because both were read
// out of its generated RTL rather than assumed:
//
//   1. `chipselect` DOES NOT QUALIFY THE TRANSACTION. The controller's command
//      FIFO is written on `(~az_wr_n | ~az_rd_n) & !za_waitrequest` - the chip
//      select is not in that term at all. Leaving read_n/write_n asserted
//      while deasserting chipselect would still issue the command. This module
//      therefore drives read_n/write_n as the real qualifiers and holds
//      chipselect alongside them for correctness on any other slave.
//
//   2. READ DATA CANNOT BE STALLED. `waitrequest` is wired straight to the
//      command FIFO's `full` flag, so it is backpressure on the COMMAND side
//      only. Returned read data arrives on `readdatavalid` a fixed number of
//      cycles after the memory is read, with nothing on the return path that
//      can be held off. Whatever consumes rsp_valid must accept it in the
//      cycle it appears - it will not be offered twice.
//
// Because waitrequest is the FIFO-full flag, respecting it is also the only
// outstanding-read limit this master needs; there is no separate credit to
// track.
//
// The command interface is ordinary ready/valid: `cmd_valid` must not depend
// combinationally on `cmd_ready`, which is why the sequencer drives it from a
// register.
// =============================================================================

module demo_avl_mm_master #(
    parameter int ADDR_WIDTH = 25,
    parameter int DATA_WIDTH = 16
) (
    input  logic                    clk,
    input  logic                    resetn,

    // ---- command in (active high, ordinary ready/valid) ------------------
    input  logic                    cmd_valid,
    output logic                    cmd_ready,
    input  logic                    cmd_write,      // 1 = write, 0 = read
    input  logic [ADDR_WIDTH-1:0]   cmd_addr,       // WORD address
    input  logic [DATA_WIDTH-1:0]   cmd_wdata,
    input  logic [DATA_WIDTH/8-1:0] cmd_be,         // active HIGH

    // ---- read response out (cannot be stalled - see above) ---------------
    output logic                    rsp_valid,
    output logic [DATA_WIDTH-1:0]   rsp_data,

    // ---- Avalon-MM master -> sdram_sys s1 --------------------------------
    output logic [ADDR_WIDTH-1:0]   avm_address,
    output logic [DATA_WIDTH/8-1:0] avm_byteenable_n,
    output logic                    avm_chipselect,
    output logic [DATA_WIDTH-1:0]   avm_writedata,
    output logic                    avm_read_n,
    output logic                    avm_write_n,
    input  logic [DATA_WIDTH-1:0]   avm_readdata,
    input  logic                    avm_readdatavalid,
    input  logic                    avm_waitrequest
);

    // The command is held on the bus until the slave takes it. `waitrequest`
    // is the whole of the flow control.
    assign cmd_ready        = !avm_waitrequest;

    assign avm_address      = cmd_addr;
    assign avm_writedata    = cmd_wdata;
    assign avm_byteenable_n = ~cmd_be;                      // active low
    assign avm_chipselect   = resetn && cmd_valid;
    assign avm_write_n      = !(resetn && cmd_valid &&  cmd_write);
    assign avm_read_n       = !(resetn && cmd_valid && !cmd_write);

    assign rsp_valid        = avm_readdatavalid;
    assign rsp_data         = avm_readdata;

endmodule
