/**
 * @file protocol.h
 * @brief Binary packet protocol definitions for host-to-MCU UART communication.
 *        Compatible with uart_protocol.py on the PC host.
 */

#ifndef PROTOCOL_H
#define PROTOCOL_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Protocol Synchronization Constants */
#define PROTOCOL_MAGIC_BYTE0       (0x5A)
#define PROTOCOL_MAGIC_BYTE1       (0xA5)
#define PROTOCOL_VERSION           (0x01)

/* Message Type Codes */
#define MSG_TYPE_DATA              (0x01)   /* Inbound audio PCM chunk */
#define MSG_TYPE_RESET             (0x02)   /* Reset filter history buffer */
#define MSG_TYPE_ACK               (0x03)   /* Outbound filtered audio response */
#define MSG_TYPE_ERROR             (0xFF)   /* Packet or CRC error response */

/* Sizing and Limits */
#define PROTOCOL_MAX_CHANNELS      (2)
#define PROTOCOL_BYTES_PER_SAMPLE  (2)      /* Signed 16-bit PCM */
#define PROTOCOL_MAX_BLOCK_FRAMES  (64)     /* 64 frames per chunk block */

/* 64 frames * 2 channels * 2 bytes/sample = 256 bytes */
#define PROTOCOL_MAX_PAYLOAD_BYTES (PROTOCOL_MAX_BLOCK_FRAMES * PROTOCOL_MAX_CHANNELS * PROTOCOL_BYTES_PER_SAMPLE)

#define PROTOCOL_HEADER_SIZE       (11)
#define PROTOCOL_CRC_SIZE          (2)
#define PROTOCOL_MAX_PACKET_SIZE   (PROTOCOL_HEADER_SIZE + PROTOCOL_MAX_PAYLOAD_BYTES + PROTOCOL_CRC_SIZE)

#pragma pack(push, 1)

/**
 * @brief 11-byte binary packet header structure.
 */
typedef struct {
    uint8_t  magic[2];       /* {0x5A, 0xA5} */
    uint8_t  version;        /* PROTOCOL_VERSION */
    uint8_t  msg_type;       /* MSG_TYPE_* */
    uint8_t  stream_id;      /* Active stream identifier */
    uint16_t seq_num;        /* Zero-indexed chunk sequence number */
    uint16_t frame_count;    /* Valid audio frames inside payload */
    uint16_t payload_len;    /* Payload byte count (frame_count * channels * 2) */
} protocol_header_t;

/**
 * @brief Complete packet structure container.
 */
typedef struct {
    protocol_header_t header;
    uint8_t           payload[PROTOCOL_MAX_PAYLOAD_BYTES];
    uint16_t          crc;
} protocol_packet_t;

#pragma pack(pop)

/**
 * @brief Computes CRC-16-CCITT (Poly: 0x1021, Init: 0xFFFF) over a byte sequence.
 * 
 * @param data Pointer to input byte buffer.
 * @param length Byte length to process.
 * @param initial_crc Initial seed value (typically 0xFFFF).
 * @return Computed 16-bit CRC checksum.
 */
uint16_t protocol_crc16(const uint8_t *data, size_t length, uint16_t initial_crc);

/**
 * @brief Validates whether a raw byte buffer contains a valid packet and matching CRC.
 * 
 * @param buffer Pointer to raw received packet bytes.
 * @param total_len Total received byte count.
 * @return true if magic, length, and CRC-16 are valid; false otherwise.
 */
bool protocol_validate_packet(const uint8_t *buffer, size_t total_len);

/**
 * @brief Packs an outbound acknowledgment or error packet with header and CRC.
 * 
 * @param out_packet Pointer to destination packet structure.
 * @param msg_type MSG_TYPE_ACK or MSG_TYPE_ERROR.
 * @param stream_id Active stream ID.
 * @param seq_num Sequence number being responded to.
 * @param frame_count Number of valid audio frames in payload.
 * @param payload Pointer to raw output PCM payload bytes (can be NULL if length is 0).
 * @param payload_len Length of output payload in bytes.
 * @return Total packet length in bytes (header + payload + CRC).
 */
size_t protocol_build_packet(
    protocol_packet_t *out_packet,
    uint8_t            msg_type,
    uint8_t            stream_id,
    uint16_t           seq_num,
    uint16_t           frame_count,
    const uint8_t     *payload,
    uint16_t           payload_len
);

#ifdef __cplusplus
}
#endif

#endif /* PROTOCOL_H */