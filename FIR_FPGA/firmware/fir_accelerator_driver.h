#ifndef FIR_ACCELERATOR_DRIVER_H
#define FIR_ACCELERATOR_DRIVER_H

#include "hal_data.h"
#include <stdint.h>
#include <stdbool.h>

// Protocol Constants
#define FIR_MAGIC_BYTE          ((uint8_t)0xA5)
#define FIR_CMD_STATUS          ((uint8_t)0x01)
#define FIR_CMD_WRITE_COEFF     ((uint8_t)0x02)
#define FIR_CMD_COMMIT          ((uint8_t)0x03)
#define FIR_CMD_SUBMIT          ((uint8_t)0x04)
#define FIR_CMD_READ_RESULT     ((uint8_t)0x05)
#define FIR_CMD_RESET_STREAM    ((uint8_t)0x06)

// Audio Buffer Dimensions
#define AUDIO_FRAMES_PER_BLOCK  (64)
#define AUDIO_CHANNELS          (2)
#define AUDIO_SAMPLES_PER_BLOCK (AUDIO_FRAMES_PER_BLOCK * AUDIO_CHANNELS) // 128 samples
#define AUDIO_BYTES_PER_BLOCK   (AUDIO_SAMPLES_PER_BLOCK * sizeof(int16_t)) // 256 bytes

// Status Flags returned by FPGA
typedef struct {
    bool input_fifo_full;
    bool result_ready;
} fir_fpga_status_t;

// Public Driver API
fsp_err_t fir_accelerator_init(void);
fsp_err_t fir_reset_stream(uint8_t epoch);
fsp_err_t fir_load_coefficients(uint8_t epoch, const int16_t *coeffs, uint16_t num_taps);
fsp_err_t fir_commit_coefficients(uint8_t epoch);
fsp_err_t fir_process_block(uint8_t epoch, uint8_t seq_num, 
                            const int16_t *input_samples, 
                            int16_t *output_samples);
fsp_err_t fir_get_status(fir_fpga_status_t *status);

#endif // FIR_ACCELERATOR_DRIVER_H