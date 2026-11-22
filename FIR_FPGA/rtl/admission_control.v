`timescale 1ns / 1ps

module admission_control #(
    parameter MAX_BLOCK_BYTES = 256
)(
    input  wire        clk,
    input  wire        rst_n,

    // Status inputs from FIFOs & Core
    input  wire [8:0]  input_fifo_count,   // Samples currently in input FIFO
    input  wire [9:0]  result_fifo_count,  // Bytes currently in result FIFO
    input  wire        core_busy,          // High if FIR scheduler is running

    // Handshakes & Triggers
    input  wire        submit_trigger,     // Pulse from packet parser when SUBMIT completes
    output reg         start_core_block,   // Pulse to scheduler to begin filtering 1 block
    output wire        fpga_ready_pin      // Hardware READY/IRQ pin to MCU header
);

    // Admission Rule:
    // Can only run a new block if the result FIFO has room for 256 new bytes (512 - 256 = 256 max)
    wire result_has_space = (result_fifo_count <= (512 - MAX_BLOCK_BYTES));

    // FPGA is ready for a new block if input queue is not full and output space is guaranteed
    assign fpga_ready_pin = result_has_space && (input_fifo_count <= (256 - 128));

    // Trigger FSM: start processing when a block is in the input FIFO and output capacity is reserved
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            start_core_block <= 1'b0;
        end else begin
            start_core_block <= 1'b0;

            // When input has at least 128 samples (64 frames), core is idle, and result has space
            if ((input_fifo_count >= 9'd128) && !core_busy && result_has_space) begin
                start_core_block <= 1'b1;
            end
        end
    end

endmodule