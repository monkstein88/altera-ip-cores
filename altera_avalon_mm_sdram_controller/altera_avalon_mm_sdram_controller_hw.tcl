package require -exact qsys 14.0

# =============================================================================
# altera_avalon_mm_sdram_controller_hw.tcl
#
# Platform Designer component for avalon_mm_sdram_controller - the SDR SDRAM
# controller with one open row per bank.
#
# It presents the same interfaces as the core it replaces
# (altera_avalon_new_sdram_controller): a clock sink, a reset sink, a
# word-addressed Avalon-MM memory slave named s1 carrying the legacy
# az_/za_ signals, and a conduit named wire carrying the SDRAM pins. Swapping
# one component for the other in an existing system therefore leaves every
# connection and every address assignment alone.
#
# WHERE THE TIMING NUMBERS LIVE
# -----------------------------
# In the HDL, and only in the HDL.
#
# In the HDL, and only in the HDL - but they cannot travel as floats.
#
# Platform Designer emits a FLOAT parameter into the generated Verilog as a
# QUOTED STRING: `.T_RC_NS("60.0")`. Assigned to a `parameter real`, that string
# is its ASCII bytes read as a number - 909127216.0 - so a 60 ns tRC silently
# becomes 90 million cycles. Measured, not assumed; see the project README.
# It is also why the core this replaces declares every one of its nanosecond
# parameters HDL_PARAMETER {0}.
#
# So the GUI asks for nanoseconds, and `elaborate` scales each one to an INTEGER
# number of picoseconds for the HDL. That scaling is a multiply by 1000 and a
# round - exact, and nothing like a ceiling division. The ceiling division that
# actually matters, nanoseconds to clock cycles, stays in the HDL where it
# exists exactly once. Two copies of it is how this project shipped the same
# rounding bug twice.
#
# `validate` below recomputes the cycle counts purely to REPORT them, and says
# so. Nothing it computes reaches the hardware.
#
# The clock frequency is not a parameter at all - it comes from whatever clock
# source you connect, via SYSTEM_INFO. A controller configured for 100 MHz and
# clocked at 143 was always a possible mistake with the old core; here it
# cannot be made.
#
# DEVICE PROFILES
# ---------------
# Supplied as Platform Designer presets in
# altera_avalon_mm_sdram_controller.qprs, which is the mechanism Intel uses for
# the same job on the same kind of component. Adding a part means adding a
# preset, not editing this file.
#
# hw.tcl syntax has drifted across Quartus releases. This file is written for
# and tested against Quartus 18.1 Standard. If a future release rejects
# something, Component Editor -> "Save / Export as hw.tcl Component" will
# produce a file guaranteed correct for that release.
# =============================================================================

set_module_property NAME         altera_avalon_mm_sdram_controller
set_module_property DISPLAY_NAME "Avalon-MM SDRAM Controller (per-bank rows)"
set_module_property DESCRIPTION  "SDR SDRAM controller with one open row per bank, a read/write turnaround that does not close the row, and look-ahead row activation. Drop-in for the SDRAM Controller Intel FPGA IP: same s1 slave, same wire conduit, same default address map."
set_module_property VERSION      1.0
set_module_property GROUP        "Memory Interfaces and Controllers/Custom"
set_module_property AUTHOR       "monkstein88"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE     false
set_module_property ELABORATION_CALLBACK elaborate
set_module_property VALIDATION_CALLBACK  validate

# -----------------------------------------------------------------------
# Files
#
# TYPE must be SYSTEM_VERILOG, not VERILOG: the RTL uses `logic`,
# always_ff/always_comb, packed structs, enums and $ceil. Declared as VERILOG,
# Quartus analyses it with the Verilog-2001 parser and fails on the first
# `logic` declaration.
# -----------------------------------------------------------------------
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH generate_synth_files ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL avalon_mm_sdram_controller
add_fileset_file avalon_mm_sdram_controller.sv SYSTEM_VERILOG \
    PATH rtl/avalon_mm_sdram_controller.sv TOP_LEVEL_FILE

add_fileset SIM_VERILOG SIM_VERILOG generate_sim_files ""
set_fileset_property SIM_VERILOG TOP_LEVEL avalon_mm_sdram_controller
add_fileset_file avalon_mm_sdram_controller.sv SYSTEM_VERILOG \
    PATH rtl/avalon_mm_sdram_controller.sv TOP_LEVEL_FILE

proc generate_synth_files {entity_name} { }
proc generate_sim_files   {entity_name} { }

# =======================================================================
# Parameters
# =======================================================================

