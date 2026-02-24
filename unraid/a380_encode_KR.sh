#!/bin/bash
# ==============================================================================
# [Intel Arc A380] AV1 배치 인코딩 스크립트 (V11.2) - Unraid용
# ==============================================================================
#
# 【필수 요구사항】
#   - Unraid에 linuxserver/ffmpeg Docker 이미지 설치
#   - 호스트에 jq 설치 (Unraid Community Apps → NerdTools → jq)
#   - Intel Arc GPU (QSV 지원)
#
# 【주요 기능】
#   - 해상도 자동 판별 (SD / 720p / 1080p / 4K / 5K / 8K)
#   - 원본 비트레이트 기반 자동 목표 비트레이트 계산 (원본의 약 65%)
#   - 비트레이트 정보 없을 때 컨테이너 비트레이트로 fallback
#   - 해상도 읽기 실패 시 안전하게 스킵 (잘못된 비트레이트로 인코딩 방지)
#   - 오디오 문제 자동 진단 (PTS 음수/지연/불연속 감지 후 조건부 보정)
#   - 자막 포맷 자동 판별 (PGS/ASS 등 불가 포맷 제외, 텍스트 기반은 mov_text 변환)
#   - 10bit 원본 보존 (yuv420p10le → p010le)
#   - 5K/8K는 CPU 디코딩 강제 (GPU 메모리 한계 대응)
#   - Ctrl+C 인터럽트 시 임시파일 자동 정리
#   - 진행률 퍼센트 표시 + 파일별/전체 용량 절감 통계
#
# 【사용법】
#   1. 아래 [설정] 섹션에서 TARGET_DIR, LOG_FILE 경로를 본인 환경에 맞게 수정
#   2. Unraid User Scripts 플러그인에 등록하거나 SSH에서 직접 실행
#      chmod +x a380_encode.sh && ./a380_encode.sh
#
# 【처리 방식】
#   - 원본 파일은 .old 확장자로 백업됨 (예: video.mp4 → video.mp4.old)
#   - 인코딩 결과는 동일 폴더에 .mp4로 저장
#   - 인코딩 실패 시 .old 파일 자동 복구, 임시파일 삭제
#   - 이미 처리된 파일(.old 존재)은 자동 스킵
#
# ==============================================================================

# ──────────────────────────────────────────────────────────────────────────────
# ▼ [설정] 여기만 수정하면 됩니다 ▼
# ──────────────────────────────────────────────────────────────────────────────

# 인코딩할 영상이 들어있는 폴더 경로
TARGET_DIR="/mnt/user/Temp"

# 사용할 ffmpeg Docker 이미지
DOCKER_IMG="linuxserver/ffmpeg:latest"

# 에러 로그 파일 경로
LOG_FILE="/mnt/user/Temp/encoding_error_log.txt"

# ──────────────────────────────────────────────────────────────────────────────
# ▲ [설정 끝] ▲
# ──────────────────────────────────────────────────────────────────────────────

LIST_FILE="/tmp/a380_final_list.txt"
TOTAL_ORIG_SIZE=0
TOTAL_NEW_SIZE=0
CURRENT_COUNT=0

# ── Ctrl+C 인터럽트 안전 종료 핸들러 ──
# 스크립트 중단 시 인코딩 중이던 임시파일(.tmp)을 자동으로 삭제
CURRENT_TEMP_FILE=""
cleanup() {
    echo ""
    echo "⚠️  중단 감지됨. 임시 파일 정리 중..."
    [ -n "$CURRENT_TEMP_FILE" ] && [ -f "$CURRENT_TEMP_FILE" ] && rm -f "$CURRENT_TEMP_FILE" && echo "    🗑️  삭제: $CURRENT_TEMP_FILE"
    rm -f "$LIST_FILE"
    echo "✅ 정리 완료. 종료합니다."
    exit 1
}
trap cleanup SIGINT SIGTERM

echo "=== [A380 Final V11.2] Source Fidelity Mode ==="

# ── 대상 파일 목록 수집 ──
find "$TARGET_DIR" -type f \
    \( -iname "*.mp4" -o -iname "*.mkv" -o -iname "*.avi" -o -iname "*.mov" \
       -o -iname "*.wmv" -o -iname "*.flv" -o -iname "*.mts" -o -iname "*.ts" \
       -o -iname "*.m2ts" -o -iname "*.mpeg" -o -iname "*.mpg" \) \
    ! -name "*.old" ! -name "*.tmp" | sort > "$LIST_FILE"

