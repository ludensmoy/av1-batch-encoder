#!/bin/bash
# ==============================================================================
# [Intel Arc A380] AV1 Batch Encoding Script (V11.2) - Unraid
# ==============================================================================
#
# Requirements:
#   - linuxserver/ffmpeg Docker image installed on Unraid
#   - jq installed on the host (Unraid Community Apps → NerdTools → jq)
#   - Intel Arc GPU with QSV support
#
# Features:
#   - Auto resolution detection (SD / 720p / 1080p / 4K / 5K / 8K)
#   - Target bitrate auto-calculated from source (~65% of original)
#   - Bitrate fallback: stream → container → 5 Mbps default
#   - Skips files with unreadable resolution (prevents wrong bitrate encoding)
#   - Auto audio diagnostics: detects and fixes PTS issues per-file only
#   - Safe subtitle handling: strips incompatible formats (PGS/ASS),
#     converts text-based formats (webvtt/subrip) to mov_text
#   - Preserves 10-bit source (yuv420p10le → p010le)
#   - Forces CPU decoding for 5K/8K (GPU memory limit)
#   - Cleans up temp files on Ctrl+C interrupt
#   - Progress percentage + per-file and total space savings stats
#
# Usage:
#   1. Edit the [Config] section below to match your paths
#   2. Run via Unraid User Scripts plugin, or directly over SSH:
#      chmod +x a380_encode.sh && ./a380_encode.sh
#
# File handling:
#   - Original files are renamed to .old (e.g. video.mp4 → video.mp4.old)
#   - Encoded output saved as .mp4 in the same folder
#   - On encoding failure: temp file deleted, original restored automatically
#   - Already processed files (.old exists) are skipped automatically
#
# ==============================================================================

# ==============================================================================
# ▼ [Config] Edit this section to match your setup ▼
# ==============================================================================

# Folder containing the videos to encode
TARGET_DIR="/mnt/user/Temp"

# Docker image to use for ffmpeg
DOCKER_IMG="linuxserver/ffmpeg:latest"

# Error log file path
LOG_FILE="/mnt/user/Temp/encoding_error_log.txt"

# GPU device paths — check yours with: ls /dev/dri/
# Adjust if your Arc GPU uses different device nodes
CARD_DEVICE="/dev/dri/card1"
RENDER_DEVICE="/dev/dri/renderD129"

# ==============================================================================
# ▲ [Config end] ▲
# ==============================================================================

LIST_FILE="/tmp/a380_final_list.txt"
TOTAL_ORIG_SIZE=0
TOTAL_NEW_SIZE=0
CURRENT_COUNT=0

# ── Ctrl+C / SIGTERM handler ──
# Deletes the in-progress .tmp file on interrupt so nothing is left behind
CURRENT_TEMP_FILE=""
cleanup() {
    echo ""
    echo "⚠️  Interrupt detected. Cleaning up temp files..."
    [ -n "$CURRENT_TEMP_FILE" ] && [ -f "$CURRENT_TEMP_FILE" ] && rm -f "$CURRENT_TEMP_FILE" && echo "    🗑️  Deleted: $CURRENT_TEMP_FILE"
    rm -f "$LIST_FILE"
    echo "✅ Done. Exiting."
    exit 1
}
trap cleanup SIGINT SIGTERM

echo "=== [A380 Final V11.2] Source Fidelity Mode ==="

# ── Collect file list ──
find "$TARGET_DIR" -type f \
    \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" \
       -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.mts" -o -iname "*.ts" \
       -o -iname "*.m2ts" -o -iname "*.mpeg" -o -iname "*.mpg" \) \
    ! -name "*.old" ! -name "*.tmp" | sort > "$LIST_FILE"

