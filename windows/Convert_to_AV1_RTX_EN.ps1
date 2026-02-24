# ==============================================================================
# [RTX NVENC] AV1 Batch Encoding Script (V1.0)
# Ported from Unraid V11.2 logic
# Features: Auto resolution detection / Bitrate fallback / Safe subtitle handling
#           Auto audio diagnostics / Folder drag-and-drop or path input support
#
# Requirements:
#   - ffmpeg & ffprobe in PATH (https://ffmpeg.org/download.html)
#   - NVIDIA GPU with NVENC AV1 support (RTX 40xx / 50xx series)
# ==============================================================================

# ── UTF-8 output ──
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8

# ── Config ──
$LOG_FILE = Join-Path $PSScriptRoot "encoding_error_log.txt"
$ErrorActionPreference = "Continue"

# ==============================================================================
# Target folder (drag-and-drop onto script or type path manually)
# ==============================================================================
if ($args.Count -gt 0) {
    $TARGET_DIR = $args[0].Trim('"')
} else {
    Write-Host "`n[Input] Drag a folder onto this window, or type the path:" -ForegroundColor Cyan
    $TARGET_DIR = (Read-Host).Trim('"')
}

if (-not (Test-Path -LiteralPath $TARGET_DIR)) {
    Write-Host "❌ Error: Folder not found: $TARGET_DIR" -ForegroundColor Red
    pause; exit 1
}

Write-Host "`n=== [RTX AV1 V1.0] Source Fidelity Mode ===" -ForegroundColor Cyan
Write-Host "📂 Target folder: $TARGET_DIR" -ForegroundColor White

# ==============================================================================
# Collect file list
# ==============================================================================
$TARGET_EXTS = @("*.mp4","*.mkv","*.avi","*.mov","*.wmv","*.flv","*.mts","*.ts","*.m2ts","*.mpeg","*.mpg")

$FILE_LIST = Get-ChildItem -LiteralPath $TARGET_DIR -Recurse -File |
    Where-Object {
        $TARGET_EXTS -contains ("*" + $_.Extension.ToLower()) -and
        $_.Extension -notin @(".old",".tmp") -and
        $_.Name -notlike "*.mp4.tmp"
    } | Sort-Object FullName

$TOTAL_FILES     = $FILE_LIST.Count
$CURRENT_COUNT   = 0
$TOTAL_ORIG_SIZE = 0
$TOTAL_NEW_SIZE  = 0

if ($TOTAL_FILES -eq 0) {
    Write-Host "⚠️  No files to process. Exiting." -ForegroundColor Yellow
    pause; exit 0
}

Write-Host "📂 Found ${TOTAL_FILES} file(s)`n" -ForegroundColor Green

