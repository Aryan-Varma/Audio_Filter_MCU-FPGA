#include "fir_accelerator_driver.h"

// Define GPIO pins according to your RA6E2 Board Wiring
// Example mapping using Port 1 pins:
#define FPGA_CS_PIN      BSP_IO_PORT_01_PIN_03  // Connected to ZedBoard JA1 (Y11)
#define FPGA_READY_PIN   BSP_IO_PORT_01_PIN_04  // Connected to ZedBoard JA7 (AB11)

static volatile bool g_spi_tx_complete = false;
static volatile bool g_spi_rx_complete = false;

// -----------------------------------------------------------------
// SPI Callback: Invoked by FSP r_spi on transfer completion
// -----------------------------------------------------------------
void g_spi0_callback(spi_callback_args_t *p_args) {
    if (p_args->event == SPI_EVENT_TRANSFER_COMPLETE) {
        g_spi_tx_complete = true;
        g_spi_rx_complete = true;
    }
}

// -----------------------------------------------------------------
// Internal Helper: Blocking SPI write/read via FSP
// -----------------------------------------------------------------
static fsp_err_t spi_transfer_blocking(const uint8_t *tx_buf, uint8_t *rx_buf, uint32_t len) {
    g_spi_tx_complete = false;
    g_spi_rx_complete = false;

    fsp_err_t err;
    if (rx_buf != NULL && tx_buf != NULL) {
        err = R_SPI_WriteRead(&g_spi0_ctrl, tx_buf, rx_buf, len, SPI_BIT_WIDTH_8_BITS);
    } else if (tx_buf != NULL) {
        err = R_SPI_Write(&g_spi0_ctrl, tx_buf, len, SPI_BIT_WIDTH_8_BITS);
    } else if (rx_buf != NULL) {
        err = R_SPI_Read(&g_spi0_ctrl, rx_buf, len, SPI_BIT_WIDTH_8_BITS);
    } else {
        return FSP_ERR_INVALID_POINTER;
    }

    if (err != FSP_SUCCESS) {
        return err;
    }

    // Wait for DMA or interrupt to signal transfer complete
    uint32_t timeout = 500000;
    while (!g_spi_tx_complete && --timeout);
    return (timeout == 0) ? FSP_ERR_TIMEOUT : FSP_SUCCESS;
}

static inline void cs_assert(void) {
    R_IOPORT_PinWrite(&g_ioport_ctrl, FPGA_CS_PIN, BSP_IO_LEVEL_LOW);
}

static inline void cs_deassert(void) {
    R_IOPORT_PinWrite(&g_ioport_ctrl, FPGA_CS_PIN, BSP_IO_LEVEL_HIGH);
}

// -----------------------------------------------------------------
// Driver Initialization
// -----------------------------------------------------------------
fsp_err_t fir_accelerator_init(void) {
    fsp_err_t err;

    // Initialize SPI peripheral
    err = R_SPI_Open(&g_spi0_ctrl, &g_spi0_cfg);
    if (err != FSP_SUCCESS) return err;

    // Ensure CS is deasserted high
    cs_deassert();

    return FSP_SUCCESS;
}

// -----------------------------------------------------------------
// Reset Stream: Flush History RAM & FIFOs
// -----------------------------------------------------------------
fsp_err_t fir_reset_stream(uint8_t epoch) {
    uint8_t hdr[7];
    uint8_t chksum = FIR_MAGIC_BYTE ^ FIR_CMD_RESET_STREAM ^ epoch ^ 0x00 ^ 0x00 ^ 0x00;

    hdr[0] = FIR_MAGIC_BYTE;
    hdr[1] = FIR_CMD_RESET_STREAM;
    hdr[2] = epoch;
    hdr[3] = 0x00; // seq
    hdr[4] = 0x00; // len MSB
    hdr[5] = 0x00; // len LSB
    hdr[6] = chksum;

    cs_assert();
    fsp_err_t err = spi_transfer_blocking(hdr, NULL, 7);
    cs_deassert();

    // Give FPGA hardware clear engine 25 microseconds to zero out Block RAM
    R_BSP_SoftwareDelay(30, BSP_DELAY_UNITS_MICROSECONDS);
    return err;
}

