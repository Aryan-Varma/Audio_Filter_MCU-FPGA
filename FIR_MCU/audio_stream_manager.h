/**
 * @file audio_stream_manager.h
 * @brief Coordinates data movement between UART packet protocol and FIR filter engine.
 */

#ifndef AUDIO_STREAM_MANAGER_H
#define AUDIO_STREAM_MANAGER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include "protocol.h"
#include "fir_filter.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * @brief Performance and telemetry statistics for stream diagnostics.
 */
typedef struct {
    uint32_t blocks_processed;        /* Total data blocks filtered */
    uint32_t frames_processed;        /* Total audio frames filtered */
    uint32_t stream_resets;           /* Total stream resets handled */
    uint32_t sequence_errors;         /* Out-of-order or duplicate sequences */
    uint32_t last_process_time_us;    /* Processing duration of last block in microseconds */
    uint32_t max_process_time_us;     /* Peak block processing duration observed */
} audio_stream_stats_t;

/**
 * @brief Initializes the stream manager, binds the FIR filter taps from flash,
 *        and prepares internal state.
 * 
 * @param channels Number of audio channels (1 for Mono, 2 for Stereo).
 * @return true on success; false if tap or channel parameters are invalid.
 */
bool audio_stream_manager_init(uint8_t channels);

/**
 * @brief Resets stream history, re-zeros FIR delay lines, and clears sequence tracking.
 */
void audio_stream_manager_reset(void);

/**
 * @brief Processes an inbound protocol packet and constructs the corresponding outbound response.
 * 
 * Handles MSG_TYPE_DATA by filtering PCM samples and populating MSG_TYPE_ACK.
 * Handles MSG_TYPE_RESET by re-zeroing filter history.
 * Generates MSG_TYPE_ERROR for malformed payloads or invalid requests.
 * 
 * @param rx_pkt Pointer to validated inbound packet.
 * @param tx_pkt Pointer to destination buffer for outbound packet.
 * @return Total byte length of the constructed tx_pkt (including header and CRC).
 */
size_t audio_stream_manager_process_packet(
    const protocol_packet_t *rx_pkt,
    protocol_packet_t       *tx_pkt
);

/**
 * @brief Retrieves the current performance and telemetry metrics.
 * 
 * @return Pointer to read-only statistics structure.
 */
const audio_stream_stats_t* audio_stream_manager_get_stats(void);

#ifdef __cplusplus
}
#endif

#endif /* AUDIO_STREAM_MANAGER_H */