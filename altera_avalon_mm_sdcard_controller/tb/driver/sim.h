/* =============================================================================
 * sim.h - what the driver tests may ask of the simulated hardware.
 *
 * Implemented by sim_main.cpp. The driver itself never sees this header: it
 * reaches the hardware only through <io.h>, exactly as on a Nios II.
 * ===========================================================================*/
#ifndef SDCARD_DRV_SIM_H
#define SDCARD_DRV_SIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* The socket. */
#define SIM_CARD_NONE  0
#define SIM_CARD_HC    1      /* SDHC: block addressed, N_CR 2, CID 0x48430001 */
#define SIM_CARD_SC    2      /* SDSC: byte addressed,  N_CR 8, CID 0x53430002 */

void     sim_card_select(int which);
void     sim_write_protect(int on);

/* Pull the card and fit `which` in its place IN THE MIDDLE OF A CALL: straight
 * after the driver's n-th write of `data` to register offset `ofst`, counting
 * from now. For the races a swap between two calls cannot reach. */
void     sim_swap_on_write(unsigned ofst, unsigned data, unsigned nth, int which);

/* Fault injection, bit per fault - the order of the inj port in drv_top. */
#define SIM_INJ_NO_RESPONSE   0x01u
#define SIM_INJ_R1_ILLEGAL    0x02u
#define SIM_INJ_R1_CRC        0x04u
#define SIM_INJ_READ_TOKEN    0x08u
#define SIM_INJ_BAD_DATA_CRC  0x10u
#define SIM_INJ_WRITE_CRC     0x20u
#define SIM_INJ_WRITE_ERR     0x40u
#define SIM_INJ_BUSY_FOREVER  0x80u

/* Held until sim_fault(0). */
void     sim_fault(unsigned mask);
/* Released as soon as the card in the socket has acted on it once. */
void     sim_fault_once(unsigned mask);
unsigned sim_faults_applied(int which);

/* Observation. */
unsigned sim_card_cmds(int which);
unsigned sim_card_blocks_written(int which);
unsigned sim_dma_beats(void);
unsigned sim_card_peek(int which, unsigned byte_addr);
void     sim_card_poke(int which, unsigned byte_addr, unsigned data);

/* Whether the card is still programming a written block, and how long it
 * programs for (byte-times; 4 unless set). */
unsigned sim_card_busy(int which);
void     sim_card_set_prog_bytes(int which, unsigned byte_times);

/* Configuration of this build. */
int      sim_cfg_dma(void);
int      sim_cfg_card_detect(void);

/* Time. */
unsigned long long sim_cycles(void);
unsigned long long sim_bus_accesses(void);
void     sim_idle(unsigned cycles);

/* Every test declares how many clock cycles it may take. A driver that spins
 * forever on a status bit the hardware will never set is a failure to report,
 * not a simulation to wait out. */
void     sim_budget(const char *test, unsigned long long cycles);

/* The CPU cost of a bus access this run was started with (+cpu=N). */
unsigned sim_cpu_cycles(void);

#ifdef __cplusplus
}
#endif

#endif
