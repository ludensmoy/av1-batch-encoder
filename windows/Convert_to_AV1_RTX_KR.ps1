# ==============================================================================
# [RTX NVENC] AV1 배치 인코딩 스크립트 (V1.0) - Windows용
# ==============================================================================
#
# 【필수 요구사항】
#   - ffmpeg & ffprobe PATH 등록 (https://ffmpeg.org/download.html)
#   - NVENC AV1 지원 NVIDIA GPU (RTX 40xx / 50xx 시리즈)
#
# 【주요 기능】
#   - 해상도 자동 판별 (SD / 720p / 1080p / 4K / 5K / 8K)
#   - 원본 비트레이트 기반 자동 목표 비트레이트 계산 (원본의 약 65%)
#   - 비트레이트 정보 없을 때 컨테이너 비트레이트로 fallback
#   - 해상도 읽기 실패 시 안전하게 스킵
#   - 오디오 문제 자동 진단 (PTS 음수/지연/불연속 감지 후 조건부 보정)
#   - 자막 포맷 자동 판별 (PGS/ASS 등 불가 포맷 제외, 텍스트 기반은 mov_text 변환)
#   - 10bit 원본 보존
#   - 폴더 드래그앤드롭 또는 경로 직접 입력 지원
#   - 진행률 퍼센트 표시 + 파일별/전체 용량 절감 통계
#
# 【사용법】
#   - 스크립트 파일에 폴더를 드래그앤드롭하거나
#   - 스크립트 실행 후 경로를 직접 입력
#
# ==============================================================================

# ── UTF-8 출력 설정 (한글 파일명 깨짐 방지) ──
$OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding  = [System.Text.Encoding]::UTF8

# ── 설정 ──
$LOG_FILE = Join-Path $PSScriptRoot "encoding_error_log.txt"
$ErrorActionPreference = "Continue"

# ==============================================================================
# 폴더 지정 (드래그앤드롭 or 직접 입력)
# ==============================================================================
if ($args.Count -gt 0) {
    $TARGET_DIR = $args[0].Trim('"')
} else {
    Write-Host "`n[경로 입력] 처리할 폴더를 이 창에 드래그하거나 경로를 입력하세요:" -ForegroundColor Cyan
    $TARGET_DIR = (Read-Host).Trim('"')
}

if (-not (Test-Path -LiteralPath $TARGET_DIR)) {
    Write-Host "❌ 오류: 폴더를 찾을 수 없습니다: $TARGET_DIR" -ForegroundColor Red
    pause; exit 1
}

Write-Host "`n=== [RTX AV1 V1.0] Source Fidelity Mode ===" -ForegroundColor Cyan
Write-Host "📂 대상 폴더: $TARGET_DIR" -ForegroundColor White

# ==============================================================================
# 파일 목록 수집
# ==============================================================================
$ALLOWED_EXTS = @(".mp4",".mkv",".avi",".mov",".wmv",".flv",".mts",".ts",".m2ts",".mpeg",".mpg")

# -Include와 -Recurse를 같이 쓰면 PowerShell 버그로 확장자 필터가 무시됨
# → -File로 전체 수집 후 Where-Object로 직접 필터링
$FILE_LIST = Get-ChildItem -LiteralPath $TARGET_DIR -Recurse -File |
    Where-Object {
        $ALLOWED_EXTS -contains $_.Extension.ToLower() -and
        $_.Name -notlike "*.mp4.tmp"
    } | Sort-Object FullName

$TOTAL_FILES     = $FILE_LIST.Count
$CURRENT_COUNT   = 0
$TOTAL_ORIG_SIZE = 0
$TOTAL_NEW_SIZE  = 0

if ($TOTAL_FILES -eq 0) {
    Write-Host "⚠️  처리할 파일이 없습니다. 종료합니다." -ForegroundColor Yellow
    pause; exit 0
}

Write-Host "📂 총 ${TOTAL_FILES}개 파일 발견`n" -ForegroundColor Green

