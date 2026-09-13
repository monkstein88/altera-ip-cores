/* Register access for the harness: every IORD/IOWR the driver makes is one
 * Avalon-MM transfer on the simulated csr slave, and the only thing that
 * advances simulated time. See tb/driver/sim_main.cpp. */
#ifndef __IO_H__
#define __IO_H__
#ifdef __cplusplus
extern "C" {
#endif
unsigned sim_iord(unsigned base, unsigned ofst);
void     sim_iowr(unsigned base, unsigned ofst, unsigned data);
#ifdef __cplusplus
}
#endif
#define IORD_32DIRECT(BASE, OFFSET) \
    sim_iord((unsigned)(BASE), (unsigned)(OFFSET))
#define IOWR_32DIRECT(BASE, OFFSET, DATA) \
    sim_iowr((unsigned)(BASE), (unsigned)(OFFSET), (unsigned)(DATA))
#endif
