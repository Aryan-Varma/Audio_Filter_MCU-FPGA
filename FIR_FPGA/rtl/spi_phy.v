`timescale 1ns / 1ps

module spi_phy (
    input  wire       clk,             // Internal FPGA system clock (100 MHz)
    input  wire       rst_n,           // Active-low asynchronous reset

    // --- Physical SPI Pins from Board Headers ---
    input  wire       spi_sclk,        // Serial Clock from MCU
    input  wire       spi_cs_n,        // Active-low Chip Select from MCU
    input  wire       spi_mosi,        // Master Out Slave In
    output reg        spi_miso,        // Master In Slave Out

    // --- Parallel Byte Interface (To Packet Parser) ---
    output reg  [7:0] rx_byte,         // Received parallel byte
    output reg        rx_byte_valid,   // Single-cycle pulse when rx_byte is ready
    input  wire [7:0] tx_byte,         // Next byte to transmit over MISO
    input  wire       tx_byte_load,    // Pulse to load tx_byte into shift register

    // --- Transaction Status ---
    output wire       trans_active,    // High while CS_N is asserted (low)
    output wire       trans_start,     // Pulse when CS_N falls
    output wire       trans_end        // Pulse when CS_N rises (end or abort)
);

    // -------------------------------------------------------------
    // Stage 1: 2-Stage Flip-Flop Synchronizers (CDC Protection)
    // -------------------------------------------------------------
    reg [2:0] sclk_sync;
    reg [2:0] cs_n_sync;
    reg [1:0] mosi_sync;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sclk_sync <= 3'b000;
            cs_n_sync <= 3'b111;
            mosi_sync <= 2'b00;
        end else begin
            sclk_sync <= {sclk_sync[1:0], spi_sclk};
            cs_n_sync <= {cs_n_sync[1:0], spi_cs_n};
            mosi_sync <= {mosi_sync[0],   spi_mosi};
        end
    end

    // Detect edges on synchronized signals
    wire sclk_rising  = (sclk_sync[2:1] == 2'b01);
    wire sclk_falling = (sclk_sync[2:1] == 2'b10);
    wire cs_falling   = (cs_n_sync[2:1] == 2'b10);
    wire cs_rising    = (cs_n_sync[2:1] == 2'b01);
    wire cs_active    = ~cs_n_sync[1]; // CS is low

    assign trans_active = cs_active;
    assign trans_start  = cs_falling;
    assign trans_end    = cs_rising;

    // -------------------------------------------------------------
    // Stage 2: Reception Logic (MOSI Deserializer)
    // -------------------------------------------------------------
    reg [2:0] bit_rx_cnt;
    reg [7:0] rx_shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_rx_cnt    <= 3'd0;
            rx_shift_reg  <= 8'd0;
            rx_byte       <= 8'd0;
            rx_byte_valid <= 1'b0;
        end else begin
            rx_byte_valid <= 1'b0;

            if (!cs_active) begin
                // Reset receiver whenever CS_N is deasserted (high)
                bit_rx_cnt   <= 3'd0;
                rx_shift_reg <= 8'd0;
            end else if (sclk_rising) begin
                // Sample MOSI on rising edge (SPI Mode 0 standard)
                rx_shift_reg <= {rx_shift_reg[6:0], mosi_sync[1]};
                
                if (bit_rx_cnt == 3'd7) begin
                    // Completed 8 bits: publish full byte
                    rx_byte       <= {rx_shift_reg[6:0], mosi_sync[1]};
                    rx_byte_valid <= 1'b1;
                    bit_rx_cnt    <= 3'd0;
                end else begin
                    bit_rx_cnt    <= bit_rx_cnt + 1'b1;
                end
            end
        end
    end

    // -------------------------------------------------------------
    // Stage 3: Transmission Logic (MISO Serializer)
    // -------------------------------------------------------------
    reg [7:0] tx_shift_reg;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_shift_reg <= 8'd0;
            spi_miso     <= 1'b0;
        end else begin
            if (tx_byte_load) begin
                tx_shift_reg <= tx_byte;
            end

            if (!cs_active) begin
                spi_miso <= 1'b0; // High-Z or driving 0 when idle
            end else if (sclk_falling) begin
                // Drive next bit on falling edge so master can sample on next rising edge
                spi_miso     <= tx_shift_reg[7];
                tx_shift_reg <= {tx_shift_reg[6:0], 1'b0};
            end
        end
    end

endmodule