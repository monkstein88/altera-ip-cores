// =============================================================================
// sim_main.cpp - driver-in-the-loop harness.
//
// Runs the Nios II HAL driver, compiled from HAL/src unmodified, against the
// controller RTL and the card model. The C driver calls IORD_32DIRECT and
// IOWR_32DIRECT; tb/driver/stubs/io.h turns each into one call here, and each
// call is one Avalon-MM transfer on the csr slave plus a few cycles of CPU.
//
// -----------------------------------------------------------------------------
// TIME
// -----------------------------------------------------------------------------
// Simulated time advances ONLY on a bus access. That is not a shortcut, it is
// the property being tested: a driver whose timing depends on how fast the CPU
// runs a loop - rather than on something the bus can count - gets no time at
// all here, and fails, instead of passing on one processor and not another.
//
// +cpu=N sets how many clock cycles each access costs beyond the transfer
// itself. The default is a quick processor; a large value is a slow one, which
// is what starves the PIO data path.
//
// -----------------------------------------------------------------------------
// POINTERS
// -----------------------------------------------------------------------------
// With the DMA, the driver writes a buffer pointer into DMA_ADDR as an alt_u32
// and the core's master dereferences it. On a 64-bit host that only works if
// every address the driver can take lies below 4 GiB, so:
//
//   - the executable is linked -no-pie, which puts its data and bss low;
//   - the tests run on a thread whose stack is mmap'd with MAP_32BIT, which
//     covers the driver's own stack buffers (read_reg16 DMAs into one);
//   - the tests keep their buffers static or on that stack, never malloc'd.
//
// The first two are checked at start-up, and a DMA build refuses to run if
// either fails - a truncated pointer here scribbles on the host instead of
// failing a test. The third is a rule for driver_tests.c; nothing can check it
// at run time, because by the time an address reaches the DPI it is already
// 32 bits and a truncated one looks like any other.
//
// MAP_32BIT and -no-pie are Linux x86-64. Elsewhere a DMA build exits 2 -
// "could not check", not "failed" - and the PIO builds, which never hand the
// core a pointer it dereferences, run as usual.
// =============================================================================

#include "Vavalon_mm_sdcard_controller_drv_top.h"
#include "Vavalon_mm_sdcard_controller_drv_top__Dpi.h"
#include "verilated.h"
#include "svdpi.h"

#include <pthread.h>
#include <sys/mman.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>

extern "C" {
#include "sim.h"
#include "sys/alt_irq.h"
int driver_tests(void);
}

using Top = Vavalon_mm_sdcard_controller_drv_top;

static VerilatedContext *ctx;
static Top              *top;
static svScope           top_scope;

static uint64_t     cycles;
static uint64_t     accesses;
static unsigned     cpu_cycles   = 3;
static uint64_t     deadline     = ~0ull;
static const char  *budget_owner = "start-up";

static unsigned     inj_once;
static unsigned     inj_once_base;

static unsigned     swap_ofst, swap_data, swap_left;
static int          swap_to_card;

static alt_isr_func isr_fn;
static void        *isr_ctx;
static int          in_isr;
static int          irq_masked;    // alt_irq_disable_all() in force

static const unsigned SDCARD_SIM_BASE = 0x00010000u;   // must match the tests

// The host address of a word the DMA master addresses. See POINTERS above for
// why the 32-bit address the core drives is the host address itself.
static inline uint32_t *host_word(unsigned word_addr)
{
    return reinterpret_cast<uint32_t *>(static_cast<uintptr_t>(word_addr) << 2);
}

// ---------------------------------------------------------------------------
// The clock
// ---------------------------------------------------------------------------
static unsigned card_faults(int which)
{
    return (which == SIM_CARD_SC) ? top->sc_faults : top->hc_faults;
}

static void tick()
{
    top->clk = 0; top->eval(); ctx->timeInc(5);
    top->clk = 1; top->eval(); ctx->timeInc(5);
    cycles++;

    // A one-shot fault is released the moment the card has used it.
    if (inj_once && (top->hc_faults + top->sc_faults) != inj_once_base) {
        top->inj &= ~inj_once;
        inj_once  = 0;
    }

    if (cycles >= deadline) {
        std::printf("  FAIL  %s: still running after its cycle budget - "
                    "the driver is waiting for something that will not happen\n",
                    budget_owner);
        std::printf("=== aborted ===\n");
        std::fflush(stdout);
        std::exit(1);
    }
}

