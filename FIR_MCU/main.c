/**
 * @file main.c
 * @brief System entry point and main event loop for Renesas RA6E2 MCU FIR filtering.
 */

#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "bsp_timer.h"
#include "bsp_uart.h"
#include "protocol.h"
#include "audio_stream_manager.h"

/* Scratch buffers for packet serialization */
static uint8_t           s_rx_raw_buffer[PROTOCOL_MAX_PACKET_SIZE];
static size_t            s_rx_raw_len = 0U;
static protocol_packet_t s_rx_packet;
static protocol_packet_t s_tx_packet;

/**
 * @brief Searches the incoming byte stream for complete and validated protocol frames.
 * 
 * @param out_packet Pointer to destination packet structure if a complete packet is decoded.
 * @return true if a complete, valid packet was extracted; false otherwise.
 */
static bool poll_and_parse_packet(protocol_packet_t *out_packet)
{
    uint8_t byte = 0U;

    /* Pull any pending bytes out of the UART ring buffer */
    while (bsp_uart_read_byte(&byte))
    {
        if (s_rx_raw_len < sizeof(s_rx_raw_buffer))
        {
            s_rx_raw_buffer[s_rx_raw_len++] = byte;
        }
        else
        {
            /* Buffer overflow safeguard: discard leading byte to slide window */
            memmove(&s_rx_raw_buffer[0], &s_rx_raw_buffer[1], sizeof(s_rx_raw_buffer) - 1U);
            s_rx_raw_buffer[sizeof(s_rx_raw_buffer) - 1U] = byte;
        }

        /* 1. Locate magic synchronization bytes */
        while (s_rx_raw_len >= 2U)
        {
            if ((s_rx_raw_buffer[0] == PROTOCOL_MAGIC_BYTE0) && 
                (s_rx_raw_buffer[1] == PROTOCOL_MAGIC_BYTE1))
            {
                break;
            }
            /* Discard non-magic prefix byte */
            memmove(&s_rx_raw_buffer[0], &s_rx_raw_buffer[1], s_rx_raw_len - 1U);
            s_rx_raw_len--;
        }

        /* 2. Wait until full header is present */
        if (s_rx_raw_len < PROTOCOL_HEADER_SIZE)
        {
            continue;
        }

        const protocol_header_t *hdr = (const protocol_header_t *)s_rx_raw_buffer;
        uint16_t payload_len = hdr->payload_len;

        /* Reject absurd payload lengths that exceed maximum allowable block size */
        if (payload_len > PROTOCOL_MAX_PAYLOAD_BYTES)
        {
            memmove(&s_rx_raw_buffer[0], &s_rx_raw_buffer[2], s_rx_raw_len - 2U);
            s_rx_raw_len -= 2U;
            continue;
        }

        /* Total required bytes = Header + Payload + 2-byte CRC */
        size_t expected_total_len = (size_t)PROTOCOL_HEADER_SIZE + (size_t)payload_len + (size_t)PROTOCOL_CRC_SIZE;

        if (s_rx_raw_len < expected_total_len)
        {
            /* Still waiting for the full payload/CRC to arrive */
            continue;
        }

        /* 3. Validate entire packet integrity with CRC-16 */
        bool valid = protocol_validate_packet(s_rx_raw_buffer, expected_total_len);

        if (valid)
        {
            /* Copy into structured container */
            memcpy(out_packet, s_rx_raw_buffer, expected_total_len);

            /* Shift any trailing surplus bytes to the front of the receive buffer */
            size_t remaining = s_rx_raw_len - expected_total_len;
            if (remaining > 0U)
            {
                memmove(&s_rx_raw_buffer[0], &s_rx_raw_buffer[expected_total_len], remaining);
            }
            s_rx_raw_len = remaining;
            return true;
        }
        else
        {
            /* CRC error: discard false magic word and resume searching */
            memmove(&s_rx_raw_buffer[0], &s_rx_raw_buffer[2], s_rx_raw_len - 2U);
            s_rx_raw_len -= 2U;
        }
    }

    return false;
}

/**
 * @brief Primary application entry point for Renesas Flexible Software Package (FSP).
 *        Called automatically after startup clocks and BSP registers initialize.
 */
void hal_entry(void)
{
    /* 1. Bring up profiling timer */
    bsp_timer_init();

    /* 2. Bring up UART peripheral */
    bsp_uart_init();

    /* 3. Initialize Audio Stream Manager for Stereo (2 channels) */
    audio_stream_manager_init(2U);

    s_rx_raw_len = 0U;

    /* 4. Main Event Processing Loop */
    while (1)
    {
        /* Poll and process inbound serial packets */
        if (poll_and_parse_packet(&s_rx_packet))
        {
            /* Process audio chunk through FIR filter and format ACK reply */
            size_t tx_len = audio_stream_manager_process_packet(&s_rx_packet, &s_tx_packet);

            if (tx_len > 0U)
            {
                /* Transmit acknowledgment and filtered samples back to host */
                bsp_uart_write((const uint8_t *)&s_tx_packet, tx_len);
            }
        }
    }
}

#if !defined(RENESAS_FSP)
/**
 * @brief Standard C main entry point for standalone builds.
 */
int main(void)
{
    hal_entry();
    return 0;
}
#endif