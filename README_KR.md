# av1-batch-encoder

**Unraid (Intel Arc A380)** 및 **Windows (RTX NVENC)** 용 AV1 배치 인코딩 스크립트입니다.  
해상도, 비트레이트, 오디오 문제, 자막 포맷을 자동으로 분석해서 최적 설정으로 인코딩합니다.

> 영어 버전 README: [README.md](./README.md)

---

## 주요 기능

- **해상도 자동 판별** — SD / 720p / 1080p / 4K / 5K / 8K
- **비트레이트 자동 계산** — 원본의 약 65%, 해상도별 상한 적용
- **비트레이트 fallback** — 스트림 → 컨테이너 → 기본값 5Mbps 순으로 시도
- **해상도 안전 처리** — 읽기 실패 시 스킵 (4K/8K를 1080p로 오판하는 사고 방지)
- **오디오 자동 진단** — PTS 음수/지연/불연속 감지, 문제 있는 파일에만 보정 적용
- **자막 안전 처리** — PGS/ASS/SSA 등 불가 포맷 제외, webvtt/subrip은 mov_text로 변환
- **10bit 원본 보존** — yuv420p10le → p010le
- **용량 절감 통계** — 파일별 및 전체 통계 출력
- **안전한 중단** — Ctrl+C 시 임시파일 자동 정리

---

## 스크립트 목록

| 파일 | 플랫폼 | 언어 |
|---|---|---|
| `unraid/a380_encode_EN.sh` | Unraid + Intel Arc A380 | 영어 |
| `unraid/a380_encode_KR.sh` | Unraid + Intel Arc A380 | 한국어 |
| `windows/Convert_to_AV1_RTX_EN.ps1` | Windows + RTX NVENC | 영어 |
| `windows/Convert_to_AV1_RTX_KR.ps1` | Windows + RTX NVENC | 한국어 |

---

## 필수 요구사항

### Unraid
- [linuxserver/ffmpeg](https://hub.docker.com/r/linuxserver/ffmpeg) Docker 이미지
- 호스트에 `jq` 설치 (Unraid Community Apps → NerdTools → jq)
- QSV 지원 Intel Arc GPU

### Windows
- [ffmpeg & ffprobe](https://ffmpeg.org/download.html) PATH 등록
- NVENC AV1 지원 NVIDIA GPU (RTX 40xx / 50xx 시리즈)

---

## 사용법

### Unraid
1. 스크립트 상단 `[설정]` 섹션 수정:
   ```bash
   TARGET_DIR="/mnt/user/폴더명"
   LOG_FILE="/mnt/user/폴더명/encoding_error_log.txt"
   CARD_DEVICE="/dev/dri/card1"        # 본인 Arc GPU 경로로 수정
   RENDER_DEVICE="/dev/dri/renderD129" # 본인 Arc GPU 경로로 수정
   ```
2. SSH 또는 Unraid User Scripts 플러그인으로 실행:
   ```bash
   chmod +x a380_encode_KR.sh && ./a380_encode_KR.sh
   ```

> **GPU 디바이스 경로 확인:**
> ```bash
> ls /dev/dri/
> ```

### Windows
1. `.ps1` 파일에 폴더를 **드래그앤드롭**하거나, 실행 후 경로를 직접 입력합니다.
2. PowerShell 실행 정책으로 차단되는 경우, PowerShell에서 한 번만 실행:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

---

## 동작 방식

- 원본 파일은 `.old`로 백업됩니다 (예: `video.mp4` → `video.mp4.old`)
- 인코딩 결과는 같은 폴더에 `.mp4`로 저장됩니다
- 인코딩 실패 시 임시파일 삭제 + 원본 자동 복구
- 이미 처리된 파일(`.old` 존재)은 재실행 시 자동 스킵

---

## 해상도별 비트레이트 기준

| 해상도 | 목표 비트레이트 | 상한 |
|---|---|---|
| 8K | 30,000k | 38,000k |
| 5K | 18,000k | 22,000k |
| 4K | 8,000k | 12,000k |
| 1080p | 원본의 65% | 2,000k |
| 720p | 원본의 65% | 1,200k |
| SD | 원본의 65% | 800k |

---

## 라이선스

MIT