# ---- device geometry --------------------------------------------------
add_parameter DATA_BITS INTEGER 16
set_parameter_property DATA_BITS DISPLAY_NAME "Data width"
set_parameter_property DATA_BITS UNITS bits
set_parameter_property DATA_BITS ALLOWED_RANGES {8 16 32}
set_parameter_property DATA_BITS HDL_PARAMETER true
set_parameter_property DATA_BITS GROUP "Memory device geometry"
set_parameter_property DATA_BITS DESCRIPTION {Width of the SDRAM data bus. One DQM bit per byte lane.}

add_parameter ROW_BITS INTEGER 13
set_parameter_property ROW_BITS DISPLAY_NAME "Row address width"
set_parameter_property ROW_BITS UNITS bits
set_parameter_property ROW_BITS ALLOWED_RANGES {10:15}
set_parameter_property ROW_BITS HDL_PARAMETER true
set_parameter_property ROW_BITS GROUP "Memory device geometry"

add_parameter COL_BITS INTEGER 10
set_parameter_property COL_BITS DISPLAY_NAME "Column address width"
set_parameter_property COL_BITS UNITS bits
set_parameter_property COL_BITS ALLOWED_RANGES {8:11}
set_parameter_property COL_BITS HDL_PARAMETER true
set_parameter_property COL_BITS GROUP "Memory device geometry"
set_parameter_property COL_BITS DESCRIPTION {Column bit 10 steps over address pin A10, which is the auto-precharge flag. 11 is the widest this encoding supports.}

