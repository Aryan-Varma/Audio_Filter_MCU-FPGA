#!/usr/bin/env python3
"""
run_pipeline.py
Master execution script: automates the complete audio filtering pipeline
from raw input to MCU execution and final metric verification.
Operates entirely in the current working directory.
"""

import argparse
import subprocess
import sys
from pathlib import Path


def run_command(command: list[str], step_name: str) -> None:
    """Executes a subprocess command and handles exit status."""
    print(f"\n{'=' * 70}")
    print(f"[*] Step: {step_name}")
    print(f"[*] Command: {' '.join(command)}")
    print(f"{'=' * 70}")

    result = subprocess.run(command)
    if result.returncode != 0:
        print(f"\n[!] ERROR: Step '{step_name}' failed with code {result.returncode}.")
        sys.exit(result.returncode)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Master runner for the MCU FIR audio processing pipeline"
    )
    # Mode selection
    parser.add_argument(
        "--mode",
        choices=["synthetic-two-tone", "synthetic-impulse", "external"],
        default="synthetic-two-tone",
        help="Input signal generation mode (default: synthetic-two-tone)",
    )
    parser.add_argument(
        "--input-wav",
        type=Path,
        default=None,
        help="Path to external .wav file (required if mode is 'external')",
    )

    # Audio & Filter parameters
    parser.add_argument(
        "--rate",
        type=int,
        default=48000,
        help="Sample rate in Hz (e.g., 48000 or 16000)",
    )
    parser.add_argument(
        "--channels",
        type=int,
        choices=[1, 2],
        default=2,
        help="Channels: 1=mono, 2=stereo",
    )
    parser.add_argument(
        "--taps",
        type=int,
        default=129,
        help="Number of filter taps (odd integer recommended)",
    )
    parser.add_argument(
        "--cutoff",
        type=float,
        default=4500.0,
        help="Filter cutoff frequency in Hz",
    )

    # Hardware connection
    parser.add_argument(
        "--port",
        type=str,
        default=None,
        help="MCU Virtual COM port (e.g., COM3, /dev/ttyUSB0)",
    )
    parser.add_argument(
        "--baud",
        type=int,
        default=115200,
        help="UART baud rate (default: 115200)",
    )
    parser.add_argument(
        "--block-frames",
        type=int,
        default=64,
        help="Frames per transmitted chunk (default: 64)",
    )
    parser.add_argument(
        "--skip-mcu",
        action="store_true",
        help="Run only PC preparation, design, and oracle stages (no serial transfer)",
    )

    args = parser.parse_args()

    # Step 1: Preprocess or synthesize audio
    cmd_prep = [
        sys.executable,
        "audio_preprocessor.py",
        "--mode",
        args.mode,
        "--rate",
        str(args.rate),
        "--channels",
        str(args.channels),
    ]
    if args.mode == "external":
        if not args.input_wav:
            print("[!] Error: --input-wav is required when using --mode external.")
            sys.exit(1)
        cmd_prep.extend(["--input-wav", str(args.input_wav)])
    run_command(cmd_prep, "1. Audio Ingestion & Preprocessing")

    # Step 2: Design and quantize FIR filter
    cmd_filter = [
        sys.executable,
        "filter_designer.py",
        "--taps",
        str(args.taps),
        "--cutoff",
        str(args.cutoff),
        "--rate",
        str(args.rate),
        "--plot",
    ]
    run_command(cmd_filter, "2. Filter Design & Q1.15 Quantization")

    # Step 3: Run PC golden software model
    cmd_oracle = [
        sys.executable,
        "fir_oracle_reference.py",
        "--rate",
        str(args.rate),
        "--channels",
        str(args.channels),
    ]
    run_command(cmd_oracle, "3. Golden Software Reference Convolution")

    # Step 4: Stream audio to MCU via UART
    if not args.skip_mcu:
        if not args.port:
            print("[!] Error: --port is required for MCU streaming (or use --skip-mcu to simulate).")
            sys.exit(1)

        cmd_stream = [
            sys.executable,
            "stream_runner.py",
            "--port",
            args.port,
            "--baud",
            str(args.baud),
            "--block-frames",
            str(args.block_frames),
            "--channels",
            str(args.channels),
        ]
        run_command(cmd_stream, "4. UART Streaming & MCU FIR Execution")

        # Step 5: Verification and evaluation
        cmd_eval = [
            sys.executable,
            "audio_evaluator.py",
            "--rate",
            str(args.rate),
            "--channels",
            str(args.channels),
        ]
        run_command(cmd_eval, "5. Verification, Waveform & Spectral Evaluation")
    else:
        print(f"\n{'=' * 70}")
        print("[*] MCU execution skipped (--skip-mcu flag active).")
        print("[*] Generated inputs, taps, and reference outputs are ready in the folder.")
        print(f"{'=' * 70}")


if __name__ == "__main__":
    main()