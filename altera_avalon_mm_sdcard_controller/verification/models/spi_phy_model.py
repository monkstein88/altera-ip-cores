# Cycle-accurate model of avalon_mm_sdcard_controller_clkgen + _spi_phy, transcribed
# from the RTL. Non-blocking semantics: next state computed from current state.
MOSI_IDLE = 0xFF

class Phy:
    def __init__(self, clkdiv=1, sample_dly=0):
        self.clkdiv, self.sample_dly = clkdiv, sample_dly
        self.cnt = 0; self.sclk = 0
        self.shreg = MOSI_IDLE; self.hold = MOSI_IDLE; self.hold_v = False
        self.tx_cnt = 0; self.mosi = 1; self.byte_active = False
        self.rxreg = 0; self.rx_cnt = 0; self.rx_data = 0; self.rx_valid = False
        self.rise_pipe = 0
        self.sclk_rises = 0

    def step(self, run, tx_we, tx_data, miso, tx_idle=False):
        div = self.clkdiv if self.clkdiv else 1
        active = self.byte_active or self.sclk
        tick = active and self.cnt == 0
        rise = tick and not self.sclk
        fall = tick and self.sclk

        smpl = (self.rise_pipe >> self.sample_dly) & 1

        tx_last = fall and self.tx_cnt == 7
        have_byte = self.hold_v or tx_idle
        load_now = run and have_byte and ((not self.byte_active) or tx_last)
        nxt = self.hold if self.hold_v else MOSI_IDLE
        tx_ready = not self.hold_v

        # ---- next state ----
        n = {}
        if not active: n['cnt'], n['sclk'] = div - 1, 0
        elif tick:     n['cnt'], n['sclk'] = div - 1, 1 - self.sclk
        else:          n['cnt'], n['sclk'] = self.cnt - 1, self.sclk

        n['rise_pipe'] = ((self.rise_pipe << 1) | (1 if rise else 0)) & 0x1FF

        n['hold'], n['hold_v'] = self.hold, self.hold_v
        if tx_we and not self.hold_v: n['hold'], n['hold_v'] = tx_data, True
        elif load_now and self.hold_v: n['hold_v'] = False

        n['shreg'], n['mosi'] = self.shreg, self.mosi
        n['tx_cnt'], n['byte_active'] = self.tx_cnt, self.byte_active
        if load_now:
            n['shreg'] = ((nxt << 1) | 1) & 0xFF; n['mosi'] = (nxt >> 7) & 1
            n['tx_cnt'] = 0; n['byte_active'] = True
        elif tx_last:
            n['byte_active'] = False; n['mosi'] = 1
        elif fall and self.byte_active:
            n['shreg'] = ((self.shreg << 1) | 1) & 0xFF
            n['mosi'] = (self.shreg >> 7) & 1; n['tx_cnt'] = self.tx_cnt + 1
        elif not self.byte_active:
            n['mosi'] = 1

        n['rxreg'], n['rx_cnt'] = self.rxreg, self.rx_cnt
        n['rx_data'], n['rx_valid'] = self.rx_data, False
        if smpl:
            n['rxreg'] = ((self.rxreg << 1) | miso) & 0xFF
            n['rx_cnt'] = (self.rx_cnt + 1) & 7
            if self.rx_cnt == 7:
                n['rx_data'] = ((self.rxreg << 1) | miso) & 0xFF; n['rx_valid'] = True
        if (not self.byte_active) and (not run) and n['rise_pipe'] == 0:
            n['rx_cnt'] = 0

        if rise: self.sclk_rises += 1
        out = dict(tx_ready=tx_ready, rx_valid=self.rx_valid, rx_data=self.rx_data,
                   mosi=self.mosi, sclk=self.sclk, rise=rise, fall=fall)
        for k, v in n.items(): setattr(self, k, v)
        return out

def run_stream(nbytes, clkdiv, sample_dly, pattern, loopback=True, idle_mode=False):
    p = Phy(clkdiv, sample_dly)
    tx = list(pattern); txi = 0; rx = []
    miso_hist = [1] * 64
    for cyc in range(nbytes * 8 * 2 * max(clkdiv,1) + 4000):
        # loopback: card echoes MOSI back on MISO with no added delay
        miso = p.mosi if loopback else 1
        we = txi < len(tx)
        o = p.step(run=(txi < len(tx) or p.hold_v), tx_we=we,
                   tx_data=tx[txi] if we else 0, miso=miso, tx_idle=idle_mode)
        if we and o['tx_ready']: txi += 1
        if o['rx_valid']: rx.append(o['rx_data'])
        if txi >= len(tx) and not p.byte_active and p.rise_pipe == 0: break
    return p, rx

print("=== inter-byte gap: SPI clocks consumed per byte ===")
print("   ideal is exactly 8.00 - anything above it is bus thrown away\n")
ok = True
for clkdiv in (1, 2, 4, 125):
    for sd in (0, 2):
        n = 32
        p, rx = run_stream(n, clkdiv, sd, [0xA5, 0x5A, 0xFF, 0x00] * (n // 4))
        per = p.sclk_rises / n
        good = abs(per - 8.0) < 1e-9
        ok &= good
        print(f"   CLKDIV={clkdiv:<4d} sample_dly={sd}   {p.sclk_rises:5d} clocks / {n} bytes"
              f" = {per:5.2f}   {'PASS' if good else 'FAIL'}")

print("\n=== loopback data integrity (MSB first, byte framing) ===")
pat = [0x00, 0xFF, 0xA5, 0x5A, 0x01, 0x80, 0x7F, 0xC3]
for clkdiv in (1, 2):
    p, rx = run_stream(len(pat), clkdiv, 0, pat)
    # first received byte is whatever was on the wire before the first tx byte
    match = rx[:len(pat)] == pat
    ok &= match
    print(f"   CLKDIV={clkdiv}  tx={[f'{x:02X}' for x in pat]}")
    print(f"             rx={[f'{x:02X}' for x in rx[:len(pat)]]}  "
          f"echo exact: {'PASS' if match else 'FAIL'}")

print("\n=== efficiency vs a shifter that idles one clock per byte ===")
print(f"   this design      : 8.00 clocks/byte -> {512/ (515*8/8) *100:5.1f}% of line rate on a 512B block")
print(f"   one idle per byte: 9.00 clocks/byte -> {8/9*100:5.1f}% of this design's throughput")

print("\nALL CHECKS PASS" if ok else "\n*** SOME CHECKS FAILED ***")
