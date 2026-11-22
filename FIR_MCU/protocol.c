/**
 * @file protocol.c
 * @brief Binary packet protocol implementation for host-to-MCU UART communication.
 */

#include "protocol.h"
#include <string.h>

uint16_t protocol_crc16(const uint8_t *data, size_t length, uint16_t initial_crc)
{
    uint16_t crc = initial_crc;

    for (size_t i = 0; i < length; ++i)
    {
        crc ^= (uint16_t)((uint16_t)data[i] << 8);
        for (uint8_t bit = 0; bit < 8; ++bit)
        {
            if (crc & 0x8000U)
            {
                crc = (uint16_t)((crc << 1) ^ 0x1021U);
            }
            else
            {
                crc = (uint16_t)(crc << 1);
            }
        }
    }

    return crc;
}

bool protocol_validate_packet(const uint8_t *buffer, size_t total_len)
{
    if ((buffer == NULL) || (total_len < (PROTOCOL_HEADER_SIZE + PROTOCOL_CRC_SIZE)))
    {
        return false;
    }

    /* 1. Verify synchronization magic bytes */
    if ((buffer[0] != PROTOCOL_MAGIC_BYTE0) || (buffer[1] != PROTOCOL_MAGIC_BYTE1))
    {
        return false;
    }

    const protocol_header_t *hdr = (const protocol_header_t *)buffer;

    /* 2. Verify protocol version and maximum legal payload bounds */
    if (hdr->version != PROTOCOL_VERSION)
    {
        return false;
    }

    if (hdr->payload_len > PROTOCOL_MAX_PAYLOAD_BYTES)
    {
        return false;
    }

    size_t expected_total_len = (size_t)PROTOCOL_HEADER_SIZE + (size_t)hdr->payload_len + (size_t)PROTOCOL_CRC_SIZE;
    if (total_len != expected_total_len)
    {
        return false;
    }

    /* 3. Compute and compare CRC-16 */
    size_t data_len = (size_t)PROTOCOL_HEADER_SIZE + (size_t)hdr->payload_len;
    uint16_t computed_crc = protocol_crc16(buffer, data_len, 0xFFFFU);

    /* Read received CRC (little-endian byte order) */
    uint16_t rx_crc = (uint16_t)((uint16_t)buffer[data_len] | ((uint16_t)buffer[data_len + 1] << 8));

    return (computed_crc == rx_crc);
}

size_t protocol_build_packet(
    protocol_packet_t *out_packet,
    uint8_t            msg_type,
    uint8_t            stream_id,
    uint16_t           seq_num,
    uint16_t           frame_count,
    const uint8_t     *payload,
    uint16_t           payload_len
)
{
    if (out_packet == NULL)
    {
        return 0;
    }

    if (payload_len > PROTOCOL_MAX_PAYLOAD_BYTES)
    {
        payload_len = PROTOCOL_MAX_PAYLOAD_BYTES;
    }

    /* Populate header fields */
    out_packet->header.magic[0]     = PROTOCOL_MAGIC_BYTE0;
    out_packet->header.magic[1]     = PROTOCOL_MAGIC_BYTE1;
    out_packet->header.version      = PROTOCOL_VERSION;
    out_packet->header.msg_type     = msg_type;
    out_packet->header.stream_id    = stream_id;
    out_packet->header.seq_num      = seq_num;
    out_packet->header.frame_count  = frame_count;
    out_packet->header.payload_len  = payload_len;

    /* Copy payload if present */
    if ((payload != NULL) && (payload_len > 0))
    {
        memcpy(out_packet->payload, payload, payload_len);
    }

    /* Wire position for CRC is immediately after header + active payload */
    uint8_t *wire_bytes = (uint8_t *)out_packet;
    size_t data_len = (size_t)PROTOCOL_HEADER_SIZE + (size_t)payload_len;

    uint16_t crc = protocol_crc16(wire_bytes, data_len, 0xFFFFU);

    /* Append CRC-16 in little-endian order */
    wire_bytes[data_len]     = (uint8_t)(crc & 0xFFU);
    wire_bytes[data_len + 1] = (uint8_t)((crc >> 8) & 0xFFU);

    return data_len + PROTOCOL_CRC_SIZE;
}