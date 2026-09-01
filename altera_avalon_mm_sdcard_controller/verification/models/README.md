# Design-time models

Two Python programs used while writing the RTL, kept because they found real
bugs and because the vectors in the first one are worth having in one place.

```
python3 crc_reference.py     # CRC7 / CRC16 against spec-derived vectors
python3 spi_phy_model.py     # cycle-accurate model of clkgen + spi_phy
```

Both exit with `ALL CHECKS PASS` or name what failed.

## What each one is for

**`crc_reference.py`** is a reference implementation of the two CRCs, checked
against constants that come from the specification rather than from this
design:

| Vector | Expected | Source |
| --- | --- | --- |
| CMD0 frame `40 00 00 00 00` | CRC byte `0x95` | Physical Layer spec §7.2.2 quotes this exact frame |
| CMD8 frame `48 00 00 01 AA` | CRC byte `0x87` | §7.2.2, CRC always checked for CMD8 |
| 512 bytes of `0xFF` | CRC16 `0x7FA1` | widely published SD test vector |
| block with its CRC appended | CRC16 `0x0000` | the property the receive path relies on |

That last one is the one that matters most in the RTL: because CRC16 is seeded
with zero, running the accumulation through the two incoming CRC bytes as well
leaves zero if the block was intact. The read path checks a block that way
rather than latching an expected value and comparing.

The 0x95 and 0x87 vectors also pin down the parameter that is most often wrong.
"CCITT" usually implies an initial value of `0xFFFF`; SD uses `0x0000`. A CRC16
seeded with `0xFFFF` produces plausible values that every card rejects, and the
symptom looks like a signal-integrity fault rather than an arithmetic one.

**`spi_phy_model.py`** is a cycle-accurate transcription of
`avalon_mm_sdcard_controller_clkgen.sv` and `avalon_mm_sdcard_controller_spi_phy.sv`, with non-blocking
assignment semantics preserved. It measures the one number the core's
throughput claim rests on — **SPI clocks consumed per byte, which must be
exactly 8.00** — and checks byte framing and MSB ordering by loopback.

Eight clocks per byte is not a rounding target. A shifter that inserts one idle
clock at each byte boundary still transfers every byte correctly and still
passes any functional test; it just runs at 8/9 of the rate, which over a
512-byte block is the difference between 99% and 88% of line rate. Nothing
except a cycle count catches that.

## Bugs these found

All three were found before the RTL had ever been simulated:

1. **Dropped prefetch byte.** Producing and consuming the one-deep prefetch were
   two independent `if` statements, so a byte written on the same cycle it was
   consumed was silently lost. Needs a sequencer fast enough to write on exactly
   that cycle, which no casual testbench would do.
2. **Truncated last byte.** The receive bit counter realigned on `byte_active`
   alone, while the delayed sample pipeline still had bits in flight. Only
   manifests when `sample_dly` is non-zero — the configuration least likely to
   be simulated first.
3. **Bit misalignment at `CLKDIV=1`.** The clock divider was gated on `run`
   rather than on `byte_active`, letting the SPI clock advance one edge before
   the first byte was loaded. At slow divisors this cost one wasted clock; at
   `CLKDIV=1` it shifted the bit alignment of the entire transfer, corrupting
   every byte. This is why the clkgen is gated the way it is.

## What these are NOT

**They are not verification of the RTL.** They are hand-transcribed models of
it, so they can drift from it, and nothing here checks that they have not. The
real regression is `simulation/verilator/run_sim.sh` against the actual RTL and
the card model; these are a design aid that happened to pay for itself.

They exist because the environment the RTL was written in had no Verilog
simulator available, and checking the arithmetic and the cycle behaviour in
Python was better than checking neither. Treat a disagreement between one of
these and the Verilog regression as the model being wrong until proven
otherwise.
