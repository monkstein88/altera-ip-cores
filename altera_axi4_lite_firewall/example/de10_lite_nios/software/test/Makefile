# =============================================================================
# Host tests for the AXI4-Lite Firewall driver.
#
#   make            build and run the tests (default)
#   make nios       compile the driver and the Nios II app with nios2-elf-gcc
#   make clean
#
# These run on the build machine, not on the target. The driver's correctness
# is mostly about ORDERING - which register is written while which other thing
# is true - which a compiler cannot see and which is awkward to observe on
# hardware. test_firewall_host.c checks it against a model of the core's
# register file that also models the orphaned-command hazard.
#
# `make nios` is a compile check, not a link; a linkable image needs the BSP,
# which ../build.sh generates.
# =============================================================================

# The driver now lives with the IP core rather than in a copy next to main.c,
# so the test compiles it from there. That is the point of promoting it: there
# is exactly one copy, and these tests exercise the same file the BSP ships.
CORE     := ../../../..

CC       ?= gcc
CFLAGS   ?= -std=c99 -Wall -Wextra -Wpedantic -Werror -O2 \
            -I$(CORE)/HAL/src -I$(CORE)/HAL/inc -I$(CORE)/inc

QUARTUS_ROOT ?= /opt/intelFPGA/18.1
NIOS_BIN     := $(QUARTUS_ROOT)/nios2eds/bin/gnu/H-x86_64-pc-linux-gnu/bin
NIOS_CC      := $(NIOS_BIN)/nios2-elf-gcc
HAL_INC      := $(QUARTUS_ROOT)/nios2eds/components/altera_nios2_gen2/HAL/inc
BSP          := ../bsp
# The driver registers an ISR, so compiling it for the target pulls in
# sys/alt_irq.h, which needs the generated system.h. That means this check
# needs a BSP - it cannot be done against the bare HAL headers the way it
# could before the driver had an interrupt.
# -Wpedantic is dropped here, and only here: Altera's own sys/alt_irq.h has a
# preprocessor directive inside macro arguments, which -Wpedantic reports and
# -Werror then turns into a build failure. That is a vendor header, not this
# driver. -Wall -Wextra -Werror still apply to our code.
NIOS_CFLAGS  := -std=c99 -Wall -Wextra -Werror -Os \
                -I$(HAL_INC) -I$(BSP) -I$(BSP)/HAL/inc -I$(BSP)/drivers/inc \
                -I$(CORE)/HAL/inc -I$(CORE)/inc

.PHONY: all test nios clean

test: test_firewall_host
	./test_firewall_host

# The test #includes the driver's .c directly so it can substitute the register
# accessors; there is deliberately no separate object to keep in step.
test_firewall_host: test_firewall_host.c \
                    $(CORE)/HAL/src/altera_axi4_lite_firewall.c \
                    $(CORE)/HAL/inc/altera_axi4_lite_firewall.h \
                    $(CORE)/inc/altera_axi4_lite_firewall_regs.h
	$(CC) $(CFLAGS) -o $@ $<

nios:
	@test -x $(NIOS_CC) || { \
	    echo "error: $(NIOS_CC) not found."; \
	    echo "       Set QUARTUS_ROOT (currently $(QUARTUS_ROOT))."; \
	    exit 1; }
	@test -f $(BSP)/system.h || { \
	    echo "error: no BSP at $(BSP)."; \
	    echo "       Run '../../build.sh sw' first - the driver's ISR needs"; \
	    echo "       the generated system.h to compile for the target."; \
	    exit 1; }
	$(NIOS_CC) $(NIOS_CFLAGS) -c -o /dev/null \
	    $(CORE)/HAL/src/altera_axi4_lite_firewall.c
	@echo "Nios II compile check: clean"

all: test nios

clean:
	rm -f test_firewall_host *.o
