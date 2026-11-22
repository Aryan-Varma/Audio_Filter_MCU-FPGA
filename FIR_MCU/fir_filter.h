/**
 * @file fir_filter.h
 * @brief Fixed-point Q1.15 direct-form FIR filter kernel interface.
 *        Maintains persistent history across block boundaries.
 */

#ifndef FIR_FILTER_H
#define FIR_FILTER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Maximum filter tap length supported in memory */
#define FIR_MAX_TAPS        (129)
#define FIR_MAX_CHANNELS    (2)

/**
 * @brief Circular delay-line history state for a single audio channel.
 */
typedef struct {
    int16_t  history[FIR_MAX_TAPS];  /* Circular sample buffer */
    uint16_t head;                   /* Insertion index for newest sample */
} fir_channel_state_t;

/**
 * @brief Top-level FIR filter instance descriptor.
 */
typedef struct {
    const int16_t       *taps;                            /* Pointer to flash-resident Q1.15 weights */
    uint16_t            num_taps;                        /* Active tap count (<= FIR_MAX_TAPS) */
    uint8_t             num_channels;                    /* 1 for Mono, 2 for Stereo */
    fir_channel_state_t channel_state[FIR_MAX_CHANNELS]; /* Independent state per channel */
} fir_filter_t;

/**
 * @brief Initializes a FIR filter instance with coefficient pointers and channel layout.
 *        Zeroes the internal delay lines.
 * 
 * @param filter Pointer to FIR filter instance.
 * @param taps Pointer to array of Q1.15 coefficients in memory/flash.
 * @param num_taps Number of taps (must be <= FIR_MAX_TAPS).
 * @param num_channels Number of audio channels (1 or 2).
 * @return true on valid configuration; false if parameters exceed limits.
 */
bool fir_filter_init(
    fir_filter_t  *filter,
    const int16_t *taps,
    uint16_t       num_taps,
    uint8_t        num_channels
);

/**
 * @brief Clears the delay-line histories to zero without reconfiguring taps.
 *        Invoked when starting a new stream sequence.
 * 
 * @param filter Pointer to FIR filter instance.
 */
void fir_filter_reset(fir_filter_t *filter);

/**
 * @brief Executes fixed-point FIR filtering over an interleaved block of PCM16 samples.
 *        Updates internal circular history so convolution continues seamlessly across calls.
 * 
 * @param filter Pointer to initialized FIR filter instance.
 * @param input Pointer to input buffer containing signed 16-bit PCM samples.
 * @param output Pointer to destination buffer where filtered PCM16 samples will be written.
 * @param num_frames Number of audio frames to process (each frame contains num_channels samples).
 */
void fir_filter_process(
    fir_filter_t  *filter,
    const int16_t *input,
    int16_t       *output,
    size_t         num_frames
);

/**
 * @brief Helper function: rounds a 64-bit signed accumulator to Q1.15 and saturates to int16.
 *        Follows round-to-nearest with ties away from zero.
 * 
 * @param acc Signed 64-bit accumulator value.
 * @return Saturated and rounded signed 16-bit output sample.
 */
int16_t fir_round_and_saturate_q15(int64_t acc);

#ifdef __cplusplus
}
#endif

#endif /* FIR_FILTER_H */