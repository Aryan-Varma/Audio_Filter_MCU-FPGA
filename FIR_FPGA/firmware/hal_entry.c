#include "hal_data.h"
#include "fir_accelerator_driver.h"
#include <string.h>

#define UART_BUF_SIZE           256
static uint8_t g_uart_rx_buf[UART_BUF_SIZE];
static uint8_t g_uart_tx_buf[UART_BUF_SIZE];
static volatile bool g_uart_rx_done = false;
static volatile bool g_uart_tx_done = false;

// UART Callback
void g_uart0_callback(uart_callback_args_t *p_args) {
    if (p_args->event == UART_EVENT_RX_COMPLETE) {
        g_uart_rx_done = true;
    } else if (p_args->event == UART_EVENT_TX_COMPLETE) {
        g_uart_tx_done = true;
    }
}

void hal_entry(void) {
    // 1. Initialize SPI accelerator driver
    fir_accelerator_init();
    R_SCI_UART_Open(&g_uart0_ctrl, &g_uart0_cfg);

    // 2. Reset FPGA stream
    fir_reset_stream(1);

    uint8_t sync_hdr[4];
    uint8_t epoch = 1;

    while (1) {
        // Read 4-byte header: 0x5A, 0xA5, BlockNum LSB, BlockNum MSB
        g_uart_rx_done = false;
        R_SCI_UART_Read(&g_uart0_ctrl, sync_hdr, 4);
        while (!g_uart_rx_done);

        if (sync_hdr[0] == 0x5A && sync_hdr[1] == 0xA5) {
            uint8_t seq = sync_hdr[2];

            // Read the 256-byte incoming audio block from PC
            g_uart_rx_done = false;
            R_SCI_UART_Read(&g_uart0_ctrl, g_uart_rx_buf, AUDIO_BYTES_PER_BLOCK);
            while (!g_uart_rx_done);

            // Forward block to ZedBoard FPGA over SPI and get filtered result
            fir_process_block(epoch, seq, 
                              (const int16_t *)g_uart_rx_buf, 
                              (int16_t *)g_uart_tx_buf);

            // Send 256-byte filtered audio back to PC
            g_uart_tx_done = false;
            R_SCI_UART_Write(&g_uart0_ctrl, g_uart_tx_buf, AUDIO_BYTES_PER_BLOCK);
            while (!g_uart_tx_done);
        }
    }
}