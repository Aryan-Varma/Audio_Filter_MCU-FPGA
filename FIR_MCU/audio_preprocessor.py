#!/usr/bin/env python3
"""
audio_preprocessor.py
Prepares raw signed 16-bit little-endian PCM audio and metadata.
All files are read and written directly in the current working directory.
"""

import argparse #lets you pass settings to terminal
import hashlib
import json
from pathlib import Path #handling folders and files
import numpy as np
from scipy.io import wavfile #read and write wav files
from scipy.signal import resample_poly #used to change sampling rate without changing pitch


def calculate_sha256(data: bytes) -> str:
    """Calculates the SHA-256 hash of a raw byte sequence."""
    hasher = hashlib.sha256()
    hasher.update(data)
    return hasher.hexdigest()


def write_pcm_and_metadata(
    pcm_data: np.ndarray,
    sample_rate: int,
    channels: int,
    output_dir: Path,
    base_name: str = "noisy_input",
    clean_target: np.ndarray | None = None
) -> None:
    """
    Writes raw PCM16, verification WAV, and JSON metadata to disk.
    """
    output_dir.mkdir(parents=True, exist_ok=True)

    # <i2 ensures little-endian signed 16-bit integers
    pcm16 = pcm_data.astype("<i2")
    raw_bytes = pcm16.tobytes()

    pcm_path = output_dir / f"{base_name}.pcm"
    wav_path = output_dir / f"{base_name}.wav"
    meta_path = output_dir / f"{base_name}_meta.json"

    pcm_path.write_bytes(raw_bytes)
    wavfile.write(wav_path, sample_rate, pcm16)

    total_frames = len(pcm16) if channels == 1 else len(pcm16) // channels

    metadata = {
        "file_name": pcm_path.name,
        "sample_rate": sample_rate,
        "channels": channels,
        "total_frames": total_frames,
        "byte_format": "signed_16_bit_le",
        "sha256": calculate_sha256(raw_bytes),
        "peak_left": int(np.max(np.abs(pcm16[0::channels]))),
        "peak_right": int(np.max(np.abs(pcm16[1::channels]))) if channels == 2 else 0,
        "has_clean_reference": clean_target is not None,
    }

    if clean_target is not None:
        clean_pcm16 = clean_target.astype("<i2")
        clean_pcm_path = output_dir / "clean_target.pcm"
        clean_wav_path = output_dir / "clean_target.wav"
        clean_pcm_path.write_bytes(clean_pcm16.tobytes())
        wavfile.write(clean_wav_path, sample_rate, clean_pcm16)
        metadata["clean_file_name"] = clean_pcm_path.name
        metadata["clean_sha256"] = calculate_sha256(clean_pcm16.tobytes())

    meta_path.write_text(json.dumps(metadata, indent=2))
    print(f"[+] Written: {pcm_path.name} ({len(raw_bytes)} bytes)")
    print(f"[+] Written: {wav_path.name}")
    print(f"[+] Written: {meta_path.name}")
    if clean_target is not None:
        print("[+] Written: clean_target.pcm & clean_target.wav")


def generate_synthetic_two_tone(
    sample_rate: int = 48000,
    duration_s: float = 2.0,
    channels: int = 2,
    wanted_freq: float = 1000.0,
    wanted_amp: float = 0.25,
    noise_freq: float = 8000.0,
    noise_amp: float = 0.10
) -> tuple[np.ndarray, np.ndarray]:
    """Generates a 1 kHz tone combined with an 8 kHz interference tone."""
    num_samples = int(sample_rate * duration_s)
    t = np.arange(num_samples) / sample_rate

    wanted_ch1 = wanted_amp * np.sin(2 * np.pi * wanted_freq * t)
    noise_ch1 = noise_amp * np.sin(2 * np.pi * noise_freq * t)
    mixed_ch1 = wanted_ch1 + noise_ch1

    if channels == 2:
        # Separate right channel to verify channel isolation
        wanted_ch2 = (wanted_amp * 0.8) * np.cos(2 * np.pi * wanted_freq * t)
        noise_ch2 = noise_amp * np.cos(2 * np.pi * noise_freq * t)
        mixed_ch2 = wanted_ch2 + noise_ch2

        mixed = np.empty((num_samples * 2,), dtype=np.float32)
        clean = np.empty((num_samples * 2,), dtype=np.float32)
        mixed[0::2] = mixed_ch1
        mixed[1::2] = mixed_ch2
        clean[0::2] = wanted_ch1
        clean[1::2] = wanted_ch2
    else:
        mixed = mixed_ch1.astype(np.float32)
        clean = wanted_ch1.astype(np.float32)

    mixed_pcm = np.clip(np.round(mixed * 32767.0), -32768, 32767).astype(np.int16)
    clean_pcm = np.clip(np.round(clean * 32767.0), -32768, 32767).astype(np.int16)
    return mixed_pcm, clean_pcm


