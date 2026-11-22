`timescale 1ns / 1ps

module scheduler #(
    parameter DATA_WIDTH  = 16,
    parameter MAX_TAPS    = 2048,
    parameter ADDR_WIDTH  = 11,
    parameter BLOCK_SAMPLES = 128   // 64 frames * 2 channels = 128 samples per block
)(
    input  wire                   clk,
    input  wire                   rst_n,

    // --- High-Level Job Handshake ---
    input  wire                   start_block,     // Pulse to start processing 1 block
    input  wire [ADDR_WIDTH-1:0]  configured_taps, // Number of taps (e.g. 129)
    output reg                    block_done,      // High when entire 64-frame block finishes
    output reg                    core_busy,       // High while computing

    // --- Input Sample Interface (From Input FIFO) ---
    input  wire [DATA_WIDTH-1:0]  new_sample_data,
    output reg                    sample_rd_en,    // Read next sample from FIFO

    // --- History RAM Control Interface ---
    output reg                    hist_wr_en,
    output reg                    hist_wr_channel, // 0 = Left, 1 = Right
    output reg  [ADDR_WIDTH-1:0]  hist_wr_addr,
    output wire [DATA_WIDTH-1:0]  hist_wr_data,
    output reg                    hist_rd_channel,
    output reg  [ADDR_WIDTH-1:0]  hist_rd_addr,

    // --- Coefficient RAM Control Interface ---
    output reg  [ADDR_WIDTH-1:0]  coeff_rd_addr,

    // --- MAC Lane Control Signals ---
    output reg                    mac_clr_acc,
    output reg                    mac_valid_in,

    // --- Reduction / Saturation Control Signals ---
    output reg                    sample_done_out,
    output reg                    sample_channel_out // 0 = Left, 1 = Right (carries with result)
);

    assign hist_wr_data = new_sample_data;

    // FSM States
    localparam STATE_IDLE       = 3'd0;
    localparam STATE_FETCH_SAMP = 3'd1;
    localparam STATE_WRITE_HIST = 3'd2;
    localparam STATE_RUN_TAPS   = 3'd3;
    localparam STATE_DRAIN_PIPE = 3'd4;
    localparam STATE_NEXT_SAMP  = 3'd5;

    reg [2:0] state;

    // Counters and Pointers
    reg [ADDR_WIDTH-1:0] tap_cnt;
    reg [7:0]            sample_cnt;      // 0 to 127 (128 samples)
    reg                  current_channel; // 0 = Left, 1 = Right
    reg [ADDR_WIDTH-1:0] head_ptr_l;
    reg [ADDR_WIDTH-1:0] head_ptr_r;
    wire [ADDR_WIDTH-1:0] current_head = (current_channel == 1'b0) ? head_ptr_l : head_ptr_r;

    // Shift registers to delay control flags matching BRAM 1-cycle read latency
    reg [1:0] pipe_valid;
    reg [1:0] pipe_clr;
    reg [3:0] pipe_done;
    reg [3:0] pipe_chan;

    // -------------------------------------------------------------
    // Circular Read Address Calculation: (head - tap_cnt) mod N
    // -------------------------------------------------------------
    always @(*) begin
        if (current_head >= tap_cnt) begin
            hist_rd_addr = current_head - tap_cnt;
        end else begin
            hist_rd_addr = (current_head + configured_taps) - tap_cnt;
        end
    end

    // -------------------------------------------------------------
    // Main Scheduler FSM
    // -------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state            <= STATE_IDLE;
            block_done       <= 1'b0;
            core_busy        <= 1'b0;
            sample_rd_en     <= 1'b0;
            hist_wr_en       <= 1'b0;
            hist_wr_channel  <= 1'b0;
            hist_wr_addr     <= {ADDR_WIDTH{1'b0}};
            hist_rd_channel  <= 1'b0;
            coeff_rd_addr    <= {ADDR_WIDTH{1'b0}};
            tap_cnt          <= {ADDR_WIDTH{1'b0}};
            sample_cnt       <= 8'd0;
            current_channel  <= 1'b0;
            head_ptr_l       <= {ADDR_WIDTH{1'b0}};
            head_ptr_r       <= {ADDR_WIDTH{1'b0}};
            pipe_valid       <= 2'b0;
            pipe_clr         <= 2'b0;
            pipe_done        <= 4'b0;
            pipe_chan        <= 4'b0;
        end else begin
            // Shift pipeline tracking registers
            pipe_valid <= {pipe_valid[0], (state == STATE_RUN_TAPS)};
            pipe_clr   <= {pipe_clr[0], (state == STATE_RUN_TAPS && tap_cnt == 0)};
            pipe_done  <= {pipe_done[2:0], (state == STATE_RUN_TAPS && tap_cnt == configured_taps - 1)};
            pipe_chan  <= {pipe_chan[2:0], current_channel};

            // Register outputs to MAC / Reduction
            mac_valid_in       <= pipe_valid[1];
            mac_clr_acc        <= pipe_clr[1];
            sample_done_out    <= pipe_done[3];
            sample_channel_out <= pipe_chan[3];

            block_done   <= 1'b0;
            sample_rd_en <= 1'b0;
            hist_wr_en   <= 1'b0;

            case (state)
                STATE_IDLE: begin
                    core_busy  <= 1'b0;
                    sample_cnt <= 8'd0;
                    if (start_block) begin
                        core_busy       <= 1'b1;
                        current_channel <= 1'b0; // Start with Left channel
                        sample_rd_en    <= 1'b1; // Pop first sample
                        state           <= STATE_FETCH_SAMP;
                    end
                end

                STATE_FETCH_SAMP: begin
                    // Wait 1 cycle for FIFO / input register to present new sample
                    state <= STATE_WRITE_HIST;
                end

                STATE_WRITE_HIST: begin
                    // Advance circular head pointer for the active channel
                    if (current_channel == 1'b0) begin
                        head_ptr_l <= (head_ptr_l == configured_taps - 1) ? {ADDR_WIDTH{1'b0}} : (head_ptr_l + 1'b1);
                        hist_wr_addr <= (head_ptr_l == configured_taps - 1) ? {ADDR_WIDTH{1'b0}} : (head_ptr_l + 1'b1);
                    end else begin
                        head_ptr_r <= (head_ptr_r == configured_taps - 1) ? {ADDR_WIDTH{1'b0}} : (head_ptr_r + 1'b1);
                        hist_wr_addr <= (head_ptr_r == configured_taps - 1) ? {ADDR_WIDTH{1'b0}} : (head_ptr_r + 1'b1);
                    end

                    hist_wr_en      <= 1'b1;
                    hist_wr_channel <= current_channel;
                    hist_rd_channel <= current_channel;
                    tap_cnt         <= {ADDR_WIDTH{1'b0}};
                    coeff_rd_addr   <= {ADDR_WIDTH{1'b0}};
                    state           <= STATE_RUN_TAPS;
                end

                STATE_RUN_TAPS: begin
                    // Read addresses are applied each cycle; RAM outputs data 1 cycle later
                    if (tap_cnt == configured_taps - 1) begin
                        coeff_rd_addr <= {ADDR_WIDTH{1'b0}};
                        state         <= STATE_DRAIN_PIPE;
                    end else begin
                        tap_cnt       <= tap_cnt + 1'b1;
                        coeff_rd_addr <= tap_cnt + 1'b1;
                    end
                end

                STATE_DRAIN_PIPE: begin
                    // Allow pipeline stages to complete final MAC operations
                    if (pipe_done[3]) begin
                        state <= STATE_NEXT_SAMP;
                    end
                end

                STATE_NEXT_SAMP: begin
                    if (sample_cnt == BLOCK_SAMPLES - 1) begin
                        // All 128 samples (64 frames) completed
                        block_done <= 1'b1;
                        core_busy  <= 1'b0;
                        state      <= STATE_IDLE;
                    end else begin
                        sample_cnt      <= sample_cnt + 1'b1;
                        current_channel <= ~current_channel; // Alternate L -> R -> L -> R
                        sample_rd_en    <= 1'b1;             // Pop next sample
                        state           <= STATE_FETCH_SAMP;
                    end
                end

                default: state <= STATE_IDLE;
            endcase
        end
    end

endmodule