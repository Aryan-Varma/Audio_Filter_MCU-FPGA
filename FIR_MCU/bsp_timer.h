/**
 * @file bsp_timer.h
 * @brief Board Support Package timer interface for high-resolution execution profiling.
 */

#ifndef BSP_TIMER_H
#define BSP_TIMER_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Initializes the hardware profiling timer (SysTick or GPT) and configures
 *        the microsecond timebase.
 * 
 * @return true on successful initialization; false otherwise.
 */
bool bsp_timer_init(void);

/**
 * @brief Retrieves the current monotonically increasing timestamp in microseconds.
 *        Handles timer counter wrap-around internally.
 * 
 * @return Elapsed microseconds since bsp_timer_init() was called.
 */
uint32_t bsp_timer_get_us(void);

/**
 * @brief Performs a busy-wait delay for a specified duration in microseconds.
 * 
 * @param us Duration in microseconds to wait.
 */
void bsp_timer_delay_us(uint32_t us);

#ifdef __cplusplus
}
#endif

#endif /* BSP_TIMER_H */