add_parameter BANK_BITS INTEGER 2
set_parameter_property BANK_BITS DISPLAY_NAME "Bank address width"
set_parameter_property BANK_BITS UNITS bits
set_parameter_property BANK_BITS ALLOWED_RANGES {1 2 3}
set_parameter_property BANK_BITS HDL_PARAMETER true
set_parameter_property BANK_BITS GROUP "Memory device geometry"
set_parameter_property BANK_BITS DESCRIPTION {The controller tracks one open row per bank, so this also sets how many rows can be open at once - which is where this core's advantage over a single-row controller comes from.}

add_parameter SA_BITS INTEGER 13
set_parameter_property SA_BITS DISPLAY_NAME "Address pins on the device"
set_parameter_property SA_BITS UNITS bits
set_parameter_property SA_BITS ALLOWED_RANGES {11:15}
set_parameter_property SA_BITS HDL_PARAMETER true
set_parameter_property SA_BITS GROUP "Memory device geometry"
set_parameter_property SA_BITS DESCRIPTION {Width of the A[] bus. Must be at least the row width, and at least 11 because A10 is the precharge-all flag.}

# ---- device timing, nanoseconds --------------------------------------
# HDL_PARAMETER true on every one of these: the ns value goes to the HDL and
# the HDL converts it. See the header.
add_parameter T_RC_NS FLOAT 60.0
set_parameter_property T_RC_NS DISPLAY_NAME "tRC - ACTIVATE to ACTIVATE, same bank"
set_parameter_property T_RC_NS UNITS nanoseconds
set_parameter_property T_RC_NS ALLOWED_RANGES {1.0:1000.0}
set_parameter_property T_RC_NS HDL_PARAMETER false
set_parameter_property T_RC_NS GROUP "Memory device timing"

add_parameter T_RAS_NS FLOAT 37.0
set_parameter_property T_RAS_NS DISPLAY_NAME "tRAS - ACTIVATE to PRECHARGE, same bank"
set_parameter_property T_RAS_NS UNITS nanoseconds
set_parameter_property T_RAS_NS ALLOWED_RANGES {1.0:1000.0}
set_parameter_property T_RAS_NS HDL_PARAMETER false
set_parameter_property T_RAS_NS GROUP "Memory device timing"
set_parameter_property T_RAS_NS DESCRIPTION {The minimum a row must stay open. A single-open-row controller never needs this, because it never closes a row sooner than a full cycle allows. This one does.}

add_parameter T_RP_NS FLOAT 15.0
set_parameter_property T_RP_NS DISPLAY_NAME "tRP - PRECHARGE to ACTIVATE, same bank"
set_parameter_property T_RP_NS UNITS nanoseconds
set_parameter_property T_RP_NS ALLOWED_RANGES {1.0:1000.0}
set_parameter_property T_RP_NS HDL_PARAMETER false
set_parameter_property T_RP_NS GROUP "Memory device timing"

add_parameter T_RCD_NS FLOAT 15.0
set_parameter_property T_RCD_NS DISPLAY_NAME "tRCD - ACTIVATE to READ or WRITE"
set_parameter_property T_RCD_NS UNITS nanoseconds
set_parameter_property T_RCD_NS ALLOWED_RANGES {1.0:1000.0}
set_parameter_property T_RCD_NS HDL_PARAMETER false
set_parameter_property T_RCD_NS GROUP "Memory device timing"

add_parameter T_RRD_NS FLOAT 14.0
set_parameter_property T_RRD_NS DISPLAY_NAME "tRRD - ACTIVATE to ACTIVATE, different bank"
set_parameter_property T_RRD_NS UNITS nanoseconds
set_parameter_property T_RRD_NS ALLOWED_RANGES {1.0:1000.0}
set_parameter_property T_RRD_NS HDL_PARAMETER false
set_parameter_property T_RRD_NS GROUP "Memory device timing"
set_parameter_property T_RRD_NS DESCRIPTION {How soon a second bank may be opened after the first. Only a controller that opens more than one bank needs this - which is why the core this replaces does not have it.}

add_parameter T_WR_NS FLOAT 14.0
set_parameter_property T_WR_NS DISPLAY_NAME "tWR - write recovery, last write data to PRECHARGE"
set_parameter_property T_WR_NS UNITS nanoseconds
set_parameter_property T_WR_NS ALLOWED_RANGES {1.0:1000.0}
set_parameter_property T_WR_NS HDL_PARAMETER false
set_parameter_property T_WR_NS GROUP "Memory device timing"

add_parameter T_MRD_NS FLOAT 14.0
set_parameter_property T_MRD_NS DISPLAY_NAME "tMRD - LOAD MODE REGISTER to next command"
set_parameter_property T_MRD_NS UNITS nanoseconds
set_parameter_property T_MRD_NS ALLOWED_RANGES {1.0:1000.0}
set_parameter_property T_MRD_NS HDL_PARAMETER false
set_parameter_property T_MRD_NS GROUP "Memory device timing"
set_parameter_property T_MRD_NS DESCRIPTION {Often quoted in clocks rather than nanoseconds. Two clocks at the slowest speed the part is rated for is a safe conversion.}

add_parameter T_RFC_NS FLOAT 60.0
set_parameter_property T_RFC_NS DISPLAY_NAME "tRFC - AUTO REFRESH to next ACTIVATE or REFRESH"
set_parameter_property T_RFC_NS UNITS nanoseconds
set_parameter_property T_RFC_NS ALLOWED_RANGES {1.0:1000.0}
set_parameter_property T_RFC_NS HDL_PARAMETER false
set_parameter_property T_RFC_NS GROUP "Memory device timing"

add_parameter CAS_LAT INTEGER 3
set_parameter_property CAS_LAT DISPLAY_NAME "CAS latency"
set_parameter_property CAS_LAT UNITS cycles
set_parameter_property CAS_LAT ALLOWED_RANGES {2 3}
set_parameter_property CAS_LAT HDL_PARAMETER true
set_parameter_property CAS_LAT GROUP "Memory device timing"
set_parameter_property CAS_LAT DESCRIPTION {Written to the mode register at initialisation and used to time read capture. Also sets the read-to-write bus turnaround, which is CAS+1 cycles.}

# ---- initialisation ---------------------------------------------------
add_parameter T_INIT_US INTEGER 100
set_parameter_property T_INIT_US DISPLAY_NAME "Power-up delay before the first command"
set_parameter_property T_INIT_US UNITS microseconds
set_parameter_property T_INIT_US ALLOWED_RANGES {1:10000}
set_parameter_property T_INIT_US HDL_PARAMETER true
set_parameter_property T_INIT_US GROUP "Initialisation"

add_parameter INIT_REFS INTEGER 8
set_parameter_property INIT_REFS DISPLAY_NAME "Refresh commands during initialisation"
set_parameter_property INIT_REFS ALLOWED_RANGES {2:15}
set_parameter_property INIT_REFS HDL_PARAMETER true
set_parameter_property INIT_REFS GROUP "Initialisation"
set_parameter_property INIT_REFS DESCRIPTION {JEDEC asks for at least 8. Some vendor sequences use 2. It costs a few microseconds once, so there is no reason to economise.}

# ---- refresh ----------------------------------------------------------
add_parameter REF_ROWS INTEGER 8192
set_parameter_property REF_ROWS DISPLAY_NAME "Rows to refresh per refresh period"
set_parameter_property REF_ROWS ALLOWED_RANGES {512:32768}
set_parameter_property REF_ROWS HDL_PARAMETER true
set_parameter_property REF_ROWS GROUP "Refresh"
set_parameter_property REF_ROWS DESCRIPTION {The device's refresh count - 4096, 8192 or 16384 on most parts. Together with the refresh period this sets the average interval between AUTO REFRESH commands.}

add_parameter REF_PERIOD_MS INTEGER 64
set_parameter_property REF_PERIOD_MS DISPLAY_NAME "Refresh period"
set_parameter_property REF_PERIOD_MS UNITS milliseconds
set_parameter_property REF_PERIOD_MS ALLOWED_RANGES {1:1000}
set_parameter_property REF_PERIOD_MS HDL_PARAMETER true
set_parameter_property REF_PERIOD_MS GROUP "Refresh"
set_parameter_property REF_PERIOD_MS DESCRIPTION {Halve this if the part is run above its commercial temperature range - most datasheets require it.}

add_parameter REF_MAX_PEND INTEGER 8
set_parameter_property REF_MAX_PEND DISPLAY_NAME "Refreshes that may be postponed"
set_parameter_property REF_MAX_PEND ALLOWED_RANGES {1:8}
set_parameter_property REF_MAX_PEND HDL_PARAMETER true
set_parameter_property REF_MAX_PEND GROUP "Refresh"
set_parameter_property REF_MAX_PEND DESCRIPTION {A refresh taken in an idle cycle is free; one taken mid-burst costs tRP + tRFC + tRCD. Postponing lets a burst finish. JEDEC permits up to 8. Set to 1 for the old behaviour of refreshing the moment the timer expires.}

# ---- controller options ----------------------------------------------
add_parameter ADDR_MAP INTEGER 0
set_parameter_property ADDR_MAP DISPLAY_NAME "Address map"
set_parameter_property ADDR_MAP ALLOWED_RANGES {0:Compatible 1:Conventional}
set_parameter_property ADDR_MAP HDL_PARAMETER true
set_parameter_property ADDR_MAP GROUP "Controller"
set_parameter_property ADDR_MAP DESCRIPTION {Compatible places bank[0] directly above the column and the remaining bank bits at the top, which is what the Intel core does. Keep it when replacing that core in an existing system: any other choice moves every address. It also interleaves banks every column-length, which suits streaming.}

add_parameter FIFO_DEPTH INTEGER 8
set_parameter_property FIFO_DEPTH DISPLAY_NAME "Command buffer depth"
set_parameter_property FIFO_DEPTH ALLOWED_RANGES {2 4 8 16 32}
set_parameter_property FIFO_DEPTH HDL_PARAMETER true
set_parameter_property FIFO_DEPTH GROUP "Controller"
set_parameter_property FIFO_DEPTH DESCRIPTION {Buffered commands. Also what look-ahead looks into: with a depth of 2 there is one command to look at, which is all look-ahead needs. Deeper mainly absorbs bursts of master traffic.}

add_parameter LOOKAHEAD INTEGER 1
set_parameter_property LOOKAHEAD DISPLAY_NAME "Look-ahead row activation"
set_parameter_property LOOKAHEAD ALLOWED_RANGES {0:Off 1:On}
set_parameter_property LOOKAHEAD HDL_PARAMETER true
set_parameter_property LOOKAHEAD GROUP "Controller"
set_parameter_property LOOKAHEAD DESCRIPTION {Open or close the next access's row while the current one is still being served. Worth roughly 1.7x on scattered traffic and nothing at all on traffic that does not change rows. Purely an optimisation - the controller is correct with it off.}

add_parameter RD_EXTRA_LAT INTEGER 0
set_parameter_property RD_EXTRA_LAT DISPLAY_NAME "Extra read capture delay"
set_parameter_property RD_EXTRA_LAT UNITS cycles
set_parameter_property RD_EXTRA_LAT ALLOWED_RANGES {0:3}
set_parameter_property RD_EXTRA_LAT HDL_PARAMETER true
set_parameter_property RD_EXTRA_LAT GROUP "Controller"
set_parameter_property RD_EXTRA_LAT DESCRIPTION {Added to the CAS latency when capturing read data. Zero is correct for a direct connection. Increase only if the DQ return path is registered - an input register in the pin, or a resynchroniser - and read data lands a cycle late.}


# ---- picoseconds to the HDL, derived from the nanoseconds above ----
# Hidden because they are not a decision anyone makes; they exist because a
# float cannot cross into the generated Verilog intact.
add_parameter T_RC_PS INTEGER 0
set_parameter_property T_RC_PS HDL_PARAMETER true
set_parameter_property T_RC_PS DERIVED true
set_parameter_property T_RC_PS VISIBLE false
add_parameter T_RAS_PS INTEGER 0
set_parameter_property T_RAS_PS HDL_PARAMETER true
set_parameter_property T_RAS_PS DERIVED true
set_parameter_property T_RAS_PS VISIBLE false
add_parameter T_RP_PS INTEGER 0
set_parameter_property T_RP_PS HDL_PARAMETER true
set_parameter_property T_RP_PS DERIVED true
set_parameter_property T_RP_PS VISIBLE false
add_parameter T_RCD_PS INTEGER 0
set_parameter_property T_RCD_PS HDL_PARAMETER true
set_parameter_property T_RCD_PS DERIVED true
set_parameter_property T_RCD_PS VISIBLE false
add_parameter T_RRD_PS INTEGER 0
set_parameter_property T_RRD_PS HDL_PARAMETER true
set_parameter_property T_RRD_PS DERIVED true
set_parameter_property T_RRD_PS VISIBLE false
add_parameter T_WR_PS INTEGER 0
set_parameter_property T_WR_PS HDL_PARAMETER true
set_parameter_property T_WR_PS DERIVED true
set_parameter_property T_WR_PS VISIBLE false
add_parameter T_MRD_PS INTEGER 0
set_parameter_property T_MRD_PS HDL_PARAMETER true
set_parameter_property T_MRD_PS DERIVED true
set_parameter_property T_MRD_PS VISIBLE false
add_parameter T_RFC_PS INTEGER 0
set_parameter_property T_RFC_PS HDL_PARAMETER true
set_parameter_property T_RFC_PS DERIVED true
set_parameter_property T_RFC_PS VISIBLE false
# ---- derived / hidden -------------------------------------------------
# The clock rate is taken from whatever clock source is connected, not typed
# in. This is the one number that used to be possible to get wrong by hand.
add_parameter CLK_RATE_HZ LONG 0
set_parameter_property CLK_RATE_HZ SYSTEM_INFO {CLOCK_RATE clk}
set_parameter_property CLK_RATE_HZ HDL_PARAMETER false
set_parameter_property CLK_RATE_HZ VISIBLE false
set_parameter_property CLK_RATE_HZ DERIVED true

add_parameter CLK_KHZ INTEGER 100000
set_parameter_property CLK_KHZ DISPLAY_NAME "Controller clock"
set_parameter_property CLK_KHZ UNITS kilohertz
set_parameter_property CLK_KHZ HDL_PARAMETER true
set_parameter_property CLK_KHZ DERIVED true
set_parameter_property CLK_KHZ GROUP "Derived"
set_parameter_property CLK_KHZ DESCRIPTION {Taken from the connected clock source. Every nanosecond figure above is converted to cycles against this, inside the HDL.}

add_parameter ADDR_W INTEGER 25
set_parameter_property ADDR_W DISPLAY_NAME "Avalon word address width"
set_parameter_property ADDR_W UNITS bits
set_parameter_property ADDR_W HDL_PARAMETER true
set_parameter_property ADDR_W DERIVED true
set_parameter_property ADDR_W GROUP "Derived"
set_parameter_property ADDR_W DESCRIPTION {Row + column + bank. The s1 slave is word-addressed, so this is a word address, matching the core this replaces.}

# =======================================================================
# Interfaces
# =======================================================================
add_interface clk clock sink
set_interface_property clk clockRate 0
add_interface_port clk clk clk Input 1

add_interface reset reset sink
set_interface_property reset associatedClock clk
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset_n reset_n Input 1

# -----------------------------------------------------------------------
# s1 - the memory slave
#
# Signal roles, address units and isMemoryDevice all match the core this
# replaces, so a system built against that one connects to this one unchanged.
#
# readLatency 0 with readdatavalid present means variable latency: the number
# of cycles a read takes depends on whether its row is already open, which is
# the entire point of the design and cannot be expressed as a fixed latency.
# -----------------------------------------------------------------------
add_interface s1 avalon slave
set_interface_property s1 associatedClock clk
set_interface_property s1 associatedReset reset
set_interface_property s1 addressUnits WORDS
set_interface_property s1 burstcountUnits WORDS
set_interface_property s1 bitsPerSymbol 8
set_interface_property s1 isMemoryDevice true
set_interface_property s1 isNonVolatileStorage false
set_interface_property s1 isFlash false
set_interface_property s1 isBigEndian false
set_interface_property s1 addressAlignment DYNAMIC
set_interface_property s1 holdTime 0
set_interface_property s1 setupTime 0
set_interface_property s1 readLatency 0
set_interface_property s1 readWaitTime 0
set_interface_property s1 writeWaitTime 0
set_interface_property s1 timingUnits Cycles
set_interface_property s1 linewrapBursts false
set_interface_property s1 burstOnBurstBoundariesOnly false
set_interface_property s1 constantBurstBehavior false
set_interface_property s1 alwaysBurstMaxBurst false
set_interface_property s1 wellBehavedWaitrequest false
set_interface_property s1 minimumUninterruptedRunLength 1

add_interface_port s1 az_addr        address       Input  ADDR_W
add_interface_port s1 az_be_n        byteenable_n  Input  DATA_BITS/8
add_interface_port s1 az_cs          chipselect    Input  1
add_interface_port s1 az_data        writedata     Input  DATA_BITS
add_interface_port s1 az_rd_n        read_n        Input  1
add_interface_port s1 az_wr_n        write_n       Input  1
add_interface_port s1 za_data        readdata      Output DATA_BITS
add_interface_port s1 za_valid       readdatavalid Output 1
add_interface_port s1 za_waitrequest waitrequest   Output 1

# -----------------------------------------------------------------------
# wire - the SDRAM pins, exported to the top level
# -----------------------------------------------------------------------
add_interface wire conduit end
set_interface_property wire associatedClock clk
set_interface_property wire associatedReset reset

add_interface_port wire zs_addr  export Output SA_BITS
add_interface_port wire zs_ba    export Output BANK_BITS
add_interface_port wire zs_cas_n export Output 1
add_interface_port wire zs_cke   export Output 1
add_interface_port wire zs_cs_n  export Output 1
add_interface_port wire zs_dq    export Bidir  DATA_BITS
add_interface_port wire zs_dqm   export Output DATA_BITS/8
add_interface_port wire zs_ras_n export Output 1
add_interface_port wire zs_we_n  export Output 1

# =======================================================================
# Elaboration - the derived parameters, and what the slave advertises
# =======================================================================
proc elaborate {} {
    set row  [get_parameter_value ROW_BITS]
    set col  [get_parameter_value COL_BITS]
    set bank [get_parameter_value BANK_BITS]
    set hz   [get_parameter_value CLK_RATE_HZ]
    set cas  [get_parameter_value CAS_LAT]
    set fifo [get_parameter_value FIFO_DEPTH]

    set_parameter_value ADDR_W [expr {$row + $col + $bank}]

    # Round to the nearest kHz. A 50 MHz clock is 50000000 Hz exactly; a PLL
    # output of 143.18 MHz is not, and the kHz figure is what the HDL divides
    # nanoseconds against.
    if {$hz > 0} {
        set_parameter_value CLK_KHZ [expr {round(double($hz) / 1000.0)}]
    }

    # Nanoseconds -> picoseconds for the HDL. A multiply and a round; the
    # ceiling division from time to cycles is the HDL's job and stays there.
    foreach {ps ns} {T_RC_PS T_RC_NS  T_RAS_PS T_RAS_NS  T_RP_PS T_RP_NS \
                     T_RCD_PS T_RCD_NS  T_RRD_PS T_RRD_NS  T_WR_PS T_WR_NS \
                     T_MRD_PS T_MRD_NS  T_RFC_PS T_RFC_NS} {
        set_parameter_value $ps [expr {round([get_parameter_value $ns] * 1000.0)}]
    }
    # How many reads the master may have outstanding: everything the command
    # buffer holds, plus everything already in the device's CAS pipeline. The
    # slave stops accepting beyond that, so advertising more would only invite
    # the interconnect to pipeline deeper than the core can absorb.
    set_interface_property s1 maximumPendingReadTransactions [expr {$fifo + $cas + 1}]
}

# =======================================================================
# Validation
#
# Every check here is a configuration that elaborates, compiles, and is wrong
# on hardware - most of them intermittently, at temperature, months later,
# which is the failure mode this whole project exists to avoid.
# =======================================================================

# Ceiling of ns at the given kHz, in cycles, never below one.
#
# This duplicates the HDL's cyc() only to REPORT numbers to the user. Nothing
# it returns is passed to the hardware - the HDL is given nanoseconds and does
# its own conversion. If these two ever disagree, the HDL is what is built.
proc cyc_of {ns khz} {
    if {$khz <= 0} { return 0 }
    set c [expr {int(ceil((double($ns) * double($khz)) / 1000000.0 - 1.0e-9))}]
    if {$c < 1} { set c 1 }
    return $c
}

# Same, with a floor in CLOCKS. tRRD, tDPL(tWR) and tMRD are specified by the
# datasheet as 2 clocks; the nanosecond column is just 2 x that speed grade's
# tCK. Below about 71 MHz a 14 ns figure is less than one clock and all three
# would round to a single cycle. The HDL floors them; this has to agree or the
# numbers reported here are not the numbers that get built.
proc cyc_of_min {ns khz floor} {
    set c [cyc_of $ns $khz]
    if {$c < $floor} { set c $floor }
    return $c
}

# The refresh interval is a MAXIMUM, not a minimum, so it floors. Rounding it
# up refreshes less often than the part allows, which is the one direction that
# loses data.
proc cyc_of_max {ns khz} {
    if {$khz <= 0} { return 0 }
    set c [expr {int(floor((double($ns) * double($khz)) / 1000000.0))}]
    if {$c < 1} { set c 1 }
    return $c
}

proc validate {} {
    set row   [get_parameter_value ROW_BITS]
    set col   [get_parameter_value COL_BITS]
    set bank  [get_parameter_value BANK_BITS]
    set sa    [get_parameter_value SA_BITS]
    set dw    [get_parameter_value DATA_BITS]
    set cas   [get_parameter_value CAS_LAT]
    set fifo  [get_parameter_value FIFO_DEPTH]
    set khz   [get_parameter_value CLK_KHZ]
    set hz    [get_parameter_value CLK_RATE_HZ]
    set look  [get_parameter_value LOOKAHEAD]
    set pend  [get_parameter_value REF_MAX_PEND]

    set t_rc  [get_parameter_value T_RC_NS]
    set t_ras [get_parameter_value T_RAS_NS]
    set t_rp  [get_parameter_value T_RP_NS]
    set t_rcd [get_parameter_value T_RCD_NS]
    set t_rrd [get_parameter_value T_RRD_NS]
    set t_wr  [get_parameter_value T_WR_NS]
    set t_rfc [get_parameter_value T_RFC_NS]
    set refr  [get_parameter_value REF_ROWS]
    set refp  [get_parameter_value REF_PERIOD_MS]

    # ---- 1. the address bus must be able to carry a row ----
    if {$sa < $row} {
        send_message error "SA_BITS=$sa cannot carry a $row-bit row address. The device needs at least $row address pins."
    }
    if {$sa < 11} {
        send_message error "SA_BITS=$sa is too small: A10 is the precharge-all flag, so at least 11 address pins are required regardless of the row width."
    }

    # ---- 2. the clock has to be known before anything else means anything ----
    if {$hz <= 0} {
        send_message warning "The clock rate is not known yet - connect a clock source to clk. Until then every nanosecond figure below is unconverted and the cycle counts reported here are meaningless."
        return
    }

    # ---- 3. definitional relationships between the timings ----
    # These catch a mistyped datasheet number, which is otherwise invisible:
    # the design still builds and still runs, just illegally.
    if {$t_ras > $t_rc} {
        send_message error "tRAS ($t_ras ns) is longer than tRC ($t_rc ns). tRC is the whole row cycle and tRAS is part of it, so this is a data-entry error."
    }
    if {$t_rc < [expr {$t_ras + $t_rp}]} {
        send_message warning "tRC ($t_rc ns) is less than tRAS + tRP ([expr {$t_ras + $t_rp}] ns). On nearly every SDR part tRC equals tRAS + tRP; check the datasheet."
    }
    if {$t_rrd > $t_rc} {
        send_message error "tRRD ($t_rrd ns) is longer than tRC ($t_rc ns). tRRD is the bank-to-bank activate delay and is always the shorter of the two."
    }

    # ---- 4. derived cycle counts ----
    set c_rc  [cyc_of $t_rc  $khz]
    set c_ras [cyc_of $t_ras $khz]
    set c_rp  [cyc_of $t_rp  $khz]
    set c_rcd [cyc_of $t_rcd $khz]
    set c_rrd [cyc_of_min $t_rrd $khz 2]
    set c_wr  [cyc_of_min $t_wr  $khz 2]
    set c_rfc [cyc_of $t_rfc $khz]
    set c_refi [cyc_of_max [expr {($refp * 1000000.0) / double($refr)}] $khz]

    # Tell the integrator when a clock-count floor is doing the work, rather
    # than silently building something different from what the nanoseconds say.
    set t_mrd [get_parameter_value T_MRD_NS]
    foreach {nm ns} [list tRRD $t_rrd tWR $t_wr tMRD $t_mrd] {
        if {[cyc_of $ns $khz] < 2} {
            send_message info "$nm is ${ns} ns, which at [format %.3f [expr {double($khz)/1000.0}]] MHz is less than two clocks. SDR SDRAM specifies it as a 2 clock minimum regardless of frequency, so the controller will use 2 cycles rather than [cyc_of $ns $khz]."
        }
    }

    # The HDL holds these in 8-bit counters.
    foreach {nm v} [list tRC $c_rc tRAS $c_ras tRP $c_rp tRCD $c_rcd \
                         tRRD $c_rrd tWR $c_wr tRFC $c_rfc] {
        if {$v > 255} {
            send_message error "$nm works out at $v cycles, which does not fit the controller's 8-bit timing counters. Either the clock is implausibly fast for this part or the nanosecond figure is wrong."
        }
    }

    # ---- 5. refresh has to be achievable ----
    # One refresh costs a precharge-all, tRP, then tRFC. If they arrive faster
    # than they can be served the controller never catches up and the part
    # loses data - silently, and only once it is warm.
    set ref_cost [expr {$c_rp + $c_rfc + 2}]
    if {$c_refi <= $ref_cost} {
        send_message error "A refresh is due every $c_refi cycles but costs about $ref_cost cycles to perform. The controller cannot keep up. Check REF_ROWS ($refr) and the refresh period ($refp ms) against the datasheet."
    } elseif {$c_refi < [expr {$ref_cost * 10}]} {
        send_message warning "Refresh will consume roughly [format %.1f [expr {100.0 * $ref_cost / $c_refi}]]% of the memory bandwidth (one refresh every $c_refi cycles, costing about $ref_cost). That is high; check REF_ROWS and the refresh period."
    }

    # ---- 5b. the power-on wait ----
    # Every SDR datasheet asks for at least 100 us of NOPs with CKE high before
    # the first command. Shorter values exist only so a simulation does not
    # spend 100 us proving nothing, and they must never reach a board.
    set tinit [get_parameter_value T_INIT_US]
    if {$tinit < 100} {
        send_message warning "The power-on wait is ${tinit} us. SDR SDRAM requires at least 100 us of NOP with CKE high before any command; anything less is a simulation shortcut and will not initialise a real part reliably."
    }

    # ---- 6. things the HDL itself requires ----
    if {$col > 11} {
        send_message error "COL_BITS=$col is beyond what the column encoding supports. Column bit 10 steps over A10; there is nowhere for a twelfth to go."
    }
    if {$fifo < 2} {
        send_message error "FIFO_DEPTH must be at least 2."
    }
    if {$look && $fifo < 2} {
        send_message error "Look-ahead needs a command buffer of at least 2 - it works by inspecting the entry behind the one being served."
    }

    # ---- 7. report, so the numbers can be checked against the datasheet ----
    set words [expr {1 << ($row + $col + $bank)}]
    set mbytes [expr {double($words) * ($dw / 8) / 1048576.0}]
    set banks [expr {1 << $bank}]

    send_message info "Memory: [format %.0f $mbytes] MByte - $banks banks x [expr {1 << $row}] rows x [expr {1 << $col}] columns x $dw bits. Avalon word address is [expr {$row + $col + $bank}] bits."

    send_message info "At [format %.3f [expr {double($khz)/1000.0}]] MHz the HDL will use: tRC=$c_rc tRAS=$c_ras tRP=$c_rp tRCD=$c_rcd tRRD=$c_rrd tWR=$c_wr tRFC=$c_rfc cycles, CAS=$cas, one refresh every $c_refi cycles. Minimum timings round UP from nanoseconds, so a cycle count one higher than the datasheet minimum is expected and correct; the refresh interval rounds DOWN, because it is a maximum."

    send_message info "$banks rows can be open at once, one per bank. A read/write turnaround inside an open row costs 0 cycles write-to-read and [expr {$cas + 1}] read-to-write, with no row command either way."

    if {!$look} {
        send_message info "Look-ahead is off. Correct, but scattered and bank-crossing traffic will be roughly 1.7x slower than it needs to be, because each row is opened only once the access needing it reaches the head of the buffer."
    }
    if {$pend == 1} {
        send_message info "Refresh postponement is disabled (REF_MAX_PEND=1), so a refresh interrupts whatever burst is in progress. Raising it lets the burst finish first."
    }
    if {[get_parameter_value ADDR_MAP] != 0} {
        send_message warning "The conventional address map is selected. This is NOT the map the SDRAM Controller Intel FPGA IP uses, so replacing that core with this one in an existing system will move every address in memory. Use the compatible map unless this is a new design."
    }
    if {[get_parameter_value RD_EXTRA_LAT] != 0} {
        send_message warning "RD_EXTRA_LAT is [get_parameter_value RD_EXTRA_LAT]. This is only correct if the DQ return path is registered outside the controller. If read data is simply wrong, this is the wrong knob - check CAS latency first."
    }
}
