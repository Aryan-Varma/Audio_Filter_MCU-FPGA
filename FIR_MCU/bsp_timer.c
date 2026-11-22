/**
 * @file bsp_timer.c
 * @brief Board Support Package timer implementation using Cortex-M33 DWT cycle counter.
 */

#include "bsp_timer.h"
#include "hal_data.h"

/* DWT Lock Access Key for ARMv8-M / Cortex-M33 architectures */
#define DWT_LAR_UNLOCK_KEY      (0xC5ACCE55U)

static uint32_t s_cycles_per_us  = 0U;
static uint32_t s_last_cyccnt    = 0U;
static uint64_t s_accumulated_us = 0ULL;
static bool     s_timer_started  = false;

bool bsp_timer_init(void)
{
    /* Calculate clock cycles per microsecond based on active system clock */
    s_cycles_per_us = SystemCoreClock / 1000000U;
    if (s_cycles_per_us == 0U)
    {
        s_cycles_per_us = 1U;
    }

    /* 1. Enable Global Trace in CoreDebug */
    CoreDebug->DEMCR |= CoreDebug_DEMCR_TRCENA_Msk;

    /* 2. Unlock DWT access if Lock Access Register is present (Cortex-M33) */
#if defined(DWT_LAR) || defined(DWT_LAR_LAR_Msk)
    DWT->LAR = DWT_LAR_UNLOCK_KEY;
#endif

    /* 3. Reset and enable DWT cycle counter */
    DWT->CYCCNT = 0U;
    DWT->CTRL  |= DWT_CTRL_CYCCNTENA_Msk;

    s_last_cyccnt    = DWT->CYCCNT;
    s_accumulated_us = 0ULL;
    s_timer_started  = true;

    return true;
}

uint32_t bsp_timer_get_us(void)
{
    if (!s_timer_started)
    {
        return 0U;
    }

    /* Read current cycle count */
    uint32_t current_cyccnt = DWT->CYCCNT;

    /* Unsigned subtraction natively handles 32-bit modulo roll-over */
    uint32_t elapsed_cycles = current_cyccnt - s_last_cyccnt;

    if (elapsed_cycles >= s_cycles_per_us)
    {
        uint32_t elapsed_us = elapsed_cycles / s_cycles_per_us;
        s_accumulated_us += (uint64_t)elapsed_us;

        /* Advance reference by the exact accounted cycles */
        s_last_cyccnt += (elapsed_us * s_cycles_per_us);
    }

    return (uint32_t)s_accumulated_us;
}

void bsp_timer_delay_us(uint32_t us)
{
    uint32_t start_us = bsp_timer_get_us();
    while ((bsp_timer_get_us() - start_us) < us)
    {
        __NOP();
    }
}