mapfile -t FILE_LIST < "$LIST_FILE"
TOTAL_FILES=${#FILE_LIST[@]}
echo "📂 총 ${TOTAL_FILES}개 파일 발견"

# 처리할 파일이 없으면 즉시 종료
if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "⚠️  처리할 파일이 없습니다. 종료합니다."
    rm -f "$LIST_FILE"
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────────────
# 메인 루프
# ──────────────────────────────────────────────────────────────────────────────
for FILE in "${FILE_LIST[@]}"; do
    ((CURRENT_COUNT++))
    [ -z "$FILE" ] && continue

    TARGET_V=0  # 루프마다 초기화 (이전 파일의 값이 남지 않도록)
    FILENAME=$(basename "$FILE")
    DIRNAME=$(dirname "$FILE")
    BASENAME="${FILENAME%.*}"
    OUT_FILE="$DIRNAME/$BASENAME.mp4"
    TEMP_FILE="$DIRNAME/$BASENAME.mp4.tmp"
    OLD_FILE="$DIRNAME/$FILENAME.old"
    CURRENT_TEMP_FILE="$TEMP_FILE"  # 인터럽트 핸들러에 현재 임시파일 경로 전달

    # 진행률 표시
    PERCENT=$(( CURRENT_COUNT * 100 / TOTAL_FILES ))
    echo "------------------------------------------------"
    echo "🚀 [$CURRENT_COUNT / $TOTAL_FILES | ${PERCENT}%] 확인: $FILENAME"

    # 이미 처리된 파일 스킵 (.old 파일이 있거나, 출력 파일이 이미 존재하는 경우)
    if [ -f "$OLD_FILE" ] || ([ -f "$OUT_FILE" ] && [ "$FILE" != "$OUT_FILE" ]); then
        echo "    ⏭️  이미 처리됨, 스킵"
        continue
    fi

    # ────────────────────────────────────────────────────────────
    # [1] ffprobe 통합 1회 호출 + 호스트 jq로 파싱
    #
    # 기존 방식: 스트림 정보마다 ffprobe를 개별 실행 → Docker 컨테이너 7회 기동
    # 개선 방식: JSON으로 한번에 받아서 호스트 jq로 파싱 → Docker 컨테이너 1회만 기동
    # -show_packets -read_intervals "%+#30" : 오디오 진단을 위해 첫 30패킷도 수집
    # ────────────────────────────────────────────────────────────
    PROBE_JSON=$(docker run --rm \
        -v "/mnt/user":"/mnt/user" \
        --entrypoint ffprobe "$DOCKER_IMG" \
        -v error -print_format json \
        -show_streams -show_format -show_packets \
        -read_intervals "%+#30" \
        "$FILE" 2>/dev/null)

    if [ -z "$PROBE_JSON" ]; then
        echo "    ❌ ffprobe 실패: $FILE"
        echo "ffprobe failed: $FILE" >> "$LOG_FILE"
        continue
    fi

    # ── 호스트 jq로 파싱 (Docker 추가 실행 없음) ──
    V_CODEC=$(jq -r '[.streams[] | select(.codec_type=="video")][0].codec_name // ""'   <<< "$PROBE_JSON")
    V_W=$(    jq -r '[.streams[] | select(.codec_type=="video")][0].width       // ""'   <<< "$PROBE_JSON")
    V_H=$(    jq -r '[.streams[] | select(.codec_type=="video")][0].height      // ""'   <<< "$PROBE_JSON")
    PIX_FMT=$(jq -r '[.streams[] | select(.codec_type=="video")][0].pix_fmt    // ""'   <<< "$PROBE_JSON")
    V_B=$(    jq -r '[.streams[] | select(.codec_type=="video")][0].bit_rate   // ""'   <<< "$PROBE_JSON")
    A_B=$(    jq -r '[.streams[] | select(.codec_type=="audio")][0].bit_rate   // ""'   <<< "$PROBE_JSON")
    A_R=$(    jq -r '[.streams[] | select(.codec_type=="audio")][0].sample_rate // ""'  <<< "$PROBE_JSON")
    # 자막 코덱 목록 (mp4 불가 포맷 감지에 사용)
    S_CODECS=$(jq -r '[.streams[] | select(.codec_type=="subtitle") | .codec_name] | join(",")' <<< "$PROBE_JSON")
    # 컨테이너 전체 비트레이트 (스트림 비트레이트가 없을 때 fallback으로 사용)
    FORMAT_B=$(jq -r '.format.bit_rate // ""' <<< "$PROBE_JSON")

    # ────────────────────────────────────────────────────────────
    # [2] 오디오 문제 자동 진단
    #
    # 모든 파일에 보정 옵션을 일괄 적용하면 정상 파일에 부작용이 생길 수 있음
    # → 문제가 감지된 파일에만 조건부로 해당 옵션을 적용
    # ────────────────────────────────────────────────────────────
    AUDIO_FIX_FLAGS=""
    AUDIO_FIX_FILTER="aresample=async=1"  # 기본값: 가벼운 싱크 보정만 적용

    # 진단 1: 오디오 시작 PTS 확인
    # 음수면 → editlist 또는 타임스탬프 문제 (MP4에서 자주 발생)
    # 0.1초 이상 늦게 시작하면 → editlist로 인한 시작점 밀림 의심
    A_START=$(jq -r '[.packets[] | select(.codec_type=="audio")] | .[0].pts_time // "0"' <<< "$PROBE_JSON" 2>/dev/null | tr -d '[:space:]')
    # "N/A" 등 숫자가 아닌 값이면 "0"으로 초기화
    [[ ! "$A_START" =~ ^-?[0-9] ]] && A_START="0"

    if [[ "$A_START" =~ ^- ]]; then
        AUDIO_FIX_FLAGS="-ignore_editlist 1 -avoid_negative_ts make_zero"
        AUDIO_FIX_FILTER="aresample=async=1000:min_hard_comp=0.1"
        echo "    🔧 오디오 진단: 시작 PTS 음수 (${A_START}s) → editlist 무시 + 타임스탬프 보정 적용"
    elif [[ "$A_START" =~ ^[0-9] ]] && awk "BEGIN{exit !($A_START > 0.1)}"; then
        # bc 대신 awk 사용 (Unraid에 bc가 없는 경우 대비)
        AUDIO_FIX_FLAGS="-ignore_editlist 1"
        AUDIO_FIX_FILTER="aresample=async=1000:min_hard_comp=0.1"
        echo "    🔧 오디오 진단: 시작 PTS 지연 (${A_START}s) → editlist 무시 적용"
    fi

    # 진단 2: 오디오 PTS 불연속 감지
    # 인접한 오디오 패킷 간격이 0.5초 이상이면 불연속으로 판단
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
        echo "    🔧 오디오 진단: PTS 불연속 ${A_DISC}건 감지 → 타임스탬프 재생성 적용"
    fi

    # 진단 3: 오디오 스트림 자체가 없는 경우 → 보정 불필요
    A_COUNT=$(jq -r '[.streams[] | select(.codec_type=="audio")] | length' <<< "$PROBE_JSON" 2>/dev/null)
    if [ "$A_COUNT" == "0" ]; then
        AUDIO_FIX_FLAGS=""
        AUDIO_FIX_FILTER=""
        echo "    ℹ️  오디오 스트림 없음: 오디오 보정 생략"
    fi

    [ -z "$AUDIO_FIX_FLAGS" ] && echo "    ✅ 오디오 진단: 이상 없음"

    # 이미 AV1으로 인코딩된 파일은 스킵
    [ "$V_CODEC" == "av1" ] && echo "    ⏭️  이미 AV1, 스킵" && continue

    # ────────────────────────────────────────────────────────────
    # [3] 해상도 판별
    #
    # 중요: 해상도를 읽지 못하면 기본값(1080p)으로 가정하지 않고 스킵
    # → 4K/8K 영상을 1080p로 오판해 낮은 비트레이트로 인코딩하는 사고 방지
    # 가로/세로 중 긴 쪽을 기준으로 판별 (세로형 영상도 올바르게 처리)
    # ────────────────────────────────────────────────────────────
    if [[ ! "$V_W" =~ ^[0-9]+$ ]] || [[ ! "$V_H" =~ ^[0-9]+$ ]]; then
        echo "    ❌ 해상도 정보를 읽을 수 없음 (W=${V_W} H=${V_H}): 안전을 위해 스킵"
        echo "Resolution undetected (skipped): $FILE" >> "$LOG_FILE"
        continue
    fi
    [ "$V_W" -gt "$V_H" ] && MAX_RES=$V_W || MAX_RES=$V_H

    # ────────────────────────────────────────────────────────────
    # [4] 해상도별 비트레이트 설정
    #
    # 4K 이상: 고정 TARGET_V 사용
    # 1080p 이하: 원본 비트레이트의 65%를 목표로 설정 (LIMIT 초과 시 cap)
    # FORCE_CPU_DEC: 5K/8K는 GPU 메모리 부족으로 CPU 디코딩 강제
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
        # [5] 비트레이트 fallback 로직
        #
        # MKV, TS, M2TS 등의 파일은 스트림 레벨에 비트레이트 정보가 없는 경우가 많음
        # 1단계: 스트림 비트레이트(V_B) 시도
        # 2단계: 없으면 컨테이너 전체 비트레이트(FORMAT_B) 사용
        # 3단계: 그래도 없으면 기본값 5Mbps 적용
        # ────────────────────────────────────────────────────────
        if [[ ! "$V_B" =~ ^[0-9]+$ ]]; then
            if [[ "$FORMAT_B" =~ ^[0-9]+$ ]]; then
                V_B="$FORMAT_B"
                echo "    ⚠️  스트림 비트레이트 없음: 컨테이너 비트레이트 사용 ($((V_B/1000))k)"
            else
                V_B=5000000
                echo "    ⚠️  비트레이트 정보 없음: 기본값 5000k 적용"
            fi
        fi

        TARGET_V=$(( (V_B/1000) * 65 / 100 ))
        [ "$TARGET_V" -gt "$LIMIT" ] && TARGET_V=$LIMIT
        [ "$TARGET_V" -lt 600 ] && TARGET_V=600
    fi

    # ────────────────────────────────────────────────────────────
    # [6] 오디오 설정
    #
    # 원본 샘플레이트(A_R) 보존 - 변환하지 않음
    # 원본 비트레이트(A_B)에 따라 목표 오디오 비트레이트(T_A) 결정
    # ────────────────────────────────────────────────────────────
    if [[ ! "$A_R" =~ ^[0-9]+$ ]]; then
        A_R=48000
        echo "    ⚠️  샘플레이트 정보 없음: 48000Hz 적용"
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
    # [7] 자막 처리
    #
    # mp4에 넣을 수 없는 포맷 (이미지 기반): PGS, ASS, SSA, DVB, DVD → 제외(-sn)
    # mp4에 넣을 수 있는 포맷 (텍스트 기반): webvtt, subrip, mov_text → mov_text로 변환
    # ────────────────────────────────────────────────────────────
    SUBTITLE_OPT=""
    if echo "$S_CODECS" | grep -qiE "hdmv_pgs|ass|ssa|dvb_subtitle|dvd_subtitle"; then
        SUBTITLE_OPT="-sn"
        echo "    ⚠️  mp4 불가 자막 포맷 감지 ($S_CODECS): 자막 제외"
    elif [ -n "$S_CODECS" ] && [ "$S_CODECS" != "null" ] && [ "$S_CODECS" != "" ]; then
        SUBTITLE_OPT="-c:s mov_text"
        echo "    📝 자막 변환: mov_text ($S_CODECS)"
    else
        SUBTITLE_OPT="-sn"
    fi

    # ────────────────────────────────────────────────────────────
    # [8] 픽셀 포맷 & 디코딩 가속 설정
    #
    # 픽셀 포맷: 원본이 10bit이면 p010le로 출력, 8bit이면 그대로 유지
    # 디코딩: 10bit 또는 5K/8K이면 CPU 디코딩, 그 외에는 QSV GPU 가속
    # ────────────────────────────────────────────────────────────
    if [[ "$PIX_FMT" == *"10"* ]]; then
        ENC_PIX="-pix_fmt p010le"
    else
        ENC_PIX=""
    fi

    if [[ "$PIX_FMT" == *"10"* ]] || [ "$FORCE_CPU_DEC" -eq 1 ]; then
        DEC_OPT=""
        MODE_MSG="💎 CPU 디코딩"
    else
        DEC_OPT="-hwaccel qsv -hwaccel_output_format nv12"
        MODE_MSG="⚡ GPU 가속"
    fi

    echo "    🎯 $RES_LABEL | $MODE_MSG | V:${TARGET_V}k | A:${T_A} @ ${A_R}Hz"
    [ -n "$S_CODECS" ] && echo "    📋 자막: $S_CODECS"

    # ────────────────────────────────────────────────────────────
    # [9] ffmpeg 인코딩 실행
    #
    # -map 0:a? : 오디오 스트림이 없어도 오류 없이 진행 (? = optional)
    # $AUDIO_FIX_FLAGS : 진단 결과에 따라 조건부로 적용되는 입력 옵션
    # ${AUDIO_FIX_FILTER:+-af "$AUDIO_FIX_FILTER"} : 필터가 있을 때만 -af 옵션 추가
    # ────────────────────────────────────────────────────────────
    docker run --rm \
        --device /dev/dri/card1:/dev/dri/card1 \
        --device /dev/dri/renderD129:/dev/dri/renderD129 \
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
    # [10] 결과 처리 + 용량 절감 통계
    #
    # mv 두 단계를 분리해서 처리:
    # 1단계 실패(원본 이동 불가) → 임시파일 삭제 후 로그 기록
    # 2단계 실패(결과 이동 불가) → 원본 복구 후 임시파일 삭제
    # ────────────────────────────────────────────────────────────
    if [ $? -eq 0 ]; then
        ORIG_SIZE=$(stat -c%s "$FILE")
        NEW_SIZE=$(stat -c%s "$TEMP_FILE")
        TOTAL_ORIG_SIZE=$((TOTAL_ORIG_SIZE + ORIG_SIZE))
        TOTAL_NEW_SIZE=$((TOTAL_NEW_SIZE + NEW_SIZE))

        SAVED_MB=$(( (ORIG_SIZE - NEW_SIZE) / 1024 / 1024 ))
        RATIO=$(( NEW_SIZE * 100 / ORIG_SIZE ))
        echo "    ✔ 성공 | 원본: $((ORIG_SIZE/1024/1024))MB → 결과: $((NEW_SIZE/1024/1024))MB (${RATIO}% | -${SAVED_MB}MB)"

        if mv "$FILE" "$OLD_FILE"; then
            if ! mv "$TEMP_FILE" "$OUT_FILE"; then
                echo "    ⚠️  출력 파일 이동 실패, 원본 복구 중..."
                mv "$OLD_FILE" "$FILE"
                rm -f "$TEMP_FILE"
                echo "Failed (mv output): $FILE" >> "$LOG_FILE"
            fi
        else
            echo "    ⚠️  원본 파일 이동 실패"
            rm -f "$TEMP_FILE"
            echo "Failed (mv original): $FILE" >> "$LOG_FILE"
        fi
    else
        echo "    ❌ 실패"
        echo "Failed: $FILE" >> "$LOG_FILE"
        [ -f "$TEMP_FILE" ] && rm -f "$TEMP_FILE"
    fi

    CURRENT_TEMP_FILE=""  # 처리 완료 후 초기화
done

# ──────────────────────────────────────────────────────────────────────────────
# 최종 통계
# ──────────────────────────────────────────────────────────────────────────────
rm -f "$LIST_FILE"
echo "================================================"
echo "🏁 인코딩 완료"
if [ "$TOTAL_ORIG_SIZE" -gt 0 ]; then
    TOTAL_SAVED=$(( (TOTAL_ORIG_SIZE - TOTAL_NEW_SIZE) / 1024 / 1024 ))
    TOTAL_RATIO=$(( TOTAL_NEW_SIZE * 100 / TOTAL_ORIG_SIZE ))
    echo "    전체 원본: $((TOTAL_ORIG_SIZE/1024/1024/1024))GB"
    echo "    전체 결과: $((TOTAL_NEW_SIZE/1024/1024/1024))GB"
    echo "    총 절감:   ${TOTAL_SAVED}MB (원본의 ${TOTAL_RATIO}%)"
fi
echo "================================================"
