`timescale 1ns / 1ps

module packet_parser #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 11
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // --- Interface from SPI PHY ---
    input  wire [7:0]             rx_byte,
    input  wire                   rx_byte_valid,
    input  wire                   trans_active,
    input  wire                   trans_start,
    input  wire                   trans_end,

    // --- Outgoing Status Byte to SPI PHY ---
    output reg  [7:0]             tx_byte,
    output reg                    tx_byte_load,

    // --- FIFO / Core Handshakes ---
    input  wire                   input_fifo_full,
    input  wire                   result_ready,     // High if result FIFO has 64 frames ready
    input  wire [7:0]             result_data_byte, // Byte from Result FIFO to transmit
    output reg                    result_rd_en,     // Pops byte from Result FIFO

    // --- Stream & Block Routing ---
    output reg                    stream_reset,
    output reg                    input_fifo_wr_en,
    output reg  [DATA_WIDTH-1:0]  input_fifo_wr_data,
    output reg                    submit_job_trigger, // Triggers core execution

    // --- Coefficient Memory Control ---
    output reg                    coeff_wr_en,
    output reg  [ADDR_WIDTH-1:0]  coeff_wr_addr,
    output reg  [DATA_WIDTH-1:0]  coeff_wr_data,
    output reg                    coeff_commit,

    // --- Diagnostics / Status Registers ---
    output reg  [7:0]             current_epoch,
    output reg  [7:0]             current_seq
);

    // Protocol Constants
    localparam [7:0] MAGIC_BYTE       = 8'hA5;

    // Command Opcodes
    localparam [7:0] CMD_STATUS       = 8'h01;
    localparam [7:0] CMD_WRITE_COEFF  = 8'h02;
    localparam [7:0] CMD_COMMIT       = 8'h03;
    localparam [7:0] CMD_SUBMIT       = 8'h04;
    localparam [7:0] CMD_READ_RESULT  = 8'h05;
    localparam [7:0] CMD_RESET_STREAM = 8'h06;

    // Parser FSM States
    localparam STATE_IDLE         = 4'd0;
    localparam STATE_GET_OPCODE   = 4'd1;
    localparam STATE_GET_EPOCH    = 4'd2;
    localparam STATE_GET_SEQ      = 4'd3;
    localparam STATE_GET_LEN_H    = 4'd4;
    localparam STATE_GET_LEN_L    = 4'd5;
    localparam STATE_PAYLOAD      = 4'd6;
    localparam STATE_CHECKSUM     = 4'd7;
    localparam STATE_STREAM_OUT   = 4'd8;

    reg [3:0]  state;

    // Packet Header Registers
    reg [7:0]  cmd_opcode;
    reg [7:0]  pkt_epoch;
    reg [7:0]  pkt_seq;
    reg [15:0] payload_len;
    reg [15:0] bytes_received;
    reg [7:0]  calc_chksum;

    // Sample assembly (2 bytes per 16-bit word, Little-Endian)
    reg [7:0]  byte_low;
    reg        byte_phase; // 0 = Low byte, 1 = High byte

    // -------------------------------------------------------------
    // Main Parser FSM
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= STATE_IDLE;
            tx_byte            <= 8'h00;
            tx_byte_load       <= 1'b0;
            result_rd_en       <= 1'b0;
            stream_reset       <= 1'b0;
            input_fifo_wr_en   <= 1'b0;
            input_fifo_wr_data <= {DATA_WIDTH{1'b0}};
            submit_job_trigger <= 1'b0;
            coeff_wr_en        <= 1'b0;
            coeff_wr_addr      <= {ADDR_WIDTH{1'b0}};
            coeff_wr_data      <= {DATA_WIDTH{1'b0}};
            coeff_commit       <= 1'b0;
            current_epoch      <= 8'h00;
            current_seq        <= 8'h00;
            cmd_opcode         <= 8'h00;
            payload_len        <= 16'd0;
            bytes_received     <= 16'd0;
            calc_chksum        <= 8'h00;
            byte_phase         <= 1'b0;
            byte_low           <= 8'h00;
        end else begin
            // Default single-cycle pulse clears
            tx_byte_load       <= 1'b0;
            result_rd_en       <= 1'b0;
            stream_reset       <= 1'b0;
            input_fifo_wr_en   <= 1'b0;
            submit_job_trigger <= 1'b0;
            coeff_wr_en        <= 1'b0;
            coeff_commit       <= 1'b0;

            // Handle transaction abort: if CS goes high prematurely, reset to IDLE
            if (trans_end && (state != STATE_IDLE)) begin
                state      <= STATE_IDLE;
                byte_phase <= 1'b0;
            end else begin
                case (state)
                    STATE_IDLE: begin
                        bytes_received <= 16'd0;
                        byte_phase     <= 1'b0;
                        if (rx_byte_valid && (rx_byte == MAGIC_BYTE)) begin
                            calc_chksum <= MAGIC_BYTE;
                            state       <= STATE_GET_OPCODE;
                        end
                    end

                    STATE_GET_OPCODE: begin
                        if (rx_byte_valid) begin
                            cmd_opcode  <= rx_byte;
                            calc_chksum <= calc_chksum ^ rx_byte;
                            state       <= STATE_GET_EPOCH;
                        end
                    end

                    STATE_GET_EPOCH: begin
                        if (rx_byte_valid) begin
                            pkt_epoch   <= rx_byte;
                            calc_chksum <= calc_chksum ^ rx_byte;
                            state       <= STATE_GET_SEQ;
                        end
                    end

                    STATE_GET_SEQ: begin
                        if (rx_byte_valid) begin
                            pkt_seq     <= rx_byte;
                            calc_chksum <= calc_chksum ^ rx_byte;
                            state       <= STATE_GET_LEN_H;
                        end
                    end

                    STATE_GET_LEN_H: begin
                        if (rx_byte_valid) begin
                            payload_len[15:8] <= rx_byte;
                            calc_chksum       <= calc_chksum ^ rx_byte;
                            state             <= STATE_GET_LEN_L;
                        end
                    end

                    STATE_GET_LEN_L: begin
                        if (rx_byte_valid) begin
                            payload_len[7:0] <= rx_byte;
                            calc_chksum      <= calc_chksum ^ rx_byte;
                            bytes_received   <= 16'd0;

                            // If command is READ_RESULT, switch directly to transmitting result
                            if (cmd_opcode == CMD_READ_RESULT) begin
                                tx_byte      <= result_data_byte;
                                tx_byte_load <= 1'b1;
                                result_rd_en <= 1'b1;
                                state        <= STATE_STREAM_OUT;
                            end else if ({payload_len[15:8], rx_byte} == 16'd0) begin
                                // No payload (e.g. COMMIT or STATUS or RESET_STREAM)
                                state <= STATE_CHECKSUM;
                            end else begin
                                state <= STATE_PAYLOAD;
                            end
                        end
                    end

                    STATE_PAYLOAD: begin
                        if (rx_byte_valid) begin
                            calc_chksum    <= calc_chksum ^ rx_byte;
                            bytes_received <= bytes_received + 1'b1;

                            // Assemble 16-bit word (Little-Endian: Low byte first)
                            if (byte_phase == 1'b0) begin
                                byte_low   <= rx_byte;
                                byte_phase <= 1'b1;
                            end else begin
                                byte_phase <= 1'b0;
                                
                                // Route complete 16-bit word based on opcode
                                if (cmd_opcode == CMD_WRITE_COEFF) begin
                                    coeff_wr_en   <= 1'b1;
                                    coeff_wr_addr <= (bytes_received >> 1); // 2 bytes per address
                                    coeff_wr_data <= {rx_byte, byte_low};
                                end else if (cmd_opcode == CMD_SUBMIT) begin
                                    input_fifo_wr_en   <= 1'b1;
                                    input_fifo_wr_data <= {rx_byte, byte_low};
                                end
                            end

                            if (bytes_received + 1'b1 == payload_len) begin
                                state <= STATE_CHECKSUM;
                            end
                        end
                    end

                    STATE_CHECKSUM: begin
                        if (rx_byte_valid) begin
                            // Verify XOR checksum
                            if (rx_byte == calc_chksum) begin
                                // Valid packet! Execute command actions:
                                current_epoch <= pkt_epoch;
                                current_seq   <= pkt_seq;

                                case (cmd_opcode)
                                    CMD_COMMIT: begin
                                        coeff_commit <= 1'b1; // Atomic swap
                                    end
                                    CMD_SUBMIT: begin
                                        submit_job_trigger <= 1'b1; // Trigger core execution
                                    end
                                    CMD_RESET_STREAM: begin
                                        stream_reset <= 1'b1; // Flush history and FIFOs
                                    end
                                    CMD_STATUS: begin
                                        // Load status flags onto MISO
                                        tx_byte      <= {6'd0, input_fifo_full, result_ready};
                                        tx_byte_load <= 1'b1;
                                    end
                                    default: ;
                                endcase
                            end
                            state <= STATE_IDLE;
                        end
                    end

                    STATE_STREAM_OUT: begin
                        // Streams out result bytes over MISO while trans_active is asserted
                        if (rx_byte_valid) begin
                            tx_byte      <= result_data_byte;
                            tx_byte_load <= 1'b1;
                            result_rd_en <= 1'b1;
                            bytes_received <= bytes_received + 1'b1;
                            if (bytes_received + 1'b1 == payload_len) begin
                                state <= STATE_IDLE;
                            end
                        end
                    end

                    default: state <= STATE_IDLE;
                endcase
            end
        end
    end

endmodule