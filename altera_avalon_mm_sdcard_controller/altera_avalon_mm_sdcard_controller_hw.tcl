package require -exact qsys 14.0

# =============================================================================
# altera_avalon_mm_sdcard_controller_hw.tcl
#
# Platform Designer / Qsys component description for avalon_mm_sdcard_controller.
#
# IMPORTANT: hand-written hw.tcl syntax has drifted across Quartus versions
# (Standard vs Pro, and release to release - see Intel's "_hw.tcl Command
# Reference" for your installed version). This file is a complete, best-effort
# starting point, not a guaranteed drop-in for every Quartus release.
#
# The robust way to package this component, recommended over trusting this file
# blindly:
#   1. In Platform Designer, Component Editor -> add the nine files under rtl/
#      as synthesis files, with avalon_mm_sdcard_controller_pkg.sv FIRST and
#      avalon_mm_sdcard_controller.sv as the top-level file, then "Analyze
#      Synthesis Files".
#   2. Because every port follows the csr_*/m0_*/sd_* convention with standard
#      Avalon-MM signal names, signal analysis should auto-group them into an
#      Avalon-MM agent, an Avalon-MM host, a clock, a reset, an interrupt
#      sender and a conduit.
#   3. File -> Save / Export as hw.tcl Component to get a file guaranteed
#      correct for your exact installed version.
# =============================================================================

set_module_property NAME altera_avalon_mm_sdcard_controller
set_module_property DISPLAY_NAME "Avalon-MM SD Card Controller (SPI)"
set_module_property DESCRIPTION "SD card controller in SPI mode, with hardware multi-block streaming, CRC7/CRC16, pre-emptive busy polling and an optional Avalon-MM master for DMA into system memory."
set_module_property VERSION 1.0
set_module_property GROUP "Memory Interfaces and Controllers/Custom"
set_module_property AUTHOR "monkstein88"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE false
set_module_property ELABORATION_CALLBACK elaborate
set_module_property VALIDATION_CALLBACK validate

# -----------------------------------------------------------------------
# Files
#
# TYPE must be SYSTEM_VERILOG, not VERILOG. The RTL uses `logic`,
# always_ff/always_comb, packed structs, enums and two packages; declaring it
# as VERILOG makes Quartus analyse it with the Verilog-2001 parser, which
# fails on the first `logic` declaration.
#
# ORDER MATTERS. The two packages must be analysed before anything that
# imports them. This is not theoretical - a glob-ordered compile puts
# avalon_mm_sdcard_controller.sv (the top) ahead of
# avalon_mm_sdcard_controller_pkg.sv alphabetically, and fails with
# "Reference to 'resp_e' before declaration".
#
# The SIM fileset is still named SIM_VERILOG; that is the fileset's name in
# Platform Designer, independent of the language of the files inside it.
# -----------------------------------------------------------------------
set rtl_files {
    avalon_mm_sdcard_controller_pkg.sv
    avalon_mm_sdcard_controller_crc.sv
    avalon_mm_sdcard_controller_clkgen.sv
    avalon_mm_sdcard_controller_spi_phy.sv
    avalon_mm_sdcard_controller_fifo.sv
    avalon_mm_sdcard_controller_dma.sv
    avalon_mm_sdcard_controller_seq.sv
    avalon_mm_sdcard_controller_regs.sv
}

add_fileset QUARTUS_SYNTH QUARTUS_SYNTH generate_synth_files ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL avalon_mm_sdcard_controller
foreach f $rtl_files {
    add_fileset_file $f SYSTEM_VERILOG PATH rtl/$f
}
add_fileset_file avalon_mm_sdcard_controller.sv SYSTEM_VERILOG \
    PATH rtl/avalon_mm_sdcard_controller.sv TOP_LEVEL_FILE

add_fileset SIM_VERILOG SIM_VERILOG generate_sim_files ""
set_fileset_property SIM_VERILOG TOP_LEVEL avalon_mm_sdcard_controller
foreach f $rtl_files {
    add_fileset_file $f SYSTEM_VERILOG PATH rtl/$f
}
add_fileset_file avalon_mm_sdcard_controller.sv SYSTEM_VERILOG \
    PATH rtl/avalon_mm_sdcard_controller.sv TOP_LEVEL_FILE

