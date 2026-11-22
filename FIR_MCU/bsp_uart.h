/**
 * @file bsp_uart.h
 * @brief Board Support Package UART driver interface for Renesas RA6E2.
 *        Wraps Renesas FSP SCI UART for buffered serial communication.
 */

#ifndef BSP_UART_H
#define BSP_UART_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Circular reception ring buffer capacity (must accommodate at least 2 full packets) */
#define BSP_UART_RX_BUFFER_SIZE     (1024)

/**
 * @brief Initializes the SCI UART peripheral via Renesas FSP and sets up the RX ring buffer.
 * 
 * @return true on successful initialization and peripheral open; false otherwise.
 */
bool bsp_uart_init(void);

/**
 * @brief Checks the number of valid bytes currently available in the RX ring buffer.
 * 
 * @return Number of readable bytes.
 */
size_t bsp_uart_available(void);

/**
 * @brief Reads up to max_len bytes from the RX ring buffer into the destination buffer.
 * 
 * @param dest Pointer to destination memory buffer.
 * @param max_len Maximum number of bytes to retrieve.
 * @return Actual number of bytes read.
 */
size_t bsp_uart_read(uint8_t *dest, size_t max_len);

/**
 * @brief Reads a single byte from the RX ring buffer if available.
 * 
 * @param byte Pointer to output uint8_t container.
 * @return true if a byte was read; false if the ring buffer is empty.
 */
bool bsp_uart_read_byte(uint8_t *byte);

/**
 * @brief Transmits a byte sequence over UART.
 * 
 * @param data Pointer to data bytes to transmit.
 * @param len Number of bytes to send.
 * @return true if transmission completed successfully; false on error.
 */
bool bsp_uart_write(const uint8_t *data, size_t len);

/**
 * @brief Clears and discards all pending unread bytes from the RX ring buffer.
 */
void bsp_uart_flush_rx(void);

#ifdef __cplusplus
}
#endif

#endif /* BSP_UART_H */