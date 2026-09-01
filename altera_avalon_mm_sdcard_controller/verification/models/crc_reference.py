# Bit-serial CRC7 and CRC16 exactly as the RTL will implement them.
# CRC7  : x^7 + x^3 + 1        , init 0, over the 5 command bytes, MSB first
# CRC16 : x^16 + x^12 + x^5 + 1, init 0, over the data block,      MSB first

def crc7_bit(crc, bit):                 # crc is 7 bits
    inv = bit ^ ((crc >> 6) & 1)
    crc = ((crc << 1) & 0x7F)
    if inv: crc ^= 0x09                 # x^3 + 1 feedback taps
    return crc

def crc7(data):
    c = 0
    for byte in data:
        for i in range(7, -1, -1):
            c = crc7_bit(c, (byte >> i) & 1)
    return c

def crc16_bit(crc, bit):                # crc is 16 bits
    inv = bit ^ ((crc >> 15) & 1)
    crc = ((crc << 1) & 0xFFFF)
    if inv: crc ^= 0x1021
    return crc

def crc16(data):
    c = 0
    for byte in data:
        for i in range(7, -1, -1):
            c = crc16_bit(c, (byte >> i) & 1)
    return c

def cmd_frame(idx, arg):
    b = [0x40 | idx] + [(arg >> s) & 0xFF for s in (24, 16, 8, 0)]
    return b + [(crc7(b) << 1) | 1]

print("=== CRC7: command frames (last byte is CRC7<<1 | 1) ===")
checks = [
    ("CMD0  GO_IDLE_STATE",      0,  0x00000000, 0x95),
    ("CMD8  SEND_IF_COND 0x1AA", 8,  0x000001AA, 0x87),
    ("CMD55 APP_CMD",            55, 0x00000000, None),
    ("CMD58 READ_OCR",           58, 0x00000000, None),
    ("CMD17 READ_SINGLE blk 0",  17, 0x00000000, None),
]
ok = True
for name, idx, arg, expect in checks:
    f = cmd_frame(idx, arg)
    s = " ".join(f"{x:02X}" for x in f)
    if expect is None:
        print(f"  {name:28s} {s}")
    else:
        good = (f[-1] == expect)
        ok &= good
        print(f"  {name:28s} {s}   expect {expect:02X}  {'PASS' if good else 'FAIL'}")

print()
print("=== CRC16-CCITT, init 0x0000 ===")
v1 = crc16(b'\xFF' * 512)
v2 = crc16(b'\x00' * 512)
v3 = crc16(bytes(range(256)) * 2)
print(f"  512 x 0xFF          -> 0x{v1:04X}   expect 0x7FA1  {'PASS' if v1==0x7FA1 else 'FAIL'}")
print(f"  512 x 0x00          -> 0x{v2:04X}   expect 0x0000  {'PASS' if v2==0x0000 else 'FAIL'}")
print(f"  0x00..0xFF twice    -> 0x{v3:04X}")
ok &= (v1 == 0x7FA1 and v2 == 0x0000)

# Self-check: appending the CRC must make the running CRC return to zero.
blk  = bytes((i * 7 + 3) & 0xFF for i in range(512))
c    = crc16(blk)
zero = crc16(blk + bytes([(c >> 8) & 0xFF, c & 0xFF]))
print(f"  data+CRC re-CRC     -> 0x{zero:04X}   expect 0x0000  {'PASS' if zero==0 else 'FAIL'}")
ok &= (zero == 0)

print()
print("ALL CHECKS PASS" if ok else "*** SOME CHECKS FAILED ***")