proc generate_synth_files {entity_name} { }
proc generate_sim_files   {entity_name} { }

# -----------------------------------------------------------------------
# Parameters
# -----------------------------------------------------------------------
add_parameter FIFO_DEPTH_BYTES INTEGER 1024
set_parameter_property FIFO_DEPTH_BYTES DISPLAY_NAME "Block buffer depth"
set_parameter_property FIFO_DEPTH_BYTES UNITS bytes
set_parameter_property FIFO_DEPTH_BYTES ALLOWED_RANGES {512 1024 2048 4096 8192}
set_parameter_property FIFO_DEPTH_BYTES HDL_PARAMETER true
set_parameter_property FIFO_DEPTH_BYTES DESCRIPTION "Decouples the SPI shifter from memory. 1024 holds two 512-byte blocks, so one can be on the wire while the other moves to or from memory. 512 works but leaves no overlap. Deeper tolerates more interconnect latency and buys nothing on a lightly loaded system."

add_parameter M0_BURST_WIDTH INTEGER 8
set_parameter_property M0_BURST_WIDTH DISPLAY_NAME "Master burstcount width"
set_parameter_property M0_BURST_WIDTH UNITS bits
set_parameter_property M0_BURST_WIDTH ALLOWED_RANGES {1:9}
set_parameter_property M0_BURST_WIDTH HDL_PARAMETER true
set_parameter_property M0_BURST_WIDTH DESCRIPTION "Maximum burst is 2^(N-1) beats. 8 gives 128 beats, exactly one 512-byte block. 1 means no bursting, which is a supported configuration and not a degraded one - at SPI rates the memory side is never the bottleneck, and Platform Designer inserts a burst adapter wherever m0 meets a slave that bursts less."

add_parameter CLKDIV_WIDTH INTEGER 8
set_parameter_property CLKDIV_WIDTH DISPLAY_NAME "Clock divider width"
set_parameter_property CLKDIV_WIDTH UNITS bits
set_parameter_property CLKDIV_WIDTH ALLOWED_RANGES {4:16}
set_parameter_property CLKDIV_WIDTH HDL_PARAMETER true
set_parameter_property CLKDIV_WIDTH DESCRIPTION "SPI clock is clk/(2*CLKDIV), set at run time. 8 bits spans clk/2 to clk/510 - from a 100 MHz clock that is 50 MHz down to 196 kHz, covering both the 400 kHz identification rate and full speed."

add_parameter TIMEOUT_WIDTH INTEGER 26
set_parameter_property TIMEOUT_WIDTH DISPLAY_NAME "Timeout counter width"
set_parameter_property TIMEOUT_WIDTH UNITS bits
set_parameter_property TIMEOUT_WIDTH ALLOWED_RANGES {16:32}
set_parameter_property TIMEOUT_WIDTH HDL_PARAMETER true
set_parameter_property TIMEOUT_WIDTH DESCRIPTION "Bounds every wait: response, data token, block, and the card's busy period. 26 bits at 100 MHz is 0.67 s, which covers the specification's 250 ms worst-case write-busy and 100 ms read-access limits with margin."

add_parameter MAX_BLOCK_BYTES INTEGER 512
set_parameter_property MAX_BLOCK_BYTES DISPLAY_NAME "Maximum block length"
set_parameter_property MAX_BLOCK_BYTES UNITS bytes
set_parameter_property MAX_BLOCK_BYTES ALLOWED_RANGES {16 64 128 256 512}
set_parameter_property MAX_BLOCK_BYTES HDL_PARAMETER true
set_parameter_property MAX_BLOCK_BYTES DESCRIPTION "512 is the specification maximum, not a convention - Physical Layer 7.2.3 fixes it regardless of READ_BL_LEN, and SDHC/SDXC accept nothing else. Smaller values only make sense for a design that will never touch a high-capacity card, or that only reads the 16-byte CSD and CID."

