# =====================================================================
# ZedBoard XDC Constraints: Real-Time Audio FIR Accelerator
# Device: xc7z020clg484-1
# =====================================================================

# ---------------------------------------------------------------------
# 1. Primary System Clock & Reset
# ---------------------------------------------------------------------
# 100 MHz oscillator connected to ZedBoard pin Y9 (Bank 13, 3.3V)
set_property PACKAGE_PIN Y9 [get_ports clk]
set_property IOSTANDARD LVCMOS33 [get_ports clk]

# Active-low center pushbutton (BTNC) or Pmod reset pin; mapping to BTNC (P16)
set_property PACKAGE_PIN P16 [get_ports rst_n]
set_property IOSTANDARD LVCMOS18 [get_ports rst_n]

# Define 100 MHz clock constraint (10.000 ns period, 50% duty cycle)
create_clock -period 10.000 -name sys_clk_pin -waveform {0.000 5.000} [get_ports clk]

# ---------------------------------------------------------------------
# 2. SPI Interface & Handshake on Pmod Header JA (3.3V)
# ---------------------------------------------------------------------
# JA1: Chip Select (spi_cs_n)
set_property PACKAGE_PIN Y11 [get_ports spi_cs_n]
set_property IOSTANDARD LVCMOS33 [get_ports spi_cs_n]

# JA2: Master Out Slave In (spi_mosi)
set_property PACKAGE_PIN AA11 [get_ports spi_mosi]
set_property IOSTANDARD LVCMOS33 [get_ports spi_mosi]

# JA3: Master In Slave Out (spi_miso)
set_property PACKAGE_PIN Y10 [get_ports spi_miso]
set_property IOSTANDARD LVCMOS33 [get_ports spi_miso]
set_property DRIVE 8 [get_ports spi_miso]
set_property SLEW FAST [get_ports spi_miso]

# JA4: SPI Serial Clock (spi_sclk)
set_property PACKAGE_PIN AA9 [get_ports spi_sclk]
set_property IOSTANDARD LVCMOS33 [get_ports spi_sclk]

# JA7: FPGA Ready / IRQ Handshake pin
set_property PACKAGE_PIN AB11 [get_ports fpga_ready_irq]
set_property IOSTANDARD LVCMOS33 [get_ports fpga_ready_irq]
set_property DRIVE 8 [get_ports fpga_ready_irq]

# ---------------------------------------------------------------------
# 3. Timing Exceptions & False Paths
# ---------------------------------------------------------------------
# Asynchronous Reset: Do not perform synchronous timing analysis on reset de-assertion
set_false_path -from [get_ports rst_n]

# Asynchronous Status Output: fpga_ready_irq is a static level checked by MCU polling/GPIO IRQ
set_false_path -to [get_ports fpga_ready_irq]

# Asynchronous SPI Inputs: spi_sclk, spi_cs_n, and spi_mosi pass through 
# 2-stage synchronizer flip-flops in spi_phy.v; decouple from 100 MHz STA
set_false_path -from [get_ports spi_cs_n]
set_false_path -from [get_ports spi_mosi]
set_false_path -from [get_ports spi_sclk]

# SPI MISO Output delay relative to internal 100 MHz sampling clock
set_output_delay -clock [get_clocks sys_clk_pin] -max 3.000 [get_ports spi_miso]
set_output_delay -clock [get_clocks sys_clk_pin] -min 0.500 [get_ports spi_miso]

# ---------------------------------------------------------------------
# 4. Configuration Voltage and Bitstream Settings
# ---------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]