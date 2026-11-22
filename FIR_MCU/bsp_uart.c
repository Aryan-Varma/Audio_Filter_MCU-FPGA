/**
 * @file bsp_uart.c
 * @brief Board Support Package UART implementation wrapping Renesas FSP SCI UART.
 */

#include "bsp_uart.h"
#include "hal_data.h"
#include <string.h>

/* Circular Reception Ring Buffer */
static volatile uint8_t  s_rx_buffer[BSP_UART_RX_BUFFER_SIZE];
static volatile uint16_t s_rx_head = 0U;
static volatile uint16_t s_rx_tail = 0U;

/* Transmission synchronization state */
static volatile bool s_tx_busy = false;

/**
 * @brief FSP SCI UART interrupt callback registered in the e² studio configurator.
 * 
 * @param p_args Pointer to UART callback arguments structure.
 */
void user_uart_callback(uart_callback_args_t *p_args)
{
    if (p_args == NULL)
    {
        return;
    }

    switch (p_args->event)
    {
        case UART_EVENT_RX_CHAR:
        {
            /* Calculate next head index */
            uint16_t next_head = (uint16_t)((s_rx_head + 1U) % BSP_UART_RX_BUFFER_SIZE);

            /* If buffer is not full, enqueue incoming byte */
            if (next_head != s_rx_tail)
            {
                s_rx_buffer[s_rx_head] = (uint8_t)p_args->data;
                s_rx_head = next_head;
            }
            break;
        }

        case UART_EVENT_TX_COMPLETE:
        {
            s_tx_busy = false;
            break;
        }

        case UART_EVENT_ERR_PARITY:
        case UART_EVENT_ERR_FRAMING:
        case UART_EVENT_ERR_OVERFLOW:
        default:
            break;
    }
}

bool bsp_uart_init(void)
{
    fsp_err_t err;

    s_rx_head = 0U;
    s_rx_tail = 0U;
    s_tx_busy = false;

    /* Initialize and open default FSP UART instance (g_uart0 generated in ra_gen) */
    err = R_SCI_UART_Open(&g_uart0_ctrl, &g_uart0_cfg);
    if (err != FSP_SUCCESS)
    {
        return false;
    }

    return true;
}

size_t bsp_uart_available(void)
{
    uint16_t head = s_rx_head;
    uint16_t tail = s_rx_tail;

    if (head >= tail)
    {
        return (size_t)(head - tail);
    }
    else
    {
        return (size_t)(BSP_UART_RX_BUFFER_SIZE + head - tail);
    }
}

bool bsp_uart_read_byte(uint8_t *byte)
{
    if ((byte == NULL) || (s_rx_head == s_rx_tail))
    {
        return false;
    }

    *byte = s_rx_buffer[s_rx_tail];
    s_rx_tail = (uint16_t)((s_rx_tail + 1U) % BSP_UART_RX_BUFFER_SIZE);

    return true;
}

size_t bsp_uart_read(uint8_t *dest, size_t max_len)
{
    if ((dest == NULL) || (max_len == 0U))
    {
        return 0U;
    }

    size_t count = 0U;
    while ((count < max_len) && bsp_uart_read_byte(&dest[count]))
    {
        count++;
    }

    return count;
}

bool bsp_uart_write(const uint8_t *data, size_t len)
{
    if ((data == NULL) || (len == 0U))
    {
        return false;
    }

    /* Wait for any preceding transmission to complete */
    uint32_t timeout_loops = 500000U;
    while (s_tx_busy && (--timeout_loops > 0U))
    {
        __NOP();
    }
    if (timeout_loops == 0U)
    {
        return false;
    }

    s_tx_busy = true;

    fsp_err_t err = R_SCI_UART_Write(&g_uart0_ctrl, data, (uint32_t)len);
    if (err != FSP_SUCCESS)
    {
        s_tx_busy = false;
        return false;
    }

    /* Block until current packet transmission finishes */
    timeout_loops = 2000000U;
    while (s_tx_busy && (--timeout_loops > 0U))
    {
        __NOP();
    }

    return (timeout_loops > 0U);
}

void bsp_uart_flush_rx(void)
{
    s_rx_tail = s_rx_head;
}