add_parameter CSR_ADDR_WIDTH INTEGER 5
set_parameter_property CSR_ADDR_WIDTH DISPLAY_NAME "Control port address width"
set_parameter_property CSR_ADDR_WIDTH UNITS bits
set_parameter_property CSR_ADDR_WIDTH ALLOWED_RANGES {5:8}
set_parameter_property CSR_ADDR_WIDTH HDL_PARAMETER true
set_parameter_property CSR_ADDR_WIDTH DESCRIPTION "In WORDS, because the csr port is word-addressed. The register map occupies 17 words, so 5 is the minimum."

add_parameter ADDR_WIDTH INTEGER 32
set_parameter_property ADDR_WIDTH DISPLAY_NAME "Master address width"
set_parameter_property ADDR_WIDTH UNITS bits
set_parameter_property ADDR_WIDTH ALLOWED_RANGES {16:32}
set_parameter_property ADDR_WIDTH HDL_PARAMETER true
set_parameter_property ADDR_WIDTH DESCRIPTION "Byte address width of m0. Ignored when the DMA is disabled."

add_parameter USE_DMA INTEGER 1
set_parameter_property USE_DMA DISPLAY_NAME "Include the DMA master"
set_parameter_property USE_DMA ALLOWED_RANGES {0 1}
set_parameter_property USE_DMA HDL_PARAMETER true
set_parameter_property USE_DMA DESCRIPTION "Adds the m0 Avalon-MM master. With it off the core has no master port and block data moves through the DATA register under software control, costing roughly 10-20% of a 100 MHz Nios II/f during a transfer and nothing in bus throughput - at SPI rates the memory side is never the limit. Turn it off for a system with no suitable memory target, or none to spare."

add_parameter USE_CARD_DETECT INTEGER 1
set_parameter_property USE_CARD_DETECT DISPLAY_NAME "Card detect and write protect"
set_parameter_property USE_CARD_DETECT ALLOWED_RANGES {0 1}
set_parameter_property USE_CARD_DETECT HDL_PARAMETER true
set_parameter_property USE_CARD_DETECT DESCRIPTION "Adds sd_cd_n and sd_wp_n to the conduit, plus the insert and remove interrupts. Turn off for a socket without the switches; STATUS then reports a card always present and never write-protected."

add_parameter USE_CRC INTEGER 1
set_parameter_property USE_CRC DISPLAY_NAME "Check data CRC16"
set_parameter_property USE_CRC ALLOWED_RANGES {0 1}
set_parameter_property USE_CRC HDL_PARAMETER true
set_parameter_property USE_CRC DESCRIPTION "CRC16 generation and checking on data blocks. This is a debugging aid, not a performance option - the CRC is computed a byte at a time as the data moves and costs nothing. CRC7 on commands is unconditional, because CMD0 and CMD8 are validated by the card whatever CMD59 says."

# -----------------------------------------------------------------------
# Clock / reset
# -----------------------------------------------------------------------
add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1

add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset_n reset_n Input 1

# -----------------------------------------------------------------------
# csr - control and status agent
#
# The classic Altera register-peripheral profile: word-addressed, 32-bit,
# fixed read latency of 1, no waitrequest, no readdatavalid. Deliberately the
# dullest possible Avalon-MM port, because it must stay reachable while the
# data path is busy or stuck. A control port that the thing it controls can
# backpressure is not a control port you can recover with.
# -----------------------------------------------------------------------
add_interface csr avalon end
set_interface_property csr addressUnits WORDS
set_interface_property csr associatedClock clock
set_interface_property csr associatedReset reset
set_interface_property csr bridgesToMaster ""
set_interface_property csr holdTime 0
set_interface_property csr readLatency 1
set_interface_property csr readWaitTime 0
set_interface_property csr writeWaitTime 0
set_interface_property csr setupTime 0
set_interface_property csr timingUnits Cycles
set_interface_property csr maximumPendingReadTransactions 0

add_interface_port csr csr_address    address    Input  CSR_ADDR_WIDTH
add_interface_port csr csr_read       read       Input  1
add_interface_port csr csr_write      write      Input  1
add_interface_port csr csr_writedata  writedata  Input  32
add_interface_port csr csr_byteenable byteenable Input  4
add_interface_port csr csr_readdata   readdata   Output 32

