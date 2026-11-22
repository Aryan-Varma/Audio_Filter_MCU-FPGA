/**
 * @file fir_filter.c
 * @brief Fixed-point Q1.15 direct-form FIR filter kernel implementation.
 */

#include "fir_filter.h"
#include <string.h>

int16_t fir_round_and_saturate_q15(int64_t acc)
{
    /* Determine sign and absolute value */
    int64_t sign = (acc < 0) ? -1LL : ((acc > 0) ? 1LL : 0LL);
    int64_t abs_acc = (acc < 0) ? -acc : acc;

    /* Round to nearest with ties away from zero: (abs + 2^14) / 2^15 */
    int64_t rounded = (abs_acc + 16384LL) >> 15;
    int64_t result = sign * rounded;

    /* Saturate within signed 16-bit limits */
    if (result > 32767LL)
    {
        return 32767;
    }
    if (result < -32768LL)
    {
        return -32768;
    }

    return (int16_t)result;
}

bool fir_filter_init(
    fir_filter_t  *filter,
    const int16_t *taps,
    uint16_t       num_taps,
    uint8_t        num_channels
)
{
    if ((filter == NULL) || (taps == NULL))
    {
        return false;
    }

    if ((num_taps == 0U) || (num_taps > FIR_MAX_TAPS))
    {
        return false;
    }

    if ((num_channels != 1U) && (num_channels != 2U))
    {
        return false;
    }

    filter->taps         = taps;
    filter->num_taps     = num_taps;
    filter->num_channels = num_channels;

    fir_filter_reset(filter);
    return true;
}

void fir_filter_reset(fir_filter_t *filter)
{
    if (filter == NULL)
    {
        return;
    }

    for (uint8_t ch = 0; ch < FIR_MAX_CHANNELS; ++ch)
    {
        memset(filter->channel_state[ch].history, 0, sizeof(filter->channel_state[ch].history));
        filter->channel_state[ch].head = 0U;
    }
}

void fir_filter_process(
    fir_filter_t  *filter,
    const int16_t *input,
    int16_t       *output,
    size_t         num_frames
)
{
    if ((filter == NULL) || (input == NULL) || (output == NULL) || (num_frames == 0U))
    {
        return;
    }

    const uint16_t num_taps     = filter->num_taps;
    const uint8_t  num_channels = filter->num_channels;
    const int16_t *taps         = filter->taps;

    for (size_t f = 0; f < num_frames; ++f)
    {
        for (uint8_t ch = 0; ch < num_channels; ++ch)
        {
            fir_channel_state_t *ch_state = &filter->channel_state[ch];
            int16_t new_sample = input[f * num_channels + ch];

            /* Write newest sample at current circular head pointer */
            ch_state->history[ch_state->head] = new_sample;

            /* Direct-form convolution sum using 64-bit accumulator */
            int64_t acc = 0;
            uint16_t head = ch_state->head;

            for (uint16_t k = 0; k < num_taps; ++k)
            {
                /* Sample k positions older than head in circular buffer */
                uint16_t sample_idx = (head >= k) ? (uint16_t)(head - k) : (uint16_t)(head + num_taps - k);
                acc += (int64_t)ch_state->history[sample_idx] * (int64_t)taps[k];
            }

            /* Advance circular head pointer modulo N */
            ch_state->head = (uint16_t)((ch_state->head + 1U) % num_taps);

            /* Round and saturate into 16-bit output */
            output[f * num_channels + ch] = fir_round_and_saturate_q15(acc);
        }
    }
}