# ==============================================================================
# Main loop
# ==============================================================================
foreach ($FILE in $FILE_LIST) {
    $CURRENT_COUNT++
    $PERCENT    = [int]($CURRENT_COUNT * 100 / $TOTAL_FILES)
    $INPUT_PATH = $FILE.FullName
    $PARENT_DIR = $FILE.DirectoryName
    $BASE_NAME  = $FILE.BaseName
    $FILE_NAME  = $FILE.Name
    $OUT_FILE   = Join-Path $PARENT_DIR ($BASE_NAME + ".mp4")
    $TEMP_FILE  = Join-Path $PARENT_DIR ($BASE_NAME + ".mp4.tmp")
    $OLD_FILE   = Join-Path $PARENT_DIR ($FILE_NAME + ".old")

    Write-Host ("─" * 60) -ForegroundColor DarkGray
    Write-Host "🚀 [$CURRENT_COUNT / $TOTAL_FILES | ${PERCENT}%] $FILE_NAME" -ForegroundColor Yellow

    # ── Skip already processed files ──
    if ((Test-Path -LiteralPath $OLD_FILE) -or
        ((Test-Path -LiteralPath $OUT_FILE) -and ($INPUT_PATH -ne $OUT_FILE))) {
        Write-Host "    ⏭️  Already processed, skipping" -ForegroundColor DarkGray
        continue
    }

    try {
        # ──────────────────────────────────────────────────────────
        # [1] ffprobe: collect all info in one call (first 30 packets)
        # ──────────────────────────────────────────────────────────
        $PROBE_JSON_RAW = & ffprobe -v error -print_format json `
            -show_streams -show_format -show_packets `
            -read_intervals "%+#30" `
            "$INPUT_PATH" 2>$null

        if (-not $PROBE_JSON_RAW) {
            Write-Host "    ❌ ffprobe failed: $INPUT_PATH" -ForegroundColor Red
            "ffprobe failed: $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
            continue
        }

        $PROBE = $PROBE_JSON_RAW | ConvertFrom-Json

        # ── Parse streams ──
        $V_STREAM  = $PROBE.streams | Where-Object { $_.codec_type -eq "video"    } | Select-Object -First 1
        $A_STREAM  = $PROBE.streams | Where-Object { $_.codec_type -eq "audio"    } | Select-Object -First 1
        $S_STREAMS = $PROBE.streams | Where-Object { $_.codec_type -eq "subtitle" }

        $V_CODEC  = $V_STREAM.codec_name
        $V_W      = $V_STREAM.width
        $V_H      = $V_STREAM.height
        $PIX_FMT  = $V_STREAM.pix_fmt
        $V_B      = $V_STREAM.bit_rate     # stream bitrate (may be null)
        $FORMAT_B = $PROBE.format.bit_rate # container bitrate (fallback)
        $A_B      = $A_STREAM.bit_rate
        $A_R      = $A_STREAM.sample_rate
        $S_CODECS = ($S_STREAMS | ForEach-Object { $_.codec_name }) -join ","

        # ── Skip already AV1 ──
        if ($V_CODEC -eq "av1") {
            Write-Host "    ⏭️  Already AV1, skipping" -ForegroundColor DarkGray
            continue
        }

        # ──────────────────────────────────────────────────────────
        # [2] Audio diagnostics — apply fixes only when needed
        # ──────────────────────────────────────────────────────────
        $AUDIO_FIX_FLAGS  = @()
        $AUDIO_FIX_FILTER = "aresample=async=1"  # default: light correction

        $A_PACKETS = $PROBE.packets | Where-Object { $_.codec_type -eq "audio" }
        $A_COUNT   = ($PROBE.streams | Where-Object { $_.codec_type -eq "audio" }).Count

        if ($A_COUNT -eq 0) {
            $AUDIO_FIX_FILTER = $null
            Write-Host "    ℹ️  No audio stream: skipping audio correction" -ForegroundColor DarkGray
        } else {
            # Diagnostic 1: check audio start PTS
            $A_START_RAW = ($A_PACKETS | Select-Object -First 1).pts_time
            $A_START = 0.0
            if ($A_START_RAW -and $A_START_RAW -ne "N/A") {
                try { $A_START = [double]$A_START_RAW } catch { $A_START = 0.0 }
            }

            if ($A_START -lt 0) {
                # Negative PTS → editlist or timestamp issue
                $AUDIO_FIX_FLAGS += "-ignore_editlist 1"
                $AUDIO_FIX_FLAGS += "-avoid_negative_ts make_zero"
                $AUDIO_FIX_FILTER = "aresample=async=1000:min_hard_comp=0.1"
                Write-Host "    🔧 Audio fix: negative start PTS (${A_START}s) → ignore editlist + timestamp correction" -ForegroundColor DarkYellow
            } elseif ($A_START -gt 0.1) {
                # Audio starts >0.1s late → likely editlist offset
                $AUDIO_FIX_FLAGS += "-ignore_editlist 1"
                $AUDIO_FIX_FILTER = "aresample=async=1000:min_hard_comp=0.1"
                Write-Host "    🔧 Audio fix: delayed start PTS (${A_START}s) → ignore editlist" -ForegroundColor DarkYellow
            }

            # Diagnostic 2: detect PTS discontinuities
            $A_PTS_LIST = $A_PACKETS |
                Where-Object { $_.pts_time -and $_.pts_time -ne "N/A" } |
                ForEach-Object { [double]$_.pts_time }

            $A_DISC = 0
            for ($i = 1; $i -lt $A_PTS_LIST.Count; $i++) {
                if (($A_PTS_LIST[$i] - $A_PTS_LIST[$i-1]) -gt 0.5) { $A_DISC++ }
            }

            if ($A_DISC -gt 0) {
                $AUDIO_FIX_FLAGS += "-fflags +genpts+igndts"
                $AUDIO_FIX_FILTER = "aresample=async=1000:min_hard_comp=0.1"
                Write-Host "    🔧 Audio fix: $A_DISC PTS discontinuity(s) detected → regenerate timestamps" -ForegroundColor DarkYellow
            }

            if ($AUDIO_FIX_FLAGS.Count -eq 0) {
                Write-Host "    ✅ Audio diagnostics: OK" -ForegroundColor DarkGreen
            }
        }

        # ──────────────────────────────────────────────────────────
        # [3] Resolution detection — skip if unreadable (safety)
        # ──────────────────────────────────────────────────────────
        if (-not $V_W -or -not $V_H) {
            Write-Host "    ❌ Cannot read resolution: skipping for safety" -ForegroundColor Red
            "Resolution undetected (skipped): $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
            continue
        }

        $MAX_RES = [Math]::Max([int]$V_W, [int]$V_H)

        # ──────────────────────────────────────────────────────────
        # [4] Resolution-based bitrate / CQ settings
        # NVENC uses CQ (constant quality) + maxrate ceiling
        # ──────────────────────────────────────────────────────────
        $TARGET_V = 0

        if ($MAX_RES -ge 7600) {
            $TARGET_V = 25000; $LIMIT = 30000; $CQ = 28; $RES_LABEL = "8K"
        } elseif ($MAX_RES -ge 5000) {
            $TARGET_V = 18000; $LIMIT = 22000; $CQ = 28; $RES_LABEL = "5K"
        } elseif ($MAX_RES -ge 3800) {
            $TARGET_V = 8000;  $LIMIT = 12000; $CQ = 30; $RES_LABEL = "4K"
        } elseif ($MAX_RES -ge 1900) {
            $LIMIT = 2000; $CQ = 31; $RES_LABEL = "1080p"
        } elseif ($MAX_RES -ge 1200) {
            $LIMIT = 1200; $CQ = 32; $RES_LABEL = "720p"
        } else {
            $LIMIT = 800;  $CQ = 33; $RES_LABEL = "SD"
        }

        # Below 4K: calculate TARGET_V from source bitrate
        if ($MAX_RES -lt 3800) {
            $USE_B = $null
            if ($V_B -and $V_B -match '^\d+$') {
                $USE_B = [int]$V_B
            } elseif ($FORMAT_B -and $FORMAT_B -match '^\d+$') {
                $USE_B = [int]$FORMAT_B
                Write-Host "    ⚠️  No stream bitrate: using container bitrate ($([int]($USE_B/1000))k)" -ForegroundColor DarkYellow
            } else {
                $USE_B = 5000000
                Write-Host "    ⚠️  No bitrate info: using default 5000k" -ForegroundColor DarkYellow
            }

            $TARGET_V = [int](($USE_B / 1000) * 65 / 100)
            if ($TARGET_V -gt $LIMIT) { $TARGET_V = $LIMIT }
            if ($TARGET_V -lt 600)    { $TARGET_V = 600 }
        }

        $MAXRATE = "$([int]($TARGET_V * 2))k"
        $BUFSIZE  = "$([int]($TARGET_V * 2))k"

        # ──────────────────────────────────────────────────────────
        # [5] Audio settings (preserve original sample rate)
        # ──────────────────────────────────────────────────────────
        if (-not $A_R -or $A_R -eq "N/A") { $A_R = "48000" }

        $A_K = 0
        if ($A_B -and $A_B -match '^\d+$') { $A_K = [int]([int]$A_B / 1000) }

        $T_A = switch ($true) {
            ($A_K -gt 448) { "512k"; break }
            ($A_K -gt 320) { "448k"; break }
            ($A_K -gt 256) { "320k"; break }
            ($A_K -gt 192) { "256k"; break }
            ($A_K -gt 160) { "192k"; break }
            ($A_K -gt 128) { "160k"; break }
            default         { "128k" }
        }

        # ──────────────────────────────────────────────────────────
        # [6] Subtitle handling
        # Image-based (PGS, ASS, SSA, DVB, DVD) → not MP4 compatible → strip
        # Text-based (webvtt, subrip, mov_text) → convert to mov_text
        # ──────────────────────────────────────────────────────────
        $BAD_SUB_PATTERN = "hdmv_pgs|dvb_subtitle|dvd_subtitle|^ass$|^ssa$"
        $HAS_BAD_SUB = $S_CODECS -match $BAD_SUB_PATTERN

        if ($HAS_BAD_SUB) {
            $SUBTITLE_ARGS = @("-sn")
            Write-Host "    ⚠️  Incompatible subtitle format ($S_CODECS): stripping subtitles" -ForegroundColor DarkYellow
        } elseif ($S_CODECS) {
            $SUBTITLE_ARGS = @("-c:s", "mov_text")
            Write-Host "    📝 Converting subtitles to mov_text ($S_CODECS)" -ForegroundColor DarkGray
        } else {
            $SUBTITLE_ARGS = @("-sn")
        }

        # ──────────────────────────────────────────────────────────
        # [7] Pixel format (preserve 10-bit if source is 10-bit)
        # ──────────────────────────────────────────────────────────
        $PIX_ARGS = @()
        if ($PIX_FMT -match "10") {
            $PIX_ARGS = @("-pix_fmt", "p010le")
        }

        Write-Host "    🎯 $RES_LABEL | CQ:$CQ | V:${TARGET_V}k | A:${T_A} @ ${A_R}Hz" -ForegroundColor Cyan

        # ──────────────────────────────────────────────────────────
        # [8] Run ffmpeg
        # ──────────────────────────────────────────────────────────
        $FF_ARGS = @(
            "-y", "-stats"
        ) + $AUDIO_FIX_FLAGS + @(
            "-i", $INPUT_PATH,
            "-map", "0:v:0", "-map", "0:a?", "-map", "0:s?",
            "-c:v", "av1_nvenc",
                "-cq", $CQ,
                "-b:v", "${TARGET_V}k",
                "-maxrate", $MAXRATE,
                "-bufsize", $BUFSIZE,
                "-preset", "p5",
                "-tune", "hq",
                "-multipass", "fullres",
                "-rc-lookahead", "32"
        ) + $PIX_ARGS + @(
            "-fps_mode", "passthrough",
            "-max_muxing_queue_size", "9999"
        )

        # Audio encoding (only if audio stream exists)
        if ($A_COUNT -gt 0) {
            $FF_ARGS += @("-c:a", "aac", "-b:a", $T_A, "-ar", $A_R)
            if ($AUDIO_FIX_FILTER) {
                $FF_ARGS += @("-af", $AUDIO_FIX_FILTER)
            }
        }

        $FF_ARGS += $SUBTITLE_ARGS
        $FF_ARGS += @("-f", "mp4", "-movflags", "+faststart", $TEMP_FILE)

        & ffmpeg @FF_ARGS

        # ──────────────────────────────────────────────────────────
        # [9] Handle result
        # ──────────────────────────────────────────────────────────
        if ($LASTEXITCODE -eq 0) {
            $ORIG_SIZE = (Get-Item -LiteralPath $INPUT_PATH).Length
            $NEW_SIZE  = (Get-Item -LiteralPath $TEMP_FILE).Length
            $TOTAL_ORIG_SIZE += $ORIG_SIZE
            $TOTAL_NEW_SIZE  += $NEW_SIZE

            $SAVED_MB = [int](($ORIG_SIZE - $NEW_SIZE) / 1MB)
            $RATIO    = [int]($NEW_SIZE * 100 / $ORIG_SIZE)
            $ORIG_MB  = [int]($ORIG_SIZE / 1MB)
            $NEW_MB   = [int]($NEW_SIZE / 1MB)

            Write-Host "    ✔ Done | Original: ${ORIG_MB}MB → Output: ${NEW_MB}MB (${RATIO}% | -${SAVED_MB}MB)" -ForegroundColor Green

            # Rename original to .old, then rename .tmp to .mp4
            # Restore original if output rename fails
            try {
                if (Test-Path -LiteralPath $OLD_FILE) { Remove-Item -LiteralPath $OLD_FILE -Force }
                Rename-Item -LiteralPath $INPUT_PATH -NewName ($FILE_NAME + ".old") -Force

                try {
                    Rename-Item -LiteralPath $TEMP_FILE -NewName ($BASE_NAME + ".mp4") -Force
                } catch {
                    Write-Host "    ⚠️  Failed to move output file. Restoring original..." -ForegroundColor DarkYellow
                    Rename-Item -LiteralPath $OLD_FILE -NewName $FILE_NAME -Force
                    if (Test-Path -LiteralPath $TEMP_FILE) { Remove-Item -LiteralPath $TEMP_FILE -Force }
                    "Failed (mv output): $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
                }
            } catch {
                Write-Host "    ⚠️  Failed to rename original file" -ForegroundColor DarkYellow
                if (Test-Path -LiteralPath $TEMP_FILE) { Remove-Item -LiteralPath $TEMP_FILE -Force }
                "Failed (mv original): $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
            }

        } else {
            Write-Host "    ❌ Failed (ExitCode: $LASTEXITCODE)" -ForegroundColor Red
            if (Test-Path -LiteralPath $TEMP_FILE) { Remove-Item -LiteralPath $TEMP_FILE -Force }
            "Failed: $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
        }

    } catch {
        $TS  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $ERR = @"
------------------------------------------------------------
Time:  $TS
File:  $INPUT_PATH
Error: $($_.Exception.Message)
------------------------------------------------------------
"@
        Write-Host "    ❌ Exception: $($_.Exception.Message)" -ForegroundColor Red
        $ERR | Out-File $LOG_FILE -Append -Encoding utf8
        if (Test-Path -LiteralPath $TEMP_FILE) { Remove-Item -LiteralPath $TEMP_FILE -Force }
    }
}

# ==============================================================================
# Summary
# ==============================================================================
Write-Host ("`n" + "=" * 60) -ForegroundColor White
Write-Host "🏁 Encoding complete" -ForegroundColor Green

if ($TOTAL_ORIG_SIZE -gt 0) {
    $TOTAL_SAVED_MB = [int](($TOTAL_ORIG_SIZE - $TOTAL_NEW_SIZE) / 1MB)
    $TOTAL_RATIO    = [int]($TOTAL_NEW_SIZE * 100 / $TOTAL_ORIG_SIZE)
    $ORIG_GB = [Math]::Round($TOTAL_ORIG_SIZE / 1GB, 2)
    $NEW_GB  = [Math]::Round($TOTAL_NEW_SIZE  / 1GB, 2)
    Write-Host "    Total original : ${ORIG_GB} GB"
    Write-Host "    Total output   : ${NEW_GB} GB"
    Write-Host "    Space saved    : ${TOTAL_SAVED_MB} MB (${TOTAL_RATIO}% of original)"
}
Write-Host ("=" * 60) -ForegroundColor White

pause