# -----------------------------------------------------------------------
# irq - level interrupt, asserted while any enabled sticky bit in IRQ_STATUS
# is set. Clear at the source (write 1 to the bit) to deassert.
# -----------------------------------------------------------------------
add_interface irq interrupt end
set_interface_property irq associatedClock clock
set_interface_property irq associatedReset reset
set_interface_property irq associatedAddressablePoint csr
add_interface_port irq irq irq Output 1

# -----------------------------------------------------------------------
# sd - conduit to the card
#
# Every signal is unidirectional. SPI mode needs no tristates at all, which is
# one of its few genuine advantages over native SD mode: no inout ports, no
# split in/out/oe triplets, no IO buffer to instantiate in the top level, and
# nothing that behaves differently between simulation and hardware.
#
# The board wiring, for a standard microSD socket:
#     sd_clk  -> pin 5 (CLK)      sd_mosi -> pin 2 (CMD)
#     sd_miso -> pin 7 (DAT0)     sd_cs_n -> pin 1 (DAT3)
# Pins 8 and 9 (DAT1, DAT2) are unused in SPI mode and should be pulled high
# at the board, as should MISO.
# -----------------------------------------------------------------------
add_interface sd conduit end
set_interface_property sd associatedClock clock
set_interface_property sd associatedReset reset

add_interface_port sd sd_clk  clk  Output 1
add_interface_port sd sd_mosi mosi Output 1
add_interface_port sd sd_miso miso Input  1
add_interface_port sd sd_cs_n cs_n Output 1

# -----------------------------------------------------------------------
# Elaboration - everything whose PRESENCE, rather than width, depends on a
# parameter.
# -----------------------------------------------------------------------
proc elaborate {} {
    set use_dma [get_parameter_value USE_DMA]
    set use_cd  [get_parameter_value USE_CARD_DETECT]
    set aw      [get_parameter_value ADDR_WIDTH]
    set bw      [get_parameter_value M0_BURST_WIDTH]

    # m0 exists only when the DMA does. The RTL always carries the ports -
    # SystemVerilog cannot remove them on a parameter - and drives them
    # inactive, but a component that advertises a master nobody drives is a
    # port Platform Designer will insist you connect for no reason.
    if {$use_dma} {
        add_interface m0 avalon start
        set_interface_property m0 addressUnits SYMBOLS
        set_interface_property m0 burstcountUnits WORDS
        set_interface_property m0 associatedClock clock
        set_interface_property m0 associatedReset reset
        set_interface_property m0 linewrapBursts false
        set_interface_property m0 burstOnBurstBoundariesOnly false
        set_interface_property m0 constantBurstBehavior false
        set_interface_property m0 alwaysBurstMaxBurst false
        set_interface_property m0 doStreamReads false
        set_interface_property m0 doStreamWrites false
        set_interface_property m0 holdTime 0
        set_interface_property m0 readLatency 0
        set_interface_property m0 readWaitTime 0
        set_interface_property m0 writeWaitTime 0
        set_interface_property m0 setupTime 0
        set_interface_property m0 timingUnits Cycles

        # The core keeps one burst outstanding at a time.
        set_interface_property m0 maximumPendingReadTransactions 1

        add_interface_port m0 m0_address       address       Output $aw
        add_interface_port m0 m0_read          read          Output 1
        add_interface_port m0 m0_write         write         Output 1
        add_interface_port m0 m0_writedata     writedata     Output 32
        add_interface_port m0 m0_byteenable    byteenable    Output 4
        add_interface_port m0 m0_burstcount    burstcount    Output $bw
        add_interface_port m0 m0_waitrequest   waitrequest   Input  1
        add_interface_port m0 m0_readdata      readdata      Input  32
        add_interface_port m0 m0_readdatavalid readdatavalid Input  1
        add_interface_port m0 m0_response      response      Input  2
    }

    if {$use_cd} {
        add_interface_port sd sd_cd_n cd_n Input 1
        add_interface_port sd sd_wp_n wp_n Input 1
    }
}

