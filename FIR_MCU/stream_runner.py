#!/usr/bin/env python3
"""
stream_runner.py
Transmits PCM audio chunks to the MCU over UART using a stop-and-wait protocol
and collects filtered output samples into mcu_output.pcm.
All input and output files reside in the current working directory.
"""

import argparse
import json
from pathlib import Path
import time
import serial

from uart_protocol import (
    build_data_packet,
    build_reset_packet,
    PacketParser,
    MSG_TYPE_ACK,
    MSG_TYPE_ERROR,
)


def run_stream(
    port: str,
    baudrate: int,
    input_pcm_path: Path,
    output_pcm_path: Path,
    block_frames: int = 64,
    channels: int = 2,
    timeout_s: float = 2.0,
    max_retries: int = 3
) -> None:
    """
    Streams raw PCM chunks to the MCU and writes returned samples to disk.
    """
    if not input_pcm_path.is_file():
        raise FileNotFoundError(f"Input file not found: {input_pcm_path.name}")

    pcm_bytes = input_pcm_path.read_bytes()
    bytes_per_sample = 2  # 16-bit PCM
    bytes_per_frame = bytes_per_sample * channels
    chunk_bytes = block_frames * bytes_per_frame

    total_frames = len(pcm_bytes) // bytes_per_frame
    total_chunks = (len(pcm_bytes) + chunk_bytes - 1) // chunk_bytes

    print(f"[*] Opening serial port:   {port} @ {baudrate} baud")
    ser = serial.Serial(port=port, baudrate=baudrate, timeout=0.1)
    parser = PacketParser()

    try:
        # 1. Reset MCU filter state
        print("[*] Sending stream reset...")
        reset_pkt = build_reset_packet(stream_id=1)
        ser.reset_input_buffer()
        ser.reset_output_buffer()
        ser.write(reset_pkt)
        time.sleep(0.05)

        # 2. Sequential chunk streaming
        collected_pcm = bytearray()
        print(f"[*] Streaming {total_frames} frames ({total_chunks} blocks of {block_frames} frames)...")
        start_time = time.perf_counter()

        for chunk_idx in range(total_chunks):
            start_offset = chunk_idx * chunk_bytes
            end_offset = min(start_offset + chunk_bytes, len(pcm_bytes))
            payload = pcm_bytes[start_offset:end_offset]
            frames_in_chunk = len(payload) // bytes_per_frame

            pkt = build_data_packet(
                stream_id=1,
                seq_num=chunk_idx,
                frame_count=frames_in_chunk,
                pcm_payload=payload
            )

            ack_received = False
            retries = 0

            while not ack_received and retries < max_retries:
                ser.write(pkt)
                deadline = time.perf_counter() + timeout_s

                while time.perf_counter() < deadline:
                    incoming = ser.read(ser.in_waiting or 1)
                    if incoming:
                        parser.feed(incoming)
                        parsed = parser.parse_one()
                        if parsed:
                            msg_type, stream_id, seq_num, frame_count, ret_payload = parsed

                            if msg_type == MSG_TYPE_ACK and seq_num == chunk_idx:
                                collected_pcm.extend(ret_payload)
                                ack_received = True
                                break
                            elif msg_type == MSG_TYPE_ERROR:
                                print(f"[!] MCU reported error for sequence {seq_num}")
                                break

                if not ack_received:
                    retries += 1
                    print(f"[!] Timeout on chunk {chunk_idx}/{total_chunks}. Retry {retries}/{max_retries}...")

            if not ack_received:
                raise RuntimeError(f"Communication failed: chunk {chunk_idx} unacknowledged after {max_retries} attempts.")

            # Periodic progress report
            if (chunk_idx + 1) % 50 == 0 or (chunk_idx + 1) == total_chunks:
                progress = (chunk_idx + 1) / total_chunks * 100.0
                print(f"    -> Progress: {progress:5.1f}% ({chunk_idx + 1}/{total_chunks} chunks)")

        elapsed = time.perf_counter() - start_time
        print(f"[+] Transfer complete in {elapsed:.2f} seconds.")

        # 3. Save received output PCM
        output_pcm_path.write_bytes(bytes(collected_pcm))
        print(f"[+] Wrote: {output_pcm_path.name} ({len(collected_pcm)} bytes)")

    finally:
        ser.close()
        print("[*] Serial port closed.")


def main() -> None:
    parser = argparse.ArgumentParser(description="Stream audio chunks to MCU via UART")
    parser.add_argument("--port", type=str, required=True, help="Serial COM port (e.g., COM3, /dev/ttyUSB0)")
    parser.add_argument("--baud", type=int, default=115200, help="Baud rate (default: 115200)")
    parser.add_argument("--input", type=Path, default=Path("noisy_input.pcm"), help="Input PCM file")
    parser.add_argument("--output", type=Path, default=Path("mcu_output.pcm"), help="Output PCM file")
    parser.add_argument("--block-frames", type=int, default=64, help="Frames per chunk (default: 64)")
    parser.add_argument("--meta", type=Path, default=Path("noisy_input_meta.json"), help="Metadata JSON")
    parser.add_argument("--channels", type=int, choices=[1, 2], default=2, help="Fallback channel count")

    args = parser.parse_args()

    channels = args.channels
    if args.meta.is_file():
        try:
            meta_dict = json.loads(args.meta.read_text())
            channels = meta_dict.get("channels", channels)
        except Exception:
            pass

    run_stream(
        port=args.port,
        baudrate=args.baud,
        input_pcm_path=args.input,
        output_pcm_path=args.output,
        block_frames=args.block_frames,
        channels=channels
    )


if __name__ == "__main__":
    main()