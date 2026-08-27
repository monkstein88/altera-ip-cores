# =============================================================================
# run_sim.tcl - board-level simulation of the SDRAM demo under Questa/ModelSim.
#
#   cd simulation/questa && vsim -c -do run_sim.tcl
#
# Needs two generated things, neither of which is committed:
#
#   ../../qsys/sdram_sys/    the Platform Designer system  (../../build.sh qsys)
#   ../.gen/sdram_mem_model.v   the SDRAM memory model     (../gen_mem_model.sh)
#
# Both are Intel's output and are regenerated from your own Quartus
# installation rather than redistributed here - see ../../../../NOTICE.
# This script runs both steps for you if the files are missing.
# =============================================================================

set EX   [file normalize [file join [pwd] .. ..]]
set GEN  [file join $EX simulation .gen]
set QSYS [file join $EX qsys sdram_sys synthesis]

if {![file exists [file join $QSYS sdram_sys.v]]} {
    puts "=== generating the Platform Designer system ==="
    if {[catch {exec [file join $EX build.sh] qsys} e]} { puts $e }
}
if {![file exists [file join $GEN sdram_mem_model.v]]} {
    puts "=== generating the SDRAM memory model ==="
    if {[catch {exec [file join $EX simulation gen_mem_model.sh]} e]} { puts $e }
}

foreach f [list [file join $QSYS sdram_sys.v] \
                [file join $QSYS submodules sdram_sys_sdram.v] \
                [file join $GEN sdram_mem_model.v]] {
    if {![file exists $f]} {
        puts "ERROR: missing $f"
        puts "       Run ../../build.sh qsys and ../gen_mem_model.sh first."
        quit -code 1
    }
}

if {[file exists work]} { vdel -all }
vlib work

# The generated Intel sources are plain Verilog; ours are SystemVerilog.
vlog -quiet          [file join $QSYS sdram_sys.v]
vlog -quiet          [file join $QSYS submodules sdram_sys_sdram.v]
vlog -quiet          [file join $GEN sdram_mem_model.v]
vlog -quiet -sv      [file join $EX rtl demo_sdram_seq.sv]
vlog -quiet -sv      [file join $EX rtl demo_avl_mm_master.sv]
vlog -quiet -sv      [file join $EX tb de10_lite_avl_mm_sdram_demo_tb.sv]

# +acc is required: the testbench reads the memory model's array directly and
# forces waitrequest to exercise the watchdog.
vsim -c -voptargs="+acc" work.de10_lite_avl_mm_sdram_demo_tb

# `onfinish stop` must come AFTER elaboration, otherwise $finish takes the
# whole simulator down before the summary below can be read.
onfinish stop
run -all

set failed 1
if {[catch {examine -radix dec sim:/de10_lite_avl_mm_sdram_demo_tb/checks_failed} nf] == 0} {
    if {[string trim $nf] == 0} { set failed 0 }
}
if {$failed} {
    puts "\nRESULT: FAILED"
    quit -code 1
}
puts "\nRESULT: PASSED"
quit -code 0
