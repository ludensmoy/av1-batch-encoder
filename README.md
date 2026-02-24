# av1-batch-encoder

Batch AV1 encoding scripts for **Unraid (Intel Arc A380)** and **Windows (RTX NVENC)**.  
Automatically detects resolution, bitrate, audio issues, and subtitle formats — then encodes with optimal settings.

---

## Features

- **Auto resolution detection** — SD / 720p / 1080p / 4K / 5K / 8K
- **Smart bitrate calculation** — targets ~65% of source bitrate, capped per resolution
- **Bitrate fallback** — stream → container → 5 Mbps default
- **Safe resolution guard** — skips files where resolution cannot be read (prevents wrong bitrate encoding)
- **Auto audio diagnostics** — detects negative PTS, delayed start, and discontinuities; applies fixes only where needed
- **Safe subtitle handling** — strips incompatible formats (PGS, ASS, SSA); converts text-based formats (webvtt, subrip) to mov_text
- **10-bit source preservation** — yuv420p10le → p010le
- **Space savings stats** — per-file and total summary at the end
- **Safe interruption** — Ctrl+C cleans up temp files automatically

---

## Scripts

| File | Platform | Language |
|---|---|---|
| `unraid/a380_encode_EN.sh` | Unraid + Intel Arc A380 | English |
| `unraid/a380_encode_KR.sh` | Unraid + Intel Arc A380 | Korean |
| `windows/Convert_to_AV1_RTX_EN.ps1` | Windows + RTX NVENC | English |
| `windows/Convert_to_AV1_RTX_KR.ps1` | Windows + RTX NVENC | Korean |

---

## Requirements

### Unraid
- [linuxserver/ffmpeg](https://hub.docker.com/r/linuxserver/ffmpeg) Docker image
- `jq` installed on host (Unraid Community Apps → NerdTools → jq)
- Intel Arc GPU with QSV support

### Windows
- [ffmpeg & ffprobe](https://ffmpeg.org/download.html) added to PATH
- NVIDIA GPU with NVENC AV1 support (RTX 40xx / 50xx series)

---

## Usage

### Unraid
1. Edit the `[Config]` section at the top of the script:
   ```bash
   TARGET_DIR="/mnt/user/YourFolder"
   LOG_FILE="/mnt/user/YourFolder/encoding_error_log.txt"
   CARD_DEVICE="/dev/dri/card1"       # adjust to your Arc GPU
   RENDER_DEVICE="/dev/dri/renderD129" # adjust to your Arc GPU
   ```
2. Run via SSH or Unraid User Scripts plugin:
   ```bash
   chmod +x a380_encode_EN.sh && ./a380_encode_EN.sh
   ```

> **Finding your GPU device path:**
> ```bash
> ls /dev/dri/
> ```

### Windows
1. **Drag and drop** a folder onto the `.ps1` script file, or run it and type the path manually.
2. If execution is blocked by PowerShell policy, run once in PowerShell:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

---

## How it works

- Original files are renamed to `.old` (e.g. `video.mp4` → `video.mp4.old`)
- Encoded output is saved as `.mp4` in the same folder
- On failure: temp file is deleted, original is restored automatically
- Already processed files (`.old` exists) are skipped on re-run

---

## Bitrate targets

| Resolution | Target | Cap |
|---|---|---|
| 8K | 30,000k | 38,000k |
| 5K | 18,000k | 22,000k |
| 4K | 8,000k | 12,000k |
| 1080p | 65% of source | 2,000k |
| 720p | 65% of source | 1,200k |
| SD | 65% of source | 800k |

---

## License

MIT
