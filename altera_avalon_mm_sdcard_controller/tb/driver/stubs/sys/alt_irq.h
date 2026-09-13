/* Interrupt registration for the harness. The registered handler is called by
 * sim_main.cpp between bus accesses while the core's irq output is high, which
 * is as preemptive as an ISR can be when time only moves on a bus access. */
#ifndef __ALT_IRQ_H__
#define __ALT_IRQ_H__
#include "alt_types.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef void (*alt_isr_func)(void *context);
int alt_ic_isr_register(alt_u32 ic_id, alt_u32 irq, alt_isr_func isr,
                        void *context, void *flags);
#ifdef __cplusplus
}
#endif
#endif