// An interrupt is taken between bus accesses, never inside one.
static void service_irq()
{
    if (top->irq && isr_fn && !in_isr && !irq_masked) {
        in_isr = 1;
        isr_fn(isr_ctx);
        in_isr = 0;
    }
}

static void check_bus(unsigned base, unsigned ofst)
{
    if (base != SDCARD_SIM_BASE || (ofst & 3u) || ofst >= 32u * 4u) {
        std::printf("  FAIL  %s: bus access to base 0x%08x offset 0x%x is not a "
                    "csr register\n", budget_owner, base, ofst);
        std::fflush(stdout);
        std::exit(1);
    }
}

// ---------------------------------------------------------------------------
// io.h
// ---------------------------------------------------------------------------
extern "C" unsigned sim_iord(unsigned base, unsigned ofst)
{
    check_bus(base, ofst);
    top->csr_address = ofst >> 2;
    top->csr_read    = 1;
    tick();                              // read latency 1: data after this edge
    top->csr_read    = 0;
    unsigned v = top->csr_readdata;
    for (unsigned i = 0; i < cpu_cycles; i++) tick();
    accesses++;
    service_irq();
    return v;
}

extern "C" void sim_iowr(unsigned base, unsigned ofst, unsigned data)
{
    check_bus(base, ofst);
    top->csr_address   = ofst >> 2;
    top->csr_writedata = data;
    top->csr_write     = 1;
    tick();
    top->csr_write     = 0;
    for (unsigned i = 0; i < cpu_cycles; i++) tick();
    accesses++;

    if (swap_left && ofst == swap_ofst && data == swap_data && --swap_left == 0) {
        top->card_sel = SIM_CARD_NONE;
        for (int i = 0; i < 4; i++) tick();
        top->card_sel = static_cast<unsigned>(swap_to_card) & 3u;
        for (int i = 0; i < 4; i++) tick();
    }

    service_irq();
}

extern "C" int alt_ic_isr_register(alt_u32, alt_u32, alt_isr_func isr,
                                   void *context, void *)
{
    isr_fn  = isr;
    isr_ctx = context;
    return 0;
}

extern "C" alt_irq_context alt_irq_disable_all(void)
{
    alt_irq_context was = irq_masked;
    irq_masked = 1;
    return was;
}

// An interrupt that arrived while they were held off is taken the moment they
// are enabled again, as the processor takes it - not at the next bus access,
// which a loop doing all its accesses with interrupts held off never reaches.
extern "C" void alt_irq_enable_all(alt_irq_context context)
{
    irq_masked = context;
    service_irq();
}

// ---------------------------------------------------------------------------
// DPI: the DMA's view of memory is the host's
// ---------------------------------------------------------------------------
unsigned int drv_mem_rd(unsigned int word_addr)
{
    return *host_word(word_addr);
}

void drv_mem_wr(unsigned int word_addr, unsigned int data)
{
    *host_word(word_addr) = data;
}

