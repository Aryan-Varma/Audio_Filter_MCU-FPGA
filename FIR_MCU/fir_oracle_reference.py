#!/usr/bin/env python3
"""
fir_oracle_reference.py
PC-side golden software model for Q1.15 fixed-point FIR convolution.
Matches the exact integer arithmetic, rounding, and saturation rules of the MCU.
Reads and writes all files in the current working directory.
"""

import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from scipy.io import wavfile


def calculate_sha256(data: bytes) -> str:
    """Calculates the SHA-256 hash of a raw byte sequence."""
    hasher = hashlib.sha256()
    hasher.update(data)
    return hasher.hexdigest()


def load_coefficients(coeff_path: Path) -> np.ndarray:
    """Loads signed Q1.15 integer coefficients from text file."""
    if not coeff_path.is_file():
        raise FileNotFoundError(f"Missing coefficients file: {coeff_path.name}")
    taps = np.loadtxt(coeff_path, dtype=np.int64)
    return taps


def round_and_saturate_q15(accumulators: np.ndarray) -> np.ndarray:
    """
    Applies the exact Q1.15 output contract:
    1. Check accumulator sign.
    2. Divide absolute value by 2^15 with nearest rounding (ties away from zero).
    3. Reapply sign.
    4. Saturate within [-32768, 32767].
    """
    # Accumulator bounds check to avoid int64 overflow
    signs = np.sign(accumulators)
    abs_acc = np.abs(accumulators)

    # (abs_acc + 16384) // 32768 performs round-to-nearest with ties away from zero
    rounded = (abs_acc + 16384) // 32768
    result = signs * rounded

    return np.clip(result, -32768, 32767).astype(np.int16)


def convolve_channel_q15(samples: np.ndarray, taps: np.ndarray) -> np.ndarray:
    """
    Computes direct-form FIR convolution for a single channel using 64-bit accumulators.
    Initial history before t=0 is assumed zero.
    """
    # Use exact integer linear convolution
    # mode='full' produces len(samples) + len(taps) - 1 outputs
    # For a stream matching input frame count, we truncate to len(samples)
    acc = np.convolve(samples.astype(np.int64), taps.astype(np.int64), mode="full")
    valid_acc = acc[:len(samples)]
    return round_and_saturate_q15(valid_acc)


def run_fir_oracle(
    input_pcm_path: Path,
    coeff_path: Path,
    channels: int,
    sample_rate: int,
    output_dir: Path
) -> None:
    """Executes the reference FIR engine across all channels and writes output."""
    raw_bytes = input_pcm_path.read_bytes()
    taps = load_coefficients(coeff_path)
    num_taps = len(taps)

    # Decode interleaved little-endian signed 16-bit PCM
    audio_int16 = np.frombuffer(raw_bytes, dtype="<i2")

    if channels == 1:
        filtered_pcm16 = convolve_channel_q15(audio_int16, taps)
    elif channels == 2:
        if len(audio_int16) % 2 != 0:
            raise ValueError("Stereo PCM buffer length must be even (incomplete frame).")

        left_in = audio_int16[0::2]
        right_in = audio_int16[1::2]

        left_out = convolve_channel_q15(left_in, taps)
        right_out = convolve_channel_q15(right_in, taps)

        # Interleave filtered left and right samples
        filtered_pcm16 = np.empty((len(left_out) * 2,), dtype=np.int16)
        filtered_pcm16[0::2] = left_out
        filtered_pcm16[1::2] = right_out
    else:
        raise ValueError(f"Unsupported channel count: {channels}")

    out_bytes = filtered_pcm16.tobytes()
    out_pcm_path = output_dir / "reference_output.pcm"
    out_wav_path = output_dir / "reference_output.wav"
    out_meta_path = output_dir / "reference_output_meta.json"

    out_pcm_path.write_bytes(out_bytes)
    wavfile.write(out_wav_path, sample_rate, filtered_pcm16)

    total_frames = len(filtered_pcm16) // channels
    group_delay_samples = (num_taps - 1) // 2

    metadata = {
        "file_name": out_pcm_path.name,
        "sample_rate": sample_rate,
        "channels": channels,
        "total_frames": total_frames,
        "filter_taps": num_taps,
        "group_delay_samples": group_delay_samples,
        "group_delay_ms": round((group_delay_samples / sample_rate) * 1000.0, 3),
        "sha256": calculate_sha256(out_bytes)
    }
    out_meta_path.write_text(json.dumps(metadata, indent=2))

    print(f"[*] Loaded Taps:           {num_taps} taps from {coeff_path.name}")
    print(f"[*] Processed Channels:    {channels}")
    print(f"[*] Group Delay:           {group_delay_samples} samples ({metadata['group_delay_ms']} ms)")
    print(f"[+] Output PCM:            {out_pcm_path.name} ({len(out_bytes)} bytes)")
    print(f"[+] Reference WAV:         {out_wav_path.name}")
    print(f"[+] SHA-256 Digest:        {metadata['sha256']}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Run Q1.15 golden reference FIR model")
    parser.add_argument("--input", type=Path, default=Path("noisy_input.pcm"),
                        help="Path to input PCM16 file")
    parser.add_argument("--coeff", type=Path, default=Path("coefficients_q15.txt"),
                        help="Path to coefficients text file")
    parser.add_argument("--meta", type=Path, default=Path("noisy_input_meta.json"),
                        help="Path to companion input metadata file")
    parser.add_argument("--rate", type=int, default=48000, help="Fallback sampling rate (Hz)")
    parser.add_argument("--channels", type=int, choices=[1, 2], default=2, help="Fallback channel count")

    args = parser.parse_args()

    # Attempt to read rate and channel configuration from metadata JSON
    sample_rate = args.rate
    channels = args.channels
    if args.meta.is_file():
        try:
            meta_dict = json.loads(args.meta.read_text())
            sample_rate = meta_dict.get("sample_rate", sample_rate)
            channels = meta_dict.get("channels", channels)
            print(f"[*] Using parameters from {args.meta.name}: Rate={sample_rate} Hz, Channels={channels}")
        except Exception as e:
            print(f"[!] Warning reading {args.meta.name} ({e}). Using CLI defaults.")

    run_fir_oracle(
        input_pcm_path=args.input,
        coeff_path=args.coeff,
        channels=channels,
        sample_rate=sample_rate,
        output_dir=Path(".")
    )


if __name__ == "__main__":
    main()