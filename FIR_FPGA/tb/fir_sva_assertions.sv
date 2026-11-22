`timescale 1ns / 1ps

module fir_sva_assertions #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 11
)(
    input wire clk,
    input wire rst_n,

    // Core control signals monitored from fpga_fir_top
    input wire coeff_commit,
    input wire core_busy,
    input wire start_core_block,
    input wire block_done,

    // FIFO signals
    input wire input_fifo_wr_en,
    input wire input_fifo_full,
    input wire sample_rd_en,
    input wire input_fifo_empty,
    input wire [DATA_WIDTH-1:0] sample_to_core,

    // SPI / Parser signals
    input wire submit_job_trigger,
    input wire fpga_ready_irq
);

    // -------------------------------------------------------------
    // Property 1: Atomic Coefficient Commit
    // Project requirement: coeff_commit |-> !job_active
    // A commit swap must NEVER fire while the arithmetic core is busy
    // -------------------------------------------------------------
    property p_atomic_coeff_commit;
        @(posedge clk) disable iff (!rst_n)
        coeff_commit |-> !core_busy;
    endproperty
    assert_atomic_commit: assert property (p_atomic_coeff_commit)
        else $error("[SVA VIOLATION] Atomic Commit violated! coeff_commit fired while core_busy is HIGH!");

    // -------------------------------------------------------------
    // Property 2: FIFO Overflow and Underflow Invariants
    // -------------------------------------------------------------
    // Input FIFO must never be written to when full
    property p_no_input_fifo_overflow;
        @(posedge clk) disable iff (!rst_n)
        input_fifo_wr_en |-> !input_fifo_full;
    endproperty
    assert_no_overflow: assert property (p_no_input_fifo_overflow)
        else $error("[SVA VIOLATION] Input FIFO Overflow! Write attempted while FIFO is full!");

    // Scheduler must never pop from an empty FIFO
    property p_no_input_fifo_underflow;
        @(posedge clk) disable iff (!rst_n)
        sample_rd_en |-> !input_fifo_empty;
    endproperty
    assert_no_underflow: assert property (p_no_input_fifo_underflow)
        else $error("[SVA VIOLATION] Input FIFO Underflow! Read requested while FIFO is empty!");

    // -------------------------------------------------------------
    // Property 3: Stable Core Triggering
    // A block execution trigger cannot be initiated while already busy
    // -------------------------------------------------------------
    property p_no_retrigger_while_busy;
        @(posedge clk) disable iff (!rst_n)
        start_core_block |-> !core_busy;
    endproperty
    assert_no_retrigger: assert property (p_no_retrigger_while_busy)
        else $error("[SVA VIOLATION] Retrigger error! start_core_block pulsed while core is already busy!");

    // -------------------------------------------------------------
    // Property 4: Handshake Backpressure
    // If submit arrives when FIFO is full, fpga_ready_irq must be deasserted
    // -------------------------------------------------------------
    property p_backpressure_flag;
        @(posedge clk) disable iff (!rst_n)
        input_fifo_full |-> !fpga_ready_irq;
    endproperty
    assert_backpressure: assert property (p_backpressure_flag)
        else $error("[SVA VIOLATION] Backpressure flag failure! fpga_ready_irq is HIGH while FIFO is full!");

    // -------------------------------------------------------------
    // Coverage Properties (Verification Evidence)
    // Proves that test stimuli reached and exercised all critical events
    // -------------------------------------------------------------
    cov_commit_exercised: cover property (@(posedge clk) disable iff (!rst_n) coeff_commit);
    cov_block_completed:  cover property (@(posedge clk) disable iff (!rst_n) block_done);
    cov_submit_accepted:  cover property (@(posedge clk) disable iff (!rst_n) submit_job_trigger);
    cov_fifo_read_valid:  cover property (@(posedge clk) disable iff (!rst_n) sample_rd_en && !input_fifo_empty);

endmodule

// -----------------------------------------------------------------
// Bind Statement: Attaches assertions cleanly to fpga_fir_top
// -----------------------------------------------------------------
bind fpga_fir_top fir_sva_assertions #(
    .DATA_WIDTH(DATA_WIDTH),
    .ADDR_WIDTH(ADDR_WIDTH)
) u_sva_bind (
    .clk(clk),
    .rst_n(rst_n),
    .coeff_commit(coeff_commit),
    .core_busy(core_busy),
    .start_core_block(start_core_block),
    .block_done(block_done),
    .input_fifo_wr_en(input_fifo_wr_en),
    .input_fifo_full(input_fifo_full),
    .sample_rd_en(sample_rd_en),
    .input_fifo_empty(input_fifo_empty),
    .sample_to_core(sample_to_core),
    .submit_job_trigger(submit_job_trigger),
    .fpga_ready_irq(fpga_ready_irq)
);