# -----------------------------------------------------------------------
# Validation
#
# Four ways to configure this core into something that elaborates, simulates
# and is quietly wrong or permanently stalled. All are cheap to catch here and
# expensive to find on a board.
# -----------------------------------------------------------------------
proc validate {} {
    set fifo  [get_parameter_value FIFO_DEPTH_BYTES]
    set blk   [get_parameter_value MAX_BLOCK_BYTES]
    set bw    [get_parameter_value M0_BURST_WIDTH]
    set caw   [get_parameter_value CSR_ADDR_WIDTH]
    set dma   [get_parameter_value USE_DMA]
    set crc   [get_parameter_value USE_CRC]
    set cdw   [get_parameter_value CLKDIV_WIDTH]

    # ---- 1. the CSR port must be able to reach every register ----
    # Integer ceil-log2 by shifting, not int(ceil(log(x)/log(2))). The
    # floating-point form gives the right answer for every value in range on
    # the platforms tested, but it relies on log(x)/log(2) never landing a hair
    # above an integer for exact powers of two - a property of the host libm,
    # not of Tcl. Shifting has no such dependency, and matches clog2_shift() in
    # the RTL package exactly.
    set need 0
    while {(1 << $need) < 17} { incr need }
    if {$caw < $need} {
        send_message error \
            "CSR_ADDR_WIDTH=$caw cannot address the register map: it occupies 17 words and needs at least $need bits. CORE_INFO and ERR_INFO would be unreachable."
    }

    # ---- 2. the buffer must hold at least one whole block ----
    # The SPI data phase cannot be paused part-way through a block without
    # stopping the clock, so a buffer smaller than a block guarantees a stall
    # in the middle of every transfer.
    if {$fifo < $blk} {
        send_message error \
            "FIFO_DEPTH_BYTES=$fifo is smaller than MAX_BLOCK_BYTES=$blk. The buffer must hold at least one complete block."
    }

    # ---- 3. a burst must fit in the buffer ----
    # Avalon read data cannot be backpressured: once a burst of N is issued, N
    # words arrive whether there is room or not. The DMA bounds each burst by
    # the free space it can see, but a burst length that can never fit at all
    # would deadlock it waiting for room that will not appear.
    set max_beats [expr {($bw > 1) ? (1 << ($bw - 1)) : 1}]
    set fifo_words [expr {$fifo / 4}]
    if {$dma && ($max_beats > $fifo_words)} {
        send_message error \
            "M0_BURST_WIDTH=$bw allows bursts of $max_beats words, but the buffer holds only $fifo_words. Avalon read data cannot be backpressured, so a burst larger than the buffer can never be issued and the DMA would wait forever."
    }

    # ---- 4. the divider must be able to reach the identification rate ----
    # Identification must happen between 100 and 400 kHz. From a 100 MHz clock
    # that needs a divisor of at least 125, so at least 7 bits.
    if {$cdw < 7} {
        send_message warning \
            "CLKDIV_WIDTH=$cdw limits the slowest SPI clock to clk/[expr {2 * ((1 << $cdw) - 1)}]. Card identification must run at 100-400 kHz; from a 100 MHz clock that needs a divisor of 125 or more, i.e. at least 7 bits."
    }

    # ---- advisories ----
    if {!$dma} {
        send_message info \
            "USE_DMA is off. Block data moves through the DATA register, which costs roughly 10-20% of a 100 MHz Nios II/f during a transfer. Bus throughput is unaffected - at SPI rates the memory side was never the limit."
    }
    if {!$crc} {
        send_message info \
            "USE_CRC is off. Corrupt blocks will be accepted silently on read, and the card will reject writes whose CRC16 it cannot verify. This is a bring-up aid; leave it on in a working system, where it costs nothing."
    }
    if {$blk < 512} {
        send_message info \
            "MAX_BLOCK_BYTES=$blk is below 512. SDHC and SDXC cards accept only 512-byte blocks, so this configuration will work with standard-capacity cards and CSD/CID reads only."
    }
    if {$fifo == $blk} {
        send_message info \
            "FIFO_DEPTH_BYTES equals MAX_BLOCK_BYTES, so there is no overlap between the block on the wire and the block moving to or from memory. It works; a buffer of twice the block size lets the two proceed together."
    }
}