mapfile -t FILE_LIST < "$LIST_FILE"
TOTAL_FILES=${#FILE_LIST[@]}
echo "📂 Found ${TOTAL_FILES} file(s)"

if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "⚠️  No files to process. Exiting."
    rm -f "$LIST_FILE"
    exit 0
fi

# ==============================================================================
# Main loop
# ==============================================================================
for FILE in "${FILE_LIST[@]}"; do
    ((CURRENT_COUNT++))
    [ -z "$FILE" ] && continue

    TARGET_V=0  # Reset per loop to prevent value leaking from previous file
    FILENAME=$(basename "$FILE")
    DIRNAME=$(dirname "$FILE")
    BASENAME="${FILENAME%.*}"
    OUT_FILE="$DIRNAME/$BASENAME.mp4"
    TEMP_FILE="$DIRNAME/$BASENAME.mp4.tmp"
    OLD_FILE="$DIRNAME/$FILENAME.old"
    CURRENT_TEMP_FILE="$TEMP_FILE"  # Pass to interrupt handler

    PERCENT=$(( CURRENT_COUNT * 100 / TOTAL_FILES ))
    echo "------------------------------------------------"
    echo "🚀 [$CURRENT_COUNT / $TOTAL_FILES | ${PERCENT}%] $FILENAME"

    # ── Skip already processed files ──
    if [ -f "$OLD_FILE" ] || ([ -f "$OUT_FILE" ] && [ "$FILE" != "$OUT_FILE" ]); then
        echo "    ⏭️  Already processed, skipping"
        continue
    fi

    # ────────────────────────────────────────────────────────────
    # [1] Single ffprobe call + host-side jq parsing
    #
    # Old approach: run ffprobe separately per stream → 7 Docker containers
    # New approach: get everything as JSON, parse with host jq → 1 container
    # -show_packets -read_intervals "%+#30": also fetch first 30 packets
    #   for audio diagnostics
    # ────────────────────────────────────────────────────────────
    PROBE_JSON=$(docker run --rm \
        -v "/mnt/user":"/mnt/user" \
        --entrypoint ffprobe "$DOCKER_IMG" \
        -v error -print_format json \
        -show_streams -show_format -show_packets \
        -read_intervals "%+#30" \
        "$FILE" 2>/dev/null)

    if [ -z "$PROBE_JSON" ]; then
        echo "    ❌ ffprobe failed: $FILE"
        echo "ffprobe failed: $FILE" >> "$LOG_FILE"
        continue
    fi

    # ── Parse with host jq (no additional Docker containers) ──
    V_CODEC=$(jq -r '[.streams[] | select(.codec_type=="video")][0].codec_name // ""'   <<< "$PROBE_JSON")
    V_W=$(    jq -r '[.streams[] | select(.codec_type=="video")][0].width       // ""'   <<< "$PROBE_JSON")
    V_H=$(    jq -r '[.streams[] | select(.codec_type=="video")][0].height      // ""'   <<< "$PROBE_JSON")
    PIX_FMT=$(jq -r '[.streams[] | select(.codec_type=="video")][0].pix_fmt    // ""'   <<< "$PROBE_JSON")
    V_B=$(    jq -r '[.streams[] | select(.codec_type=="video")][0].bit_rate   // ""'   <<< "$PROBE_JSON")
    A_B=$(    jq -r '[.streams[] | select(.codec_type=="audio")][0].bit_rate   // ""'   <<< "$PROBE_JSON")
    A_R=$(    jq -r '[.streams[] | select(.codec_type=="audio")][0].sample_rate // ""'  <<< "$PROBE_JSON")
    # Subtitle codec list (used to detect MP4-incompatible formats)
    S_CODECS=$(jq -r '[.streams[] | select(.codec_type=="subtitle") | .codec_name] | join(",")' <<< "$PROBE_JSON")
    # Container-level bitrate (fallback when stream bitrate is unavailable)
    FORMAT_B=$(jq -r '.format.bit_rate // ""' <<< "$PROBE_JSON")

    # ────────────────────────────────────────────────────────────
    # [2] Audio diagnostics — apply fixes only where needed
    #
    # Applying corrections blindly to all files can hurt normal ones.
    # Each fix is only applied when the specific problem is detected.
    # ────────────────────────────────────────────────────────────
    AUDIO_FIX_FLAGS=""
    AUDIO_FIX_FILTER="aresample=async=1"  # default: light sync correction only

    # Diagnostic 1: check audio start PTS
    # Negative → editlist or timestamp issue (common in MP4)
    # >0.1s delay → suspected editlist offset
    A_START=$(jq -r '[.packets[] | select(.codec_type=="audio")] | .[0].pts_time // "0"' <<< "$PROBE_JSON" 2>/dev/null | tr -d '[:space:]')
    # Treat non-numeric values (e.g. "N/A") as 0
    [[ ! "$A_START" =~ ^-?[0-9] ]] && A_START="0"

    if [[ "$A_START" =~ ^- ]]; then
        # Negative start PTS → ignore editlist + fix timestamps
        AUDIO_FIX_FLAGS="-ignore_editlist 1 -avoid_negative_ts make_zero"
        AUDIO_FIX_FILTER="aresample=async=1000:min_hard_comp=0.1"
        echo "    🔧 Audio fix: negative start PTS (${A_START}s) → ignore editlist + timestamp correction"
    elif [[ "$A_START" =~ ^[0-9] ]] && awk "BEGIN{exit !($A_START > 0.1)}"; then
        # Audio starts >0.1s late → ignore editlist (awk used instead of bc)
        AUDIO_FIX_FLAGS="-ignore_editlist 1"
        AUDIO_FIX_FILTER="aresample=async=1000:min_hard_comp=0.1"
        echo "    🔧 Audio fix: delayed start PTS (${A_START}s) → ignore editlist"
    fi

    # Diagnostic 2: detect PTS discontinuities
    # Gap between adjacent audio packets >0.5s is treated as discontinuity
    A_DISC=$(jq -r '
        [.packets[] | select(.codec_type=="audio" and .pts_time != "N/A") | .pts_time | tonumber] as $pts |
        if ($pts | length) < 2 then 0
        else
            [ range(1; $pts|length) | select( $pts[.] - $pts[.-1] > 0.5 ) ] | length
        end
    ' <<< "$PROBE_JSON" 2>/dev/null)

    if [[ "$A_DISC" =~ ^[0-9]+$ ]] && [ "$A_DISC" -gt 0 ]; then
        AUDIO_FIX_FLAGS="$AUDIO_FIX_FLAGS -fflags +genpts+igndts"
        AUDIO_FIX_FILTER="aresample=async=1000:min_hard_comp=0.1"
        echo "    🔧 Audio fix: $A_DISC PTS discontinuity(s) → regenerate timestamps"
    fi

    # Diagnostic 3: no audio stream → skip all correction
    A_COUNT=$(jq -r '[.streams[] | select(.codec_type=="audio")] | length' <<< "$PROBE_JSON" 2>/dev/null)
    if [ "$A_COUNT" == "0" ]; then
        AUDIO_FIX_FLAGS=""
        AUDIO_FIX_FILTER=""
        echo "    ℹ️  No audio stream: skipping audio correction"
    fi

    [ -z "$AUDIO_FIX_FLAGS" ] && echo "    ✅ Audio diagnostics: OK"

    # Skip files already encoded as AV1
    [ "$V_CODEC" == "av1" ] && echo "    ⏭️  Already AV1, skipping" && continue

    # ────────────────────────────────────────────────────────────
    # [3] Resolution detection
    #
    # Important: if resolution cannot be read, skip the file entirely.
    # Never assume a default (e.g. 1080p) — a 4K/8K file encoded with
    # 1080p bitrates would be severely degraded.
    # Uses the longer side (width or height) to handle portrait videos.
    # ────────────────────────────────────────────────────────────
    if [[ ! "$V_W" =~ ^[0-9]+$ ]] || [[ ! "$V_H" =~ ^[0-9]+$ ]]; then
        echo "    ❌ Cannot read resolution (W=${V_W} H=${V_H}): skipping for safety"
        echo "Resolution undetected (skipped): $FILE" >> "$LOG_FILE"
        continue
    fi
    [ "$V_W" -gt "$V_H" ] && MAX_RES=$V_W || MAX_RES=$V_H

    # ────────────────────────────────────────────────────────────
    # [4] Resolution-based bitrate targets
    #
    # 4K and above: fixed TARGET_V
    # Below 4K: 65% of source bitrate, capped at LIMIT
    # FORCE_CPU_DEC: 5K/8K use CPU decoding due to GPU memory limits
    # ────────────────────────────────────────────────────────────
    FORCE_CPU_DEC=0
    if [ "$MAX_RES" -ge 7600 ]; then
        TARGET_V=30000; LIMIT=38000; RES_LABEL="8K"; FORCE_CPU_DEC=1
    elif [ "$MAX_RES" -ge 5000 ]; then
        TARGET_V=18000; LIMIT=22000; RES_LABEL="5K"; FORCE_CPU_DEC=1
    elif [ "$MAX_RES" -ge 3800 ]; then
        TARGET_V=8000; LIMIT=12000; RES_LABEL="4K"
    elif [ "$MAX_RES" -ge 1900 ]; then
        LIMIT=2000; RES_LABEL="1080p"
    elif [ "$MAX_RES" -ge 1200 ]; then
        LIMIT=1200; RES_LABEL="720p"
    else
        LIMIT=800; RES_LABEL="SD"
    fi

    if [ "$MAX_RES" -lt 3800 ]; then
        # ────────────────────────────────────────────────────────
        # [5] Bitrate fallback logic
        #
        # MKV, TS, M2TS often lack stream-level bitrate info.
        # Step 1: use stream bitrate (V_B)
        # Step 2: fall back to container bitrate (FORMAT_B)
        # Step 3: if still unavailable, use default 5 Mbps
        # ────────────────────────────────────────────────────────
        if [[ ! "$V_B" =~ ^[0-9]+$ ]]; then
            if [[ "$FORMAT_B" =~ ^[0-9]+$ ]]; then
                V_B="$FORMAT_B"
                echo "    ⚠️  No stream bitrate: using container bitrate ($((V_B/1000))k)"
            else
                V_B=5000000
                echo "    ⚠️  No bitrate info: using default 5000k"
            fi
        fi

        TARGET_V=$(( (V_B/1000) * 65 / 100 ))
        [ "$TARGET_V" -gt "$LIMIT" ] && TARGET_V=$LIMIT
        [ "$TARGET_V" -lt 600 ] && TARGET_V=600
    fi

    # ────────────────────────────────────────────────────────────
    # [6] Audio settings
    #
    # Preserve original sample rate (A_R) — no conversion
    # Map source audio bitrate (A_B) to AAC target bitrate (T_A)
    # ────────────────────────────────────────────────────────────
    if [[ ! "$A_R" =~ ^[0-9]+$ ]]; then
        A_R=48000
        echo "    ⚠️  No sample rate info: using 48000 Hz"
    fi

    if [[ "$A_B" =~ ^[0-9]+$ ]]; then
        A_K=$((A_B / 1000))
        if   [ "$A_K" -gt 448 ]; then T_A="512k"
        elif [ "$A_K" -gt 320 ]; then T_A="448k"
        elif [ "$A_K" -gt 256 ]; then T_A="320k"
        elif [ "$A_K" -gt 192 ]; then T_A="256k"
        elif [ "$A_K" -gt 160 ]; then T_A="192k"
        elif [ "$A_K" -gt 128 ]; then T_A="160k"
        else T_A="128k"; fi
    else
        T_A="256k"
    fi

    # ────────────────────────────────────────────────────────────
    # [7] Subtitle handling
    #
    # Image-based (MP4-incompatible): PGS, ASS, SSA, DVB, DVD → strip (-sn)
    # Text-based (MP4-compatible): webvtt, subrip, mov_text → convert to mov_text
    # ────────────────────────────────────────────────────────────
    SUBTITLE_OPT=""
    if echo "$S_CODECS" | grep -qiE "hdmv_pgs|ass|ssa|dvb_subtitle|dvd_subtitle"; then
        SUBTITLE_OPT="-sn"
        echo "    ⚠️  Incompatible subtitle format ($S_CODECS): stripping subtitles"
    elif [ -n "$S_CODECS" ] && [ "$S_CODECS" != "null" ] && [ "$S_CODECS" != "" ]; then
        SUBTITLE_OPT="-c:s mov_text"
        echo "    📝 Converting subtitles to mov_text ($S_CODECS)"
    else
        SUBTITLE_OPT="-sn"
    fi

    # ────────────────────────────────────────────────────────────
    # [8] Pixel format & decoding mode
    #
    # Pixel format: output p010le if source is 10-bit, otherwise keep 8-bit
    # Decoding: use QSV GPU acceleration by default;
    #           fall back to CPU for 10-bit or 5K/8K content
    # ────────────────────────────────────────────────────────────
    if [[ "$PIX_FMT" == *"10"* ]]; then
        ENC_PIX="-pix_fmt p010le"
    else
        ENC_PIX=""
    fi

    if [[ "$PIX_FMT" == *"10"* ]] || [ "$FORCE_CPU_DEC" -eq 1 ]; then
        DEC_OPT=""
        MODE_MSG="💎 CPU decode"
    else
        DEC_OPT="-hwaccel qsv -hwaccel_output_format nv12"
        MODE_MSG="⚡ GPU accel"
    fi

    echo "    🎯 $RES_LABEL | $MODE_MSG | V:${TARGET_V}k | A:${T_A} @ ${A_R}Hz"
    [ -n "$S_CODECS" ] && echo "    📋 Subtitles: $S_CODECS"

    # ────────────────────────────────────────────────────────────
    # [9] Run ffmpeg encoding
    #
    # -map 0:a? : audio is optional (no error if stream is missing)
    # $AUDIO_FIX_FLAGS : conditionally applied input flags from diagnostics
    # ${AUDIO_FIX_FILTER:+-af "..."} : only adds -af if filter is set
    # ────────────────────────────────────────────────────────────
    docker run --rm \
        --device "$CARD_DEVICE":"$CARD_DEVICE" \
        --device "$RENDER_DEVICE":"$RENDER_DEVICE" \
        -v "/mnt/user":"/mnt/user" \
        -e LIBVA_DRIVER_NAME=iHD -e PUID=99 -e PGID=100 \
        "$DOCKER_IMG" \
        -y -stats $AUDIO_FIX_FLAGS $DEC_OPT -i "$FILE" \
        -map 0:v:0 -map 0:a? -map 0:s? \
        -c:v av1_qsv \
            -b:v "${TARGET_V}k" \
            -maxrate "$((TARGET_V * 2))k" \
            -bufsize "$((TARGET_V * 2))k" \
            -preset 4 \
        $ENC_PIX -fps_mode passthrough \
        -max_muxing_queue_size 9999 \
        -c:a aac -b:a "$T_A" -ar "$A_R" ${AUDIO_FIX_FILTER:+-af "$AUDIO_FIX_FILTER"} \
        $SUBTITLE_OPT \
        -f mp4 -movflags +faststart \
        "$TEMP_FILE"

    # ────────────────────────────────────────────────────────────
    # [10] Handle result + space savings stats
    #
    # Two-stage mv with rollback:
    # Stage 1 fails (can't rename original) → delete temp, log error
    # Stage 2 fails (can't rename output)   → restore original, delete temp
    # ────────────────────────────────────────────────────────────
    if [ $? -eq 0 ]; then
        ORIG_SIZE=$(stat -c%s "$FILE")
        NEW_SIZE=$(stat -c%s "$TEMP_FILE")
        TOTAL_ORIG_SIZE=$((TOTAL_ORIG_SIZE + ORIG_SIZE))
        TOTAL_NEW_SIZE=$((TOTAL_NEW_SIZE + NEW_SIZE))

        SAVED_MB=$(( (ORIG_SIZE - NEW_SIZE) / 1024 / 1024 ))
        RATIO=$(( NEW_SIZE * 100 / ORIG_SIZE ))
        echo "    ✔ Done | Original: $((ORIG_SIZE/1024/1024))MB → Output: $((NEW_SIZE/1024/1024))MB (${RATIO}% | -${SAVED_MB}MB)"

        if mv "$FILE" "$OLD_FILE"; then
            if ! mv "$TEMP_FILE" "$OUT_FILE"; then
                echo "    ⚠️  Failed to move output file. Restoring original..."
                mv "$OLD_FILE" "$FILE"
                rm -f "$TEMP_FILE"
                echo "Failed (mv output): $FILE" >> "$LOG_FILE"
            fi
        else
            echo "    ⚠️  Failed to rename original file"
            rm -f "$TEMP_FILE"
            echo "Failed (mv original): $FILE" >> "$LOG_FILE"
        fi
    else
        echo "    ❌ Failed"
        echo "Failed: $FILE" >> "$LOG_FILE"
        [ -f "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
    fi

    CURRENT_TEMP_FILE=""  # Clear after processing
done

# ==============================================================================
# Summary
# ==============================================================================
rm -f "$LIST_FILE"
echo "================================================"
echo "🏁 Encoding complete"
if [ "$TOTAL_ORIG_SIZE" -gt 0 ]; then
    TOTAL_SAVED=$(( (TOTAL_ORIG_SIZE - TOTAL_NEW_SIZE) / 1024 / 1024 ))
    TOTAL_RATIO=$(( TOTAL_NEW_SIZE * 100 / TOTAL_ORIG_SIZE ))
    echo "    Total original : $((TOTAL_ORIG_SIZE/1024/1024/1024)) GB"
    echo "    Total output   : $((TOTAL_NEW_SIZE/1024/1024/1024)) GB"
    echo "    Space saved    : ${TOTAL_SAVED} MB (${TOTAL_RATIO}% of original)"
fi
echo "================================================"
