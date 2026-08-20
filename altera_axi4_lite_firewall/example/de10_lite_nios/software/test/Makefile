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

CC       ?= gcc
CFLAGS   ?= -std=c99 -Wall -Wextra -Wpedantic -Werror -O2

QUARTUS_ROOT ?= /opt/intelFPGA/18.1
NIOS_BIN     := $(QUARTUS_ROOT)/nios2eds/bin/gnu/H-x86_64-pc-linux-gnu/bin
NIOS_CC      := $(NIOS_BIN)/nios2-elf-gcc
HAL_INC      := $(QUARTUS_ROOT)/nios2eds/components/altera_nios2_gen2/HAL/inc
NIOS_CFLAGS  := -std=c99 -Wall -Wextra -Wpedantic -Werror -Os -I$(HAL_INC) -I..

.PHONY: all test nios clean

test: test_firewall_host
	./test_firewall_host

# The test #includes ../axi4_lite_firewall.c directly so it can substitute the
# register accessors; there is deliberately no separate object to keep in step.
test_firewall_host: test_firewall_host.c ../axi4_lite_firewall.c ../axi4_lite_firewall.h
	$(CC) $(CFLAGS) -o $@ $<

nios:
	@test -x $(NIOS_CC) || { \
	    echo "error: $(NIOS_CC) not found."; \
	    echo "       Set QUARTUS_ROOT (currently $(QUARTUS_ROOT))."; \
	    exit 1; }
	$(NIOS_CC) $(NIOS_CFLAGS) -c -o /dev/null ../axi4_lite_firewall.c
	@echo "Nios II compile check: clean"

all: test nios

clean:
	rm -f test_firewall_host *.o
