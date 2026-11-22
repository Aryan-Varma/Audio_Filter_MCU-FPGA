`timescale 1ns / 1ps

module tb_fir_core;

    // --- Simulation Parameters ---
    localparam DATA_WIDTH    = 16;
    localparam MAX_TAPS      = 2048;
    localparam ADDR_WIDTH    = 11;
    localparam ACCUM_WIDTH   = 40;
    localparam TEST_TAPS     = 129;
    localparam BLOCK_SAMPLES = 128; // 64 stereo frames = 128 samples

    // --- Clock and Reset ---
    reg clk;
    reg rst_n;

    // 100 MHz clock generation (10 ns period)
    always #5 clk = ~clk;

    // --- Interconnect Wires ---
    // Scheduler control & handshakes
    reg                    start_block;
    wire                   block_done;
    wire                   core_busy;
    reg  [DATA_WIDTH-1:0]  sim_sample_data;
    wire                   sample_rd_en;

    // Memory control
    wire                   hist_wr_en;
    wire                   hist_wr_channel;
    wire [ADDR_WIDTH-1:0]  hist_wr_addr;
    wire [DATA_WIDTH-1:0]  hist_wr_data;
    wire                   hist_rd_channel;
    wire [ADDR_WIDTH-1:0]  hist_rd_addr;
    wire [DATA_WIDTH-1:0]  hist_rd_data;
    wire [ADDR_WIDTH-1:0]  coeff_rd_addr;
    wire [DATA_WIDTH-1:0]  coeff_rd_data;

    // Coefficient write port
    reg                    coeff_wr_en;
    reg  [ADDR_WIDTH-1:0]  coeff_wr_addr;
    reg  [DATA_WIDTH-1:0]  coeff_wr_data;
    reg                    coeff_commit;
    wire                   active_bank_id;

    // MAC lane signals
    wire                   mac_clr_acc;
    wire                   mac_valid_in;
    wire signed [ACCUM_WIDTH-1:0] mac_accum_out;

    // Reduction / Saturation signals
    wire                   sample_done_out;
    wire                   sample_channel_out;
    wire                   out_valid;
    wire signed [DATA_WIDTH-1:0] sample_out;

    // Stream reset
    reg                    stream_reset;
    wire                   hist_busy;

    // -------------------------------------------------------------
    // Device Under Test (DUT) Instantiations
    // -------------------------------------------------------------

    // 1. Coefficient RAM
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

    // 2. Circular History RAM
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

    // 3. Scheduler
    scheduler #(
        .DATA_WIDTH(DATA_WIDTH),
        .MAX_TAPS(MAX_TAPS),
        .ADDR_WIDTH(ADDR_WIDTH),
        .BLOCK_SAMPLES(BLOCK_SAMPLES)
    ) u_scheduler (
        .clk(clk),
        .rst_n(rst_n),
        .start_block(start_block),
        .configured_taps(ADDR_WIDTH'(TEST_TAPS)),
        .block_done(block_done),
        .core_busy(core_busy),
        .new_sample_data(sim_sample_data),
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

    // 4. MAC Lane
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

    // 5. Reduction & Saturation
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
    // Test Memories and Tracking Variables
    // -------------------------------------------------------------
    reg [15:0] coeff_file_mem [0:TEST_TAPS-1];
    reg [15:0] test_input_mem [0:8191];
    reg [15:0] test_gold_mem  [0:8191];

    integer input_idx;
    integer output_idx;
    integer total_errors;
    integer k;

    // Synchronous mock input FIFO: supplies new sample when sample_rd_en pulses
    always @(posedge clk) begin
        if (sample_rd_en) begin
            sim_sample_data <= test_input_mem[input_idx];
            input_idx       <= input_idx + 1;
        end
    end

    // Scoreboard: compares DUT output with expected golden output
    always @(posedge clk) begin
        if (out_valid) begin
            if (sample_out !== $signed(test_gold_mem[output_idx])) begin
                $display("[ERROR] Sample %0d Mismatch! Got: %0d, Expected: %0d", 
                         output_idx, sample_out, $signed(test_gold_mem[output_idx]));
                total_errors = total_errors + 1;
            end
            output_idx = output_idx + 1;
        end
    end

    // -------------------------------------------------------------
    // Task: Run a complete multi-block vector verification
    // -------------------------------------------------------------
    task run_vector_test(
        input string in_path, 
        input string exp_path, 
        input integer num_samples
    );
        integer num_blocks;
        integer b;
        begin
            $display("--- Starting Test: %s ---", in_path);
            $readmemh(in_path, test_input_mem);
            $readmemh(exp_path, test_gold_mem);

            input_idx    = 0;
            output_idx   = 0;
            total_errors = 0;
            num_blocks   = num_samples / BLOCK_SAMPLES;

            // Clear history RAM before new test
            @(posedge clk);
            stream_reset = 1'b1;
            @(posedge clk);
            stream_reset = 1'b0;
            // Wait for history clearing to finish
            wait(!hist_busy);
            @(posedge clk);

            // Feed blocks one by one
            for (b = 0; b < num_blocks; b = b + 1) begin
                start_block = 1'b1;
                @(posedge clk);
                start_block = 1'b0;

                // Wait until this block completes
                @(posedge block_done);
                @(posedge clk);
            end

            // Wait a few cycles for the reduction pipeline to drain the final sample
            repeat(10) @(posedge clk);

            if (total_errors == 0 && output_idx == num_samples) begin
                $display("[PASS] %s: All %0d samples matched exactly (0 errors).\n", in_path, num_samples);
            end else begin
                $display("[FAIL] %s: Completed with %0d errors out of %0d samples.\n", in_path, total_errors, num_samples);
            end
        end
    endtask

    // -------------------------------------------------------------
    // Main Test Stimulus
    // -------------------------------------------------------------
    initial begin
        clk             = 0;
        rst_n           = 0;
        start_block     = 0;
        sim_sample_data = 0;
        coeff_wr_en     = 0;
        coeff_wr_addr   = 0;
        coeff_wr_data   = 0;
        coeff_commit    = 0;
        stream_reset    = 0;

        // Reset pulse
        repeat(5) @(posedge clk);
        rst_n = 1;
        repeat(5) @(posedge clk);

        // Step 1: Load Quantized Coefficients into Inactive Bank
        $display("[INFO] Loading coefficients into coeff_ram...");
        $readmemh("tools/coefficients_q15.hex", coeff_file_mem);
        for (k = 0; k < TEST_TAPS; k = k + 1) begin
            @(posedge clk);
            coeff_wr_en   = 1'b1;
            coeff_wr_addr = k[ADDR_WIDTH-1:0];
            coeff_wr_data = coeff_file_mem[k];
        end
        @(posedge clk);
        coeff_wr_en = 1'b0;

        // Step 2: Atomic Commit to activate the loaded coefficients
        @(posedge clk);
        coeff_commit = 1'b1;
        @(posedge clk);
        coeff_commit = 1'b0;
        $display("[INFO] Coefficients committed. Active Bank ID: %0d", active_bank_id);

        // Step 3: Run Vector Tests
        // 512 frames = 1024 samples (8 blocks)
        run_vector_test("data/vectors/test_impulse_in.hex", 
                        "data/vectors/test_impulse_expected.hex", 1024);

        run_vector_test("data/vectors/test_isolation_in.hex", 
                        "data/vectors/test_isolation_expected.hex", 1024);

        run_vector_test("data/vectors/test_saturation_in.hex", 
                        "data/vectors/test_saturation_expected.hex", 1024);

        // 2048 frames = 4096 samples (32 blocks)
        run_vector_test("data/vectors/test_twotone_in.hex", 
                        "data/vectors/test_twotone_expected.hex", 4096);

        $display("==================================================");
        $display("   ALL CORE ARITHMETIC TESTS COMPLETED!           ");
        $display("==================================================");
        $stop;
    end

endmodule