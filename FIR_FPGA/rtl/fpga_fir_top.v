`timescale 1ns / 1ps

module fpga_fir_top #(
    parameter DATA_WIDTH  = 16,
    parameter MAX_TAPS    = 2048,
    parameter ADDR_WIDTH  = 11,
    parameter ACCUM_WIDTH = 40,
    parameter DEFAULT_TAPS = 129
)(
    // --- Board Clocks and Resets ---
    input  wire clk,              // 100 MHz onboard oscillator from ZedBoard
    input  wire rst_n,            // Active-low pushbutton / power-on reset

    // --- Physical SPI Interface (Connected to MCU via Header/Pmod) ---
    input  wire spi_sclk,
    input  wire spi_cs_n,
    input  wire spi_mosi,
    output wire spi_miso,

    // --- Hardware Handshake / Backpressure ---
    output wire fpga_ready_irq    // High = ready for next block; Low = backpressure
);

    // -------------------------------------------------------------
    // Internal Wires: SPI PHY <-> Packet Parser
    // -------------------------------------------------------------
    wire [7:0] rx_byte;
    wire       rx_byte_valid;
    wire [7:0] tx_byte;
    wire       tx_byte_load;
    wire       trans_active;
    wire       trans_start;
    wire       trans_end;

    // -------------------------------------------------------------
    // Internal Wires: Packet Parser <-> FIFOs / Memory / Core
    // -------------------------------------------------------------
    wire                  stream_reset;
    wire                  input_fifo_wr_en;
    wire [DATA_WIDTH-1:0] input_fifo_wr_data;
    wire                  submit_job_trigger;
    wire                  coeff_wr_en;
    wire [ADDR_WIDTH-1:0] coeff_wr_addr;
    wire [DATA_WIDTH-1:0] coeff_wr_data;
    wire                  coeff_commit;
    wire [7:0]            current_epoch;
    wire [7:0]            current_seq;

    // -------------------------------------------------------------
    // Internal Wires: Input FIFO <-> Scheduler
    // -------------------------------------------------------------
    wire [DATA_WIDTH-1:0] sample_to_core;
    wire                  sample_rd_en;
    wire                  input_fifo_full;
    wire                  input_fifo_empty;
    wire [8:0]            input_fifo_count;

    // -------------------------------------------------------------
    // Internal Wires: Result FIFO <-> Parser / SPI
    // -------------------------------------------------------------
    wire                  result_has_block;
    wire [7:0]            result_byte_data;
    wire                  result_byte_rd_en;
    wire [9:0]            result_fifo_count;

    // -------------------------------------------------------------
    // Internal Wires: Core Engine Interconnect
    // -------------------------------------------------------------
    wire                  start_core_block;
    wire                  block_done;
    wire                  core_busy;

    // History RAM signals
    wire                  hist_busy;
    wire                  hist_wr_en;
    wire                  hist_wr_channel;
    wire [ADDR_WIDTH-1:0] hist_wr_addr;
    wire [DATA_WIDTH-1:0] hist_wr_data;
    wire                  hist_rd_channel;
    wire [ADDR_WIDTH-1:0] hist_rd_addr;
    wire [DATA_WIDTH-1:0] hist_rd_data;

    // Coefficient RAM signals
    wire [ADDR_WIDTH-1:0] coeff_rd_addr;
    wire [DATA_WIDTH-1:0] coeff_rd_data;
    wire                  active_bank_id;

    // MAC lane signals
    wire                  mac_clr_acc;
    wire                  mac_valid_in;
    wire signed [ACCUM_WIDTH-1:0] mac_accum_out;

    // Reduction / Saturation signals
    wire                  sample_done_out;
    wire                  sample_channel_out;
    wire                  out_valid;
    wire signed [DATA_WIDTH-1:0] sample_out;

    // -------------------------------------------------------------
    // 1. SPI PHY Layer
    // -------------------------------------------------------------
    spi_phy u_spi_phy (
        .clk(clk),
        .rst_n(rst_n),
        .spi_sclk(spi_sclk),
        .spi_cs_n(spi_cs_n),
        .spi_mosi(spi_mosi),
        .spi_miso(spi_miso),
        .rx_byte(rx_byte),
        .rx_byte_valid(rx_byte_valid),
        .tx_byte(tx_byte),
        .tx_byte_load(tx_byte_load),
        .trans_active(trans_active),
        .trans_start(trans_start),
        .trans_end(trans_end)
    );

    // -------------------------------------------------------------
    // 2. Packet Parser & Command Registers
    // -------------------------------------------------------------
    packet_parser #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_packet_parser (
        .clk(clk),
        .rst_n(rst_n),
        .rx_byte(rx_byte),
        .rx_byte_valid(rx_byte_valid),
        .trans_active(trans_active),
        .trans_start(trans_start),
        .trans_end(trans_end),
        .tx_byte(tx_byte),
        .tx_byte_load(tx_byte_load),
        .input_fifo_full(input_fifo_full),
        .result_ready(result_has_block),
        .result_data_byte(result_byte_data),
        .result_rd_en(result_byte_rd_en),
        .stream_reset(stream_reset),
        .input_fifo_wr_en(input_fifo_wr_en),
        .input_fifo_wr_data(input_fifo_wr_data),
        .submit_job_trigger(submit_job_trigger),
        .coeff_wr_en(coeff_wr_en),
        .coeff_wr_addr(coeff_wr_addr),
        .coeff_wr_data(coeff_wr_data),
        .coeff_commit(coeff_commit),
        .current_epoch(current_epoch),
        .current_seq(current_seq)
    );

    // -------------------------------------------------------------
    // 3. Admission Control
    // -------------------------------------------------------------
    admission_control u_admission_control (
        .clk(clk),
        .rst_n(rst_n),
        .input_fifo_count(input_fifo_count),
        .result_fifo_count(result_fifo_count),
        .core_busy(core_busy),
        .submit_trigger(submit_job_trigger),
        .start_core_block(start_core_block),
        .fpga_ready_pin(fpga_ready_irq)
    );

    // -------------------------------------------------------------
    // 4. Input Job FIFO
    // -------------------------------------------------------------
    input_job_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(256),
        .ADDR_WIDTH(8)
    ) u_input_job_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .flush(stream_reset),
        .wr_en(input_fifo_wr_en),
        .wr_data(input_fifo_wr_data),
        .full(input_fifo_full),
        .rd_en(sample_rd_en),
        .rd_data(sample_to_core),
        .empty(input_fifo_empty),
        .count(input_fifo_count)
    );

    // -------------------------------------------------------------
    // 5. Coefficient Ping-Pong RAM
    // -------------------------------------------------------------
    coeff_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_TAPS(MAX_TAPS),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_coeff_ram (
        .clk(clk),
        .rst_n(rst_n),
        .write_en(coeff_wr_en),
        .write_addr(coeff_wr_addr),
        .write_data(coeff_wr_data),
        .commit_swap(coeff_commit),
        .read_addr(coeff_rd_addr),
        .read_data(coeff_rd_data),
        .active_bank_id(active_bank_id)
    );

    // -------------------------------------------------------------
    // 6. Circular History RAM
    // -------------------------------------------------------------
    history_ram #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_TAPS(MAX_TAPS),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) u_history_ram (
        .clk(clk),
        .rst_n(rst_n),
        .stream_reset(stream_reset),
        .busy(hist_busy),
        .wr_en(hist_wr_en),
        .wr_channel(hist_wr_channel),
        .wr_addr(hist_wr_addr),
        .wr_data(hist_wr_data),
        .rd_channel(hist_rd_channel),
        .rd_addr(hist_rd_addr),
        .rd_data(hist_rd_data)
    );

    // -------------------------------------------------------------
    // 7. Core Scheduler
    // -------------------------------------------------------------
    scheduler #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_TAPS(MAX_TAPS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BLOCK_SAMPLES(128)
    ) u_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start_block(start_core_block),
        .configured_taps(ADDR_WIDTH'(DEFAULT_TAPS)),
        .block_done(block_done),
        .core_busy(core_busy),
        .new_sample_data(sample_to_core),
        .sample_rd_en(sample_rd_en),
        .hist_wr_en(hist_wr_en),
        .hist_wr_channel(hist_wr_channel),
        .hist_wr_addr(hist_wr_addr),
        .hist_wr_data(hist_wr_data),
        .hist_rd_channel(hist_rd_channel),
        .hist_rd_addr(hist_rd_addr),
        .coeff_rd_addr(coeff_rd_addr),
        .mac_clr_acc(mac_clr_acc),
        .mac_valid_in(mac_valid_in),
        .sample_done_out(sample_done_out),
        .sample_channel_out(sample_channel_out)
    );

    // -------------------------------------------------------------
    // 8. MAC Engine
    // -------------------------------------------------------------
    mac_lane #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) u_mac_lane (
        .clk(clk),
        .rst_n(rst_n),
        .clr_acc(mac_clr_acc),
        .valid_in(mac_valid_in),
        .sample_in(hist_rd_data),
        .coeff_in(coeff_rd_data),
        .accum_out(mac_accum_out)
    );

    // -------------------------------------------------------------
    // 9. Reduction / Saturation Unit
    // -------------------------------------------------------------
    reduction_saturate #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) u_reduction_saturate (
        .clk(clk),
        .rst_n(rst_n),
        .sample_done(sample_done_out),
        .out_valid(out_valid),
        .accum_in(mac_accum_out),
        .sample_out(sample_out)
    );

    // -------------------------------------------------------------
    // 10. Result FIFO
    // -------------------------------------------------------------
    result_fifo #(
        .DATA_WIDTH(DATA_WIDTH),
        .FIFO_DEPTH(512),
        .ADDR_WIDTH(9)
    ) u_result_fifo (
        .clk(clk),
        .rst_n(rst_n),
        .flush(stream_reset),
        .sample_valid(out_valid),
        .sample_data(sample_out),
        .byte_rd_en(result_byte_rd_en),
        .byte_rd_data(result_byte_data),
        .has_full_block(result_has_block),
        .byte_count(result_fifo_count)
    );

endmodule