def generate_synthetic_impulse(
    sample_rate: int = 48000,
    total_frames: int = 512,
    channels: int = 2
) -> tuple[np.ndarray, np.ndarray]:
    """Generates an impulse vector (delta at t=0 on left channel)."""
    total_samples = total_frames * channels
    mixed = np.zeros(total_samples, dtype=np.int16)
    mixed[0] = 32767
    return mixed, mixed.copy()


def process_external_wav(
    wav_path: Path,
    target_fs: int = 48000,
    target_channels: int = 2
) -> tuple[np.ndarray, None]:
    """Decodes, resamples, and normalizes an external WAV file."""
    src_fs, raw_audio = wavfile.read(wav_path)

    if raw_audio.dtype == np.int16:
        audio = raw_audio.astype(np.float32) / 32768.0
    elif raw_audio.dtype == np.int32:
        audio = raw_audio.astype(np.float32) / 2147483648.0
    elif raw_audio.dtype == np.uint8:
        audio = (raw_audio.astype(np.float32) - 128.0) / 128.0
    else:
        audio = raw_audio.astype(np.float32)

    if audio.ndim == 1:
        if target_channels == 2:
            audio = np.column_stack((audio, audio))
    elif audio.ndim == 2:
        if audio.shape[1] > target_channels:
            audio = audio[:, :target_channels]
        elif audio.shape[1] == 1 and target_channels == 2:
            audio = np.column_stack((audio[:, 0], audio[:, 0]))

    if src_fs != target_fs:
        gcd = np.gcd(src_fs, target_fs)
        up = target_fs // gcd
        down = src_fs // gcd
        audio = resample_poly(audio, up, down, axis=0)

    peak = np.max(np.abs(audio))
    if peak > 0.999:
        audio = audio * (0.95 / peak)

    interleaved = audio.flatten()
    pcm16 = np.clip(np.round(interleaved * 32767.0), -32768, 32767).astype(np.int16)
    return pcm16, None


def main() -> None:
    parser = argparse.ArgumentParser(description="Ingest or synthesize PCM16 audio")
    parser.add_argument("--mode", choices=["synthetic-two-tone", "synthetic-impulse", "external"],
                        default="synthetic-two-tone", help="Signal creation mode")
    parser.add_argument("--input-wav", type=Path, default=None, help="Path to input .wav file")
    parser.add_argument("--rate", type=int, default=48000, help="Target sample rate (Hz)")
    parser.add_argument("--channels", type=int, choices=[1, 2], default=2, help="1=Mono, 2=Stereo")
    parser.add_argument("--duration", type=float, default=2.0, help="Duration in seconds (synthetic)")
    parser.add_argument("--outdir", type=Path, default=Path("."), help="Target output folder")

    args = parser.parse_args()

    if args.mode == "synthetic-two-tone":
        pcm, clean = generate_synthetic_two_tone(
            sample_rate=args.rate,
            duration_s=args.duration,
            channels=args.channels
        )
    elif args.mode == "synthetic-impulse":
        pcm, clean = generate_synthetic_impulse(
            sample_rate=args.rate,
            channels=args.channels
        )
    elif args.mode == "external":
        if not args.input_wav or not args.input_wav.is_file():
            raise FileNotFoundError(f"Input WAV not found: {args.input_wav}")
        pcm, clean = process_external_wav(
            wav_path=args.input_wav,
            target_fs=args.rate,
            target_channels=args.channels
        )

    write_pcm_and_metadata(
        pcm_data=pcm,
        sample_rate=args.rate,
        channels=args.channels,
        output_dir=args.outdir,
        base_name="noisy_input",
        clean_target=clean
    )


if __name__ == "__main__":
    main()