# ==============================================================================
# 메인 루프
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

    # ── 이미 처리된 파일 스킵 ──
    if ((Test-Path -LiteralPath $OLD_FILE) -or
        ((Test-Path -LiteralPath $OUT_FILE) -and ($INPUT_PATH -ne $OUT_FILE))) {
        Write-Host "    ⏭️  이미 처리됨, 스킵" -ForegroundColor DarkGray
        continue
    }

    try {
        # ──────────────────────────────────────────────────────────
        # [1] ffprobe 통합 1회 호출 (첫 30패킷 포함)
        # ──────────────────────────────────────────────────────────
        $PROBE_JSON_RAW = & ffprobe -v error -print_format json `
            -show_streams -show_format -show_packets `
            -read_intervals "%+#30" `
            "$INPUT_PATH" 2>$null

        if (-not $PROBE_JSON_RAW) {
            Write-Host "    ❌ ffprobe 실패: $INPUT_PATH" -ForegroundColor Red
            "ffprobe failed: $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
            continue
        }

        $PROBE = $PROBE_JSON_RAW | ConvertFrom-Json

        # ── 스트림 파싱 ──
        $V_STREAM  = $PROBE.streams | Where-Object { $_.codec_type -eq "video"    } | Select-Object -First 1
        $A_STREAM  = $PROBE.streams | Where-Object { $_.codec_type -eq "audio"    } | Select-Object -First 1
        $S_STREAMS = $PROBE.streams | Where-Object { $_.codec_type -eq "subtitle" }

        $V_CODEC  = $V_STREAM.codec_name
        $V_W      = $V_STREAM.width
        $V_H      = $V_STREAM.height
        $PIX_FMT  = $V_STREAM.pix_fmt
        $V_B      = $V_STREAM.bit_rate     # 스트림 비트레이트 (없으면 null)
        $FORMAT_B = $PROBE.format.bit_rate # 컨테이너 전체 비트레이트 (fallback)
        $A_B      = $A_STREAM.bit_rate
        $A_R      = $A_STREAM.sample_rate
        $S_CODECS = ($S_STREAMS | ForEach-Object { $_.codec_name }) -join ","

        # ── 이미 AV1이면 스킵 ──
        if ($V_CODEC -eq "av1") {
            Write-Host "    ⏭️  이미 AV1, 스킵" -ForegroundColor DarkGray
            continue
        }

        # ──────────────────────────────────────────────────────────
        # [2] 오디오 문제 자동 진단 - 문제 있는 파일에만 보정 적용
        # ──────────────────────────────────────────────────────────
        $AUDIO_FIX_FLAGS  = @()
        $AUDIO_FIX_FILTER = "aresample=async=1"  # 기본: 가벼운 보정만

        $A_PACKETS = $PROBE.packets | Where-Object { $_.codec_type -eq "audio" }
        $A_COUNT   = ($PROBE.streams | Where-Object { $_.codec_type -eq "audio" }).Count

        if ($A_COUNT -eq 0) {
            # 오디오 없음 → 보정 불필요
            $AUDIO_FIX_FILTER = $null
            Write-Host "    ℹ️  오디오 스트림 없음: 오디오 보정 생략" -ForegroundColor DarkGray
        } else {
            # 진단 1: 오디오 시작 PTS 확인
            $A_START_RAW = ($A_PACKETS | Select-Object -First 1).pts_time
            $A_START = 0.0
            if ($A_START_RAW -and $A_START_RAW -ne "N/A") {
                try { $A_START = [double]$A_START_RAW } catch { $A_START = 0.0 }
            }

            if ($A_START -lt 0) {
                # 음수 PTS → editlist 또는 타임스탬프 문제
                $AUDIO_FIX_FLAGS += "-ignore_editlist 1"
                $AUDIO_FIX_FLAGS += "-avoid_negative_ts make_zero"
                $AUDIO_FIX_FILTER = "aresample=async=1000:min_hard_comp=0.1"
                Write-Host "    🔧 오디오 진단: 시작 PTS 음수 (${A_START}s) → editlist 무시 + 타임스탬프 보정 적용" -ForegroundColor DarkYellow
            } elseif ($A_START -gt 0.1) {
                # 0.1초 이상 늦게 시작 → editlist 시작점 밀림 의심
                $AUDIO_FIX_FLAGS += "-ignore_editlist 1"
                $AUDIO_FIX_FILTER = "aresample=async=1000:min_hard_comp=0.1"
                Write-Host "    🔧 오디오 진단: 시작 PTS 지연 (${A_START}s) → editlist 무시 적용" -ForegroundColor DarkYellow
            }

            # 진단 2: 오디오 PTS 불연속 감지
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
                Write-Host "    🔧 오디오 진단: PTS 불연속 ${A_DISC}건 감지 → 타임스탬프 재생성 적용" -ForegroundColor DarkYellow
            }

            if ($AUDIO_FIX_FLAGS.Count -eq 0) {
                Write-Host "    ✅ 오디오 진단: 이상 없음" -ForegroundColor DarkGreen
            }
        }

        # ──────────────────────────────────────────────────────────
        # [3] 해상도 판별 — 못 읽으면 안전하게 스킵
        # ──────────────────────────────────────────────────────────
        if (-not $V_W -or -not $V_H) {
            Write-Host "    ❌ 해상도 정보를 읽을 수 없음: 안전을 위해 스킵" -ForegroundColor Red
            "Resolution undetected (skipped): $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
            continue
        }

        $MAX_RES = [Math]::Max([int]$V_W, [int]$V_H)

        # ──────────────────────────────────────────────────────────
        # [4] 해상도별 비트레이트/CQ 설정
        # NVENC는 CQ(고정 품질) 모드 + maxrate 상한 병행 사용
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

        # 4K 미만: 원본 비트레이트 기반으로 TARGET_V 계산
        if ($MAX_RES -lt 3800) {
            # 스트림 비트레이트 우선, 없으면 컨테이너 비트레이트 fallback
            $USE_B = $null
            if ($V_B -and $V_B -match '^\d+$') {
                $USE_B = [int]$V_B
            } elseif ($FORMAT_B -and $FORMAT_B -match '^\d+$') {
                $USE_B = [int]$FORMAT_B
                Write-Host "    ⚠️  스트림 비트레이트 없음: 컨테이너 비트레이트 사용 ($([int]($USE_B/1000))k)" -ForegroundColor DarkYellow
            } else {
                $USE_B = 5000000
                Write-Host "    ⚠️  비트레이트 정보 없음: 기본값 5000k 적용" -ForegroundColor DarkYellow
            }

            $TARGET_V = [int](($USE_B / 1000) * 65 / 100)
            if ($TARGET_V -gt $LIMIT) { $TARGET_V = $LIMIT }
            if ($TARGET_V -lt 600)    { $TARGET_V = 600 }
        }

        $MAXRATE = "${LIMIT}k"
        $BUFSIZE  = "${LIMIT}k"

        # ──────────────────────────────────────────────────────────
        # [5] 오디오 설정 (원본 샘플레이트 보존)
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
        # [6] 자막 처리
        # mp4 불가 포맷 (이미지 기반): PGS, ASS, SSA, DVB, DVD → 제외(-sn)
        # mp4 가능 포맷 (텍스트 기반): webvtt, subrip, mov_text → mov_text 변환
        # ──────────────────────────────────────────────────────────
        $BAD_SUB_PATTERN = "hdmv_pgs|dvb_subtitle|dvd_subtitle|^ass$|^ssa$"
        $HAS_BAD_SUB = $S_CODECS -match $BAD_SUB_PATTERN

        if ($HAS_BAD_SUB) {
            $SUBTITLE_ARGS = @("-sn")
            Write-Host "    ⚠️  mp4 불가 자막 포맷 감지 ($S_CODECS): 자막 제외" -ForegroundColor DarkYellow
        } elseif ($S_CODECS) {
            $SUBTITLE_ARGS = @("-c:s", "mov_text")
            Write-Host "    📝 자막 변환: mov_text ($S_CODECS)" -ForegroundColor DarkGray
        } else {
            $SUBTITLE_ARGS = @("-sn")
        }

        # ──────────────────────────────────────────────────────────
        # [7] 픽셀 포맷 (10bit 원본 보존)
        # ──────────────────────────────────────────────────────────
        $PIX_ARGS = @()
        if ($PIX_FMT -match "10") {
            $PIX_ARGS = @("-pix_fmt", "p010le")
        }

        Write-Host "    🎯 $RES_LABEL | CQ:$CQ | V:${TARGET_V}k | A:${T_A} @ ${A_R}Hz" -ForegroundColor Cyan

        # ──────────────────────────────────────────────────────────
        # [8] ffmpeg 인코딩 실행
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

        # 오디오 인코딩 (스트림 있을 때만)
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
        # [9] 결과 처리 + 용량 절감 통계
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

            Write-Host "    ✔ 성공 | 원본: ${ORIG_MB}MB → 결과: ${NEW_MB}MB (${RATIO}% | -${SAVED_MB}MB)" -ForegroundColor Green

            # 원본 .old 백업 후 결과 이름 교체 (실패 시 복구)
            try {
                if (Test-Path -LiteralPath $OLD_FILE) { Remove-Item -LiteralPath $OLD_FILE -Force }
                Rename-Item -LiteralPath $INPUT_PATH -NewName ($FILE_NAME + ".old") -Force

                try {
                    Rename-Item -LiteralPath $TEMP_FILE -NewName ($BASE_NAME + ".mp4") -Force
                } catch {
                    Write-Host "    ⚠️  출력 파일 이동 실패, 원본 복구 중..." -ForegroundColor DarkYellow
                    Rename-Item -LiteralPath $OLD_FILE -NewName $FILE_NAME -Force
                    if (Test-Path -LiteralPath $TEMP_FILE) { Remove-Item -LiteralPath $TEMP_FILE -Force }
                    "Failed (mv output): $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
                }
            } catch {
                Write-Host "    ⚠️  원본 파일 이동 실패" -ForegroundColor DarkYellow
                if (Test-Path -LiteralPath $TEMP_FILE) { Remove-Item -LiteralPath $TEMP_FILE -Force }
                "Failed (mv original): $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
            }

        } else {
            Write-Host "    ❌ 실패 (ExitCode: $LASTEXITCODE)" -ForegroundColor Red
            if (Test-Path -LiteralPath $TEMP_FILE) { Remove-Item -LiteralPath $TEMP_FILE -Force }
            "Failed: $INPUT_PATH" | Out-File $LOG_FILE -Append -Encoding utf8
        }

    } catch {
        $TS  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $ERR = @"
------------------------------------------------------------
시간: $TS
파일: $INPUT_PATH
에러: $($_.Exception.Message)
------------------------------------------------------------
"@
        Write-Host "    ❌ 예외 발생: $($_.Exception.Message)" -ForegroundColor Red
        $ERR | Out-File $LOG_FILE -Append -Encoding utf8
        if (Test-Path -LiteralPath $TEMP_FILE) { Remove-Item -LiteralPath $TEMP_FILE -Force }
    }
}

# ==============================================================================
# 최종 통계
# ==============================================================================
Write-Host ("`n" + "=" * 60) -ForegroundColor White
Write-Host "🏁 인코딩 완료" -ForegroundColor Green

if ($TOTAL_ORIG_SIZE -gt 0) {
    $TOTAL_SAVED_MB = [int](($TOTAL_ORIG_SIZE - $TOTAL_NEW_SIZE) / 1MB)
    $TOTAL_RATIO    = [int]($TOTAL_NEW_SIZE * 100 / $TOTAL_ORIG_SIZE)
    $ORIG_GB = [Math]::Round($TOTAL_ORIG_SIZE / 1GB, 2)
    $NEW_GB  = [Math]::Round($TOTAL_NEW_SIZE  / 1GB, 2)
    Write-Host "    전체 원본: ${ORIG_GB}GB"
    Write-Host "    전체 결과: ${NEW_GB}GB"
    Write-Host "    총 절감:   ${TOTAL_SAVED_MB}MB (원본의 ${TOTAL_RATIO}%)"
}
Write-Host ("=" * 60) -ForegroundColor White

pause