// -----------------------------------------------------------------
// Write Coefficients into Inactive RAM Bank
// -----------------------------------------------------------------
fsp_err_t fir_load_coefficients(uint8_t epoch, const int16_t *coeffs, uint16_t num_taps) {
    uint16_t payload_bytes = num_taps * 2;
    uint8_t hdr[6];
    uint8_t chksum = FIR_MAGIC_BYTE ^ FIR_CMD_WRITE_COEFF ^ epoch ^ 0x00 ^ 
                     (uint8_t)(payload_bytes >> 8) ^ (uint8_t)(payload_bytes & 0xFF);

    hdr[0] = FIR_MAGIC_BYTE;
    hdr[1] = FIR_CMD_WRITE_COEFF;
    hdr[2] = epoch;
    hdr[3] = 0x00;
    hdr[4] = (uint8_t)(payload_bytes >> 8);
    hdr[5] = (uint8_t)(payload_bytes & 0xFF);

    // Calculate rolling checksum across coefficient payload (Little-Endian)
    for (uint16_t i = 0; i < num_taps; i++) {
        uint8_t low_b  = (uint8_t)(coeffs[i] & 0xFF);
        uint8_t high_b = (uint8_t)((coeffs[i] >> 8) & 0xFF);
        chksum ^= low_b ^ high_b;
    }

    cs_assert();
    spi_transfer_blocking(hdr, NULL, 6);
    spi_transfer_blocking((const uint8_t *)coeffs, NULL, payload_bytes);
    spi_transfer_blocking(&chksum, NULL, 1);
    cs_deassert();

    return FSP_SUCCESS;
}

// -----------------------------------------------------------------
// Atomic Commit: Instantly flips active bank at block boundary
// -----------------------------------------------------------------
fsp_err_t fir_commit_coefficients(uint8_t epoch) {
    uint8_t packet[7];
    uint8_t chksum = FIR_MAGIC_BYTE ^ FIR_CMD_COMMIT ^ epoch ^ 0x00 ^ 0x00 ^ 0x00;

    packet[0] = FIR_MAGIC_BYTE;
    packet[1] = FIR_CMD_COMMIT;
    packet[2] = epoch;
    packet[3] = 0x00;
    packet[4] = 0x00;
    packet[5] = 0x00;
    packet[6] = chksum;

    cs_assert();
    fsp_err_t err = spi_transfer_blocking(packet, NULL, 7);
    cs_deassert();

    return err;
}

// -----------------------------------------------------------------
// Process 64-Frame Audio Block (Submit -> Compute -> Readback)
// -----------------------------------------------------------------
fsp_err_t fir_process_block(uint8_t epoch, uint8_t seq_num, 
                            const int16_t *input_samples, 
                            int16_t *output_samples) {
    fsp_err_t err;

    // 1. Check Hardware Backpressure Pin
    bsp_io_level_t ready_level;
    uint32_t timeout = 50000;
    do {
        R_IOPORT_PinRead(&g_ioport_ctrl, FPGA_READY_PIN, &ready_level);
        if (ready_level == BSP_IO_LEVEL_HIGH) break;
        R_BSP_SoftwareDelay(1, BSP_DELAY_UNITS_MICROSECONDS);
    } while (--timeout);

    if (timeout == 0) {
        return FSP_ERR_TIMEOUT; // FPGA admission control backpressure timed out
    }

    // 2. Transmit SUBMIT Command with 256-Byte Payload
    uint8_t sub_hdr[6];
    uint16_t len = AUDIO_BYTES_PER_BLOCK;
    uint8_t chksum = FIR_MAGIC_BYTE ^ FIR_CMD_SUBMIT ^ epoch ^ seq_num ^ 
                     (uint8_t)(len >> 8) ^ (uint8_t)(len & 0xFF);

    sub_hdr[0] = FIR_MAGIC_BYTE;
    sub_hdr[1] = FIR_CMD_SUBMIT;
    sub_hdr[2] = epoch;
    sub_hdr[3] = seq_num;
    sub_hdr[4] = (uint8_t)(len >> 8);
    sub_hdr[5] = (uint8_t)(len & 0xFF);

    const uint8_t *raw_in = (const uint8_t *)input_samples;
    for (uint16_t i = 0; i < len; i++) {
        chksum ^= raw_in[i];
    }

    cs_assert();
    spi_transfer_blocking(sub_hdr, NULL, 6);
    spi_transfer_blocking(raw_in, NULL, len);
    spi_transfer_blocking(&chksum, NULL, 1);
    cs_deassert();

    // 3. Allow PL Pipeline to compute (128 samples * 129 taps @ 100 MHz ~ 165 us)
    // In production, this wait is replaced by a FreeRTOS task semaphore from EXTI
    R_BSP_SoftwareDelay(180, BSP_DELAY_UNITS_MICROSECONDS);

    // 4. Readback Filtered Result via READ_RESULT
    uint8_t rd_hdr[6];
    rd_hdr[0] = FIR_MAGIC_BYTE;
    rd_hdr[1] = FIR_CMD_READ_RESULT;
    rd_hdr[2] = epoch;
    rd_hdr[3] = seq_num;
    rd_hdr[4] = (uint8_t)(len >> 8);
    rd_hdr[5] = (uint8_t)(len & 0xFF);

    cs_assert();
    spi_transfer_blocking(rd_hdr, NULL, 6);
    err = spi_transfer_blocking(NULL, (uint8_t *)output_samples, len);
    cs_deassert();

    return err;
}