// ---------------------------------------------------------------------------
// sim.h
// ---------------------------------------------------------------------------
extern "C" {

void sim_card_select(int which)
{
    top->card_sel = static_cast<unsigned>(which) & 3u;
    for (int i = 0; i < 4; i++) tick();
    service_irq();
}

void sim_swap_on_write(unsigned ofst, unsigned data, unsigned nth, int which)
{
    swap_ofst    = ofst;
    swap_data    = data;
    swap_left    = nth;
    swap_to_card = which;
}

void sim_write_protect(int on)
{
    top->wp = on ? 1 : 0;
    for (int i = 0; i < 4; i++) tick();
}

void sim_fault(unsigned mask)
{
    top->inj = mask & 0xFFu;
    inj_once = 0;
}

void sim_fault_once(unsigned mask)
{
    inj_once_base = top->hc_faults + top->sc_faults;
    inj_once      = mask & 0xFFu;
    top->inj      = inj_once;
}

unsigned sim_faults_applied(int which) { return card_faults(which); }

unsigned sim_card_cmds(int which)
{
    return (which == SIM_CARD_SC) ? top->sc_cmds : top->hc_cmds;
}

unsigned sim_card_blocks_written(int which)
{
    return (which == SIM_CARD_SC) ? top->sc_blocks_wr : top->hc_blocks_wr;
}

unsigned sim_dma_beats(void) { return top->dma_beats; }
unsigned sim_read_holds(void) { return top->read_holds; }

unsigned sim_cpu_cycles(void) { return cpu_cycles; }

unsigned sim_card_peek(int which, unsigned byte_addr)
{
    svSetScope(top_scope);
    return drv_card_peek(static_cast<unsigned>(which), byte_addr);
}

void sim_card_poke(int which, unsigned byte_addr, unsigned data)
{
    svSetScope(top_scope);
    drv_card_poke(static_cast<unsigned>(which), byte_addr, data);
}

unsigned sim_card_busy(int which)
{
    svSetScope(top_scope);
    return drv_card_busy(static_cast<unsigned>(which));
}

void sim_card_set_prog_bytes(int which, unsigned byte_times)
{
    svSetScope(top_scope);
    drv_card_set_prog(static_cast<unsigned>(which), byte_times);
}

int sim_cfg_dma(void)          { return SDCARD_CFG_DMA; }
int sim_cfg_card_detect(void)  { return SDCARD_CFG_CD; }

unsigned long long sim_cycles(void)       { return cycles; }
unsigned long long sim_bus_accesses(void) { return accesses; }

void sim_idle(unsigned n)
{
    while (n--) {
        tick();
        service_irq();
    }
}

// Budgets are written for the default processor speed. A slower one spends
// proportionally longer in every loop the driver runs, so the budget scales
// with it - never below the budget as written.
void sim_budget(const char *test, unsigned long long n)
{
    unsigned long long scale = (cpu_cycles + 1u + 3u) / 4u;
    budget_owner = test;
    deadline     = cycles + n * (scale ? scale : 1u);
}

} // extern "C"

// ---------------------------------------------------------------------------
// Start-up
// ---------------------------------------------------------------------------
static int g_argc;
static char **g_argv;
static int g_rc;

static void *run(void *)
{
    // The address checks, before the core is trusted with a pointer.
    int on_stack = 0;
    static int in_bss;
    if (SDCARD_CFG_DMA &&
        (reinterpret_cast<uintptr_t>(&on_stack) > UINT32_MAX ||
         reinterpret_cast<uintptr_t>(&in_bss)   > UINT32_MAX)) {
        std::printf("harness: NOT RUN - stack %p or data %p is above 4 GiB, where "
                    "the DMA cannot address it. This build needs Linux x86-64 "
                    "(MAP_32BIT, -no-pie).\n",
                    static_cast<void *>(&on_stack), static_cast<void *>(&in_bss));
        g_rc = 2;
        return nullptr;
    }

    ctx = new VerilatedContext;
    ctx->commandArgs(g_argc, g_argv);
    top = new Top{ctx};

    const char *arg = ctx->commandArgsPlusMatch("cpu=");
    if (arg && *arg) cpu_cycles = static_cast<unsigned>(std::atoi(arg + 5));

    top_scope = svGetScopeFromName("TOP.avalon_mm_sdcard_controller_drv_top");
    if (!top_scope) {
        std::printf("harness error: DPI scope not found\n");
        g_rc = 2;
        return nullptr;
    }

    top->reset_n = 0;
    top->card_sel = SIM_CARD_NONE;
    for (int i = 0; i < 8; i++) tick();
    top->reset_n = 1;
    for (int i = 0; i < 8; i++) tick();

    std::printf("driver harness: DMA %s, card detect %s, %u CPU cycles per access\n",
                SDCARD_CFG_DMA ? "on" : "off", SDCARD_CFG_CD ? "on" : "off",
                cpu_cycles);

    g_rc = driver_tests();

    top->final();
    std::printf("  (%llu clock cycles, %llu bus accesses)\n",
                static_cast<unsigned long long>(cycles),
                static_cast<unsigned long long>(accesses));
    delete top;
    delete ctx;
    return nullptr;
}

int main(int argc, char **argv)
{
    g_argc = argc;
    g_argv = argv;

#ifdef MAP_32BIT
    const int low = MAP_32BIT;
#else
    const int low = 0;          // the start-up check decides whether that is enough
#endif
    const size_t stack_size = 16u << 20;
    void *stack = mmap(nullptr, stack_size, PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANONYMOUS | low, -1, 0);
    if (stack == MAP_FAILED) {
        std::perror("mmap");
        return 2;
    }

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstack(&attr, stack, stack_size);

    pthread_t th;
    if (pthread_create(&th, &attr, run, nullptr) != 0) {
        std::perror("pthread_create");
        return 2;
    }
    pthread_join(th, nullptr);
    return g_rc;
}
