#!/usr/bin/env bash
# photo-autobackup — 촬영한 사진을 구글드라이브로 올리고, 검증에 성공한 것만 폰에서 치운다.
#
# 안전 원칙: 원본은 "업로드 완료 + 원격 MD5 == 로컬 MD5"가 확인된 뒤에만 로컬 휴지통으로
# 옮긴다. 해시를 확인할 수 없으면 실패로 간주하고 원본을 건드리지 않는다(fail-closed).
# 완전 삭제는 보관 기간이 지난 뒤 purge 단계에서만 일어난다.

# sh/dash 로 실행되면 bash 문법에서 조용히 깨진다. 명확히 알려주고 멈춘다.
if [ -z "${BASH_VERSION:-}" ]; then
  echo "이 스크립트는 bash 로 실행해야 한다:  bash $0 $*" >&2
  exit 1
fi

set -uo pipefail

VERSION="1.8.0"
CONFIG_FILE="${PHOTO_AUTOBACKUP_CONFIG:-$HOME/.config/photo-autobackup/config.env}"

# ---------------------------------------------------------------- 설정 기본값
RCLONE_REMOTE="gdrive"
DRIVE_FOLDER="PhoneCamera"
WATCH_DIRS="$HOME/storage/dcim/Camera"
EXTENSIONS="jpg jpeg png heic heif dng webp"
# 동영상은 따로 다룬다. 사진과 섞이면 드라이브 폴더가 뒤죽박죽이 되고, 크기가 훨씬
# 커서 진행 상황을 가늠하기도 어렵다.
VIDEO_EXTENSIONS="mp4 mov m4v 3gp mkv avi webm"
VIDEO_DRIVE_FOLDER="동영상"
STATE_DIR="$HOME/.local/share/photo-autobackup"
MIN_AGE_SECONDS=20
POLL_SECONDS=60
RETENTION_DAYS=30
MAX_ATTEMPTS=5
DRY_RUN=0
RCLONE_EXTRA_ARGS=""

# 감시 모드에서 드라이브에 쌓는 방식: date(연/연-월) 또는 mirror(폰 폴더 구조 그대로)
LAYOUT="date"
# 일괄 이관(migrate)에서 쓸 방식. 폰 폴더 구조를 그대로 옮기는 게 기본이다.
MIGRATE_LAYOUT="mirror"
# 일괄 이관이 훑을 최상위 경로. SD카드가 있으면 여기에 덧붙인다.
MIGRATE_ROOTS="$HOME/storage/shared"
# 1이면 Wi-Fi에 붙어 있을 때만 업로드한다.
REQUIRE_WIFI=0

# --- 통화녹취 -----------------------------------------------------------------
# 기본은 꺼져 있다. 통화 녹취에는 상대방 음성이 담기므로, 사용자가 명시적으로
# 켜기 전에 클라우드로 올라가면 사고다.
CALL_ENABLED=0
CALL_DIRS=""                       # 비면 자동 탐색
CALL_EXTENSIONS="m4a mp3 amr wav aac 3gpp"
TRANSCRIPT_EXTENSIONS="txt md json srt vtt"
CALL_DRIVE_IN="수신녹취"
CALL_DRIVE_OUT="발신통화녹취"
CALL_DRIVE_UNKNOWN="통화녹취_미분류"
CALL_IN_PATTERN="수신|받은|incoming|_in_|^in[-_]"
CALL_OUT_PATTERN="발신|보낸|outgoing|_out_|^out[-_]"
CALL_LOG_WINDOW=90                 # 통화기록 대조 허용 오차(초)

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  TRASH_DIR="${TRASH_DIR:-$STATE_DIR/trash}"
  LOG_FILE="${LOG_FILE:-$STATE_DIR/autobackup.log}"
  MANIFEST="$TRASH_DIR/manifest.tsv"
  FAILURES="$STATE_DIR/failures.tsv"
  LEDGER="$STATE_DIR/uploaded.tsv"
  mkdir -p "$STATE_DIR" "$TRASH_DIR" "$(dirname "$LOG_FILE")"
  [ -f "$MANIFEST" ] || printf 'moved_at\toriginal_path\ttrash_path\tremote_path\tmd5\n' > "$MANIFEST"
  [ -f "$FAILURES" ] || : > "$FAILURES"
  [ -f "$LEDGER" ] || : > "$LEDGER"
}

# ------------------------------------------------------------------- 유틸리티
log() {
  local level="$1"; shift
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
  printf '%s\n' "$line" >&2
  printf '%s\n' "$line" >> "$LOG_FILE"
}

die() { log ERROR "$*"; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

resolve_dir() { readlink -f "$1" 2>/dev/null || printf '%s' "$1"; }

all_extensions() { printf '%s %s' "$EXTENSIONS" "$VIDEO_EXTENSIONS"; }

# 확장자로 동영상인지 본다. 대소문자를 가리지 않는다(.MP4 도 동영상이다).
is_video() {
  local ext lower
  lower=$(printf '%s' "${1##*.}" | tr 'A-Z' 'a-z')
  for ext in $VIDEO_EXTENSIONS; do
    [ "$lower" = "$ext" ] && return 0
  done
  return 1
}

# 이 파일이 들어갈 드라이브 최상위 폴더 — 사진과 동영상을 갈라 준다.
base_folder_for() {
  if is_video "$1" && [ -n "$VIDEO_DRIVE_FOLDER" ]; then
    printf '%s' "$VIDEO_DRIVE_FOLDER"
  else
    printf '%s' "$DRIVE_FOLDER"
  fi
}

human() {
  local b="${1:-0}"
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB",u," "); i=1
    while (b>=1024 && i<5) { b/=1024; i++ }
    printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i]
  }'
}

# 갤러리(MediaStore) 색인에서 사라지게 한다. termux-api가 없으면 조용히 넘어간다.
media_scan() {
  have termux-media-scan && termux-media-scan -f "$1" >/dev/null 2>&1
  return 0
}

md5_of() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

# 긴 작업이 끝났을 때 폰 알림을 띄운다. 몇 시간짜리 이관을 터미널만 쳐다보며
# 기다리게 하지 않으려는 것이다. termux-api 가 없으면 조용히 넘어간다.
notify() {
  local title="$1" body="$2"
  have termux-notification || return 0
  termux-notification --id photo-autobackup --title "$title" --content "$body" \
    --priority high >/dev/null 2>&1
  return 0
}

# 권한 토글은 사람이 눌러야만 켜진다. 대신 어느 메뉴인지 찾아 헤매지 않도록
# 해당 설정 화면을 폰에서 바로 띄워 준다.
open_settings() {
  have am || return 1
  am start -a "$1" -d "package:com.termux" >/dev/null 2>&1
}

# 사진이 실제로 어디에 있는지 폰에서 직접 찾아낸다. DCIM/Camera 를 가정하면
# 기기·앱마다 다른 실제 경로를 놓친다 — 이게 "안 된다"의 흔한 원인이다.
detect_roots() {
  local d
  [ -d "$HOME/storage/shared" ] && printf '%s\n' "$HOME/storage/shared"
  for d in /storage/*; do
    case "$(basename "$d" 2>/dev/null)" in
      emulated|self|sdcard0|container|"*") continue ;;
    esac
    [ -d "$d" ] && [ -r "$d" ] && printf '%s\n' "$d"
  done
}

detect_photo_dirs() {
  discover_all 2>/dev/null | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn
}

# REQUIRE_WIFI=1인데 판정 수단이 없으면 진행을 막는다. 요금을 지키려고 켠 옵션이
# 판정 불가라는 이유로 무력화되면 켠 의미가 없다.
wifi_ok() {
  [ "$REQUIRE_WIFI" = "1" ] || return 0
  if ! have termux-wifi-connectioninfo; then
    log WARN "REQUIRE_WIFI=1이지만 termux-api가 없어 Wi-Fi 여부를 알 수 없다 (pkg install termux-api). 업로드를 보류한다."
    return 1
  fi
  termux-wifi-connectioninfo 2>/dev/null | grep -q '"supplicant_state"[[:space:]]*:[[:space:]]*"COMPLETED"'
}

# 파일이 아직 기록 중일 수 있으므로, 충분히 오래됐고 크기가 안정된 것만 다룬다.
is_stable() {
  local f="$1" mtime now size1 size2
  mtime=$(stat -c %Y "$f" 2>/dev/null) || return 1
  now=$(date +%s)
  [ $((now - mtime)) -ge "$MIN_AGE_SECONDS" ] || return 1
  size1=$(stat -c %s "$f" 2>/dev/null) || return 1
  sleep 1
  size2=$(stat -c %s "$f" 2>/dev/null) || return 1
  [ "$size1" = "$size2" ] && [ "$size1" -gt 0 ]
}

# 실패 횟수 추적 — 망가진 파일 하나 때문에 매 주기마다 모바일 데이터를 태우지 않도록.
attempts_of() {
  local key="$1"
  awk -F'\t' -v k="$key" '$1==k {print $2}' "$FAILURES" | tail -n1
}

record_failure() {
  local key="$1" n
  n=$(attempts_of "$key"); n=${n:-0}
  n=$((n + 1))
  local tmp="$FAILURES.tmp"
  awk -F'\t' -v k="$key" '$1!=k' "$FAILURES" > "$tmp" 2>/dev/null || : > "$tmp"
  printf '%s\t%s\n' "$key" "$n" >> "$tmp"
  mv "$tmp" "$FAILURES"
}

clear_failure() {
  local key="$1" tmp="$FAILURES.tmp"
  awk -F'\t' -v k="$key" '$1!=k' "$FAILURES" > "$tmp" 2>/dev/null || : > "$tmp"
  mv "$tmp" "$FAILURES"
}

# 드라이브 안에서 이 파일이 놓일 폴더를 정한다.
#   date   : PhoneCamera/2026/2026-08
#   mirror : Z폴드 8 사진/DCIM/Camera    (폰의 폴더 구조를 그대로 재현)
remote_dir_for() {
  local f="$1" mode="${2:-$LAYOUT}" ymd root real rel base
  base=$(base_folder_for "$f")
  if [ "$mode" = "mirror" ]; then
    for root in $MIGRATE_ROOTS; do
      real=$(resolve_dir "$root")
      case "$f" in
        "$real"/*)
          rel=$(dirname "${f#"$real"/}")
          if [ "$rel" = "." ]; then printf '%s' "$base"
          else printf '%s/%s' "$base" "$rel"; fi
          return ;;
      esac
    done
  fi
  ymd=$(date -d "@$(stat -c %Y "$f")" '+%Y/%Y-%m' 2>/dev/null) || ymd=$(date '+%Y/%Y-%m')
  printf '%s/%s' "$base" "$ymd"
}

rclone_run() {
  # shellcheck disable=SC2086
  rclone "$@" $RCLONE_EXTRA_ARGS
}

remote_md5() {
  # rclone hashsum 출력: "<md5>  <name>"
  rclone_run hashsum MD5 "$1" 2>/dev/null | awk 'NF {print $1; exit}'
}

# ------------------------------------------------------------- 업로드 + 검증
# 사진은 올린 뒤 폰에서 치우고, 통화녹취는 올린 뒤 폰에 남긴다. 두 정책이 갈리는
# 지점은 마지막 한 단계뿐이므로, 그 앞의 "올리고 해시로 확인한다"를 여기로 모은다.
#
# 성공 시 0 을 돌려주고 UPLOADED_REL 에 최종 원격 경로(폴더/파일명)를 담는다.
UPLOADED_REL=""
upload_and_verify() {
  local src="$1" rdir="$2" conflict="${3:-rename}"
  local base rpath lmd5 rmd5
  UPLOADED_REL=""

  base=$(basename "$src")
  lmd5=$(md5_of "$src")
  [ -n "$lmd5" ] || { log WARN "해시 계산 실패, 건너뜀: $src"; return 1; }
  rpath="$RCLONE_REMOTE:$rdir/$base"

  # 같은 이름이 이미 있으면: 내용이 같으면 업로드 생략, 다르면 이름을 구분해 준다.
  rmd5=$(remote_md5 "$rpath")
  if [ -n "$rmd5" ] && [ "$rmd5" != "$lmd5" ] && [ "$conflict" = "rename" ]; then
    local stem ext
    stem="${base%.*}"; ext="${base##*.}"
    if [ "$stem" = "$base" ]; then base="${base}-${lmd5:0:8}"
    else base="${stem}-${lmd5:0:8}.${ext}"; fi
    rpath="$RCLONE_REMOTE:$rdir/$base"
    rmd5=$(remote_md5 "$rpath")
    log INFO "원격에 동명이인 파일이 있어 이름을 바꿔 올린다: $base"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log INFO "[DRY-RUN] 업로드 예정: $src -> $rdir/$base"
    return 1
  fi

  if [ "$rmd5" = "$lmd5" ]; then
    log INFO "이미 업로드되어 있음, 검증만 통과: $base"
  else
    if ! rclone_run copyto "$src" "$rpath"; then
      log WARN "업로드 실패: $src"
      return 1
    fi
    rmd5=$(remote_md5 "$rpath")
  fi

  # 안전장치의 핵심 — 해시가 비었거나 다르면 로컬을 건드릴 자격이 없다.
  if [ -z "$rmd5" ]; then
    log WARN "원격 해시를 읽지 못했다: $base"
    return 1
  fi
  if [ "$rmd5" != "$lmd5" ]; then
    log WARN "해시 불일치(local=$lmd5 remote=$rmd5): $base"
    return 1
  fi

  UPLOADED_REL="$rdir/$base"
  UPLOADED_MD5="$lmd5"
  return 0
}

# --------------------------------------------------------------- 파일 한 건 처리
# 사진·동영상 정책: 올리고 검증한 뒤 폰에서 치운다(휴지통으로 이동).
# 성공 시 0, 그 외 1.
process_file() {
  local src="$1" mode="${2:-$LAYOUT}"
  local rdir target base

  rdir=$(remote_dir_for "$src" "$mode")
  upload_and_verify "$src" "$rdir" || return 1

  base=$(basename "$UPLOADED_REL")
  target="$TRASH_DIR/$(date '+%Y%m%d-%H%M%S')-$base"
  if ! mv "$src" "$target" 2>/dev/null; then
    log WARN "휴지통 이동 실패(저장소 권한 확인 필요): $src"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$src" "$target" "$UPLOADED_REL" "$UPLOADED_MD5" >> "$MANIFEST"
  media_scan "$src"
  log INFO "업로드+검증 완료, 휴지통으로 이동: $base"
  return 0
}

# 통화녹취 정책: 올리고 검증한 뒤 폰에 그대로 둔다(복사).
# 파일이 계속 남으므로, 매번 원격 해시를 물어보면 통화 수가 쌓일수록 느려진다.
# 올린 것을 장부에 적어 두고 내용이 그대로면 통신 없이 건너뛴다.
copy_file() {
  local src="$1" rdir="$2" conflict="${3:-rename}"
  local lmd5 seen

  lmd5=$(md5_of "$src")
  [ -n "$lmd5" ] || { log WARN "해시 계산 실패, 건너뜀: $src"; return 1; }

  seen=$(awk -F'\t' -v k="$src" '$1==k {print $2}' "$LEDGER" 2>/dev/null | tail -n1)
  if [ "$seen" = "$lmd5" ]; then
    return 2   # 이미 올렸고 내용도 그대로 — 조용히 넘어간다
  fi

  upload_and_verify "$src" "$rdir" "$conflict" || return 1

  local tmp="$LEDGER.tmp"
  awk -F'\t' -v k="$src" '$1!=k' "$LEDGER" > "$tmp" 2>/dev/null || : > "$tmp"
  printf '%s\t%s\t%s\t%s\n' "$src" "$lmd5" "$UPLOADED_REL" "$(date '+%Y-%m-%d %H:%M:%S')" >> "$tmp"
  mv "$tmp" "$LEDGER"
  log INFO "업로드+검증 완료, 폰에는 그대로 둔다: $(basename "$src")"
  return 0
}

# ------------------------------------------------------------------ 대상 수집
collect_candidates() {
  local d ext args=()
  for ext in $(all_extensions); do args+=(-iname "*.${ext}" -o); done
  unset 'args[${#args[@]}-1]'
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    d=$(resolve_dir "$d"); [ -d "$d" ] || continue
    find "$d" -type f \( "${args[@]}" \) ! -name '.*' ! -name '*.pending' ! -name '*.trashed*' 2>/dev/null
  done < <(printf '%s\n' $WATCH_DIRS)
}

# 폰 전체에서 '진짜 사진'만 골라낸다. 앱 캐시·썸네일·다운로드 임시파일은 건너뛴다 —
# 이런 것까지 올리면 드라이브가 쓰레기로 차고, 지우면 앱이 깨진다.
discover_all() {
  local root real args=() ext
  for ext in $(all_extensions); do args+=(-iname "*.${ext}" -o); done
  unset 'args[${#args[@]}-1]'
  for root in $MIGRATE_ROOTS; do
    real=$(resolve_dir "$root"); [ -d "$real" ] || continue
    find "$real" \
      \( -name '.thumbnails' -o -name 'cache' -o -name 'Cache' -o -name '.cache' \
         -o -path '*/Android/data' -o -path '*/Android/obb' -o -name '.trashed*' \) -prune -o \
      -type f \( "${args[@]}" \) \
      ! -name '.*' ! -name '*.pending' ! -name '*.trashed*' \
      ! -path "$TRASH_DIR/*" ! -path "$STATE_DIR/*" \
      -print 2>/dev/null
  done
}

# ------------------------------------------------------------------ 한 번 훑기
cmd_once() {
  local f n_ok=0 n_skip=0 n_fail=0 attempts
  wifi_ok || { log INFO "Wi-Fi 대기 중 — 이번 주기는 건너뛴다"; return 0; }
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    attempts=$(attempts_of "$f"); attempts=${attempts:-0}
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then
      n_skip=$((n_skip + 1)); continue
    fi
    is_stable "$f" || { n_skip=$((n_skip + 1)); continue; }
    if process_file "$f"; then
      clear_failure "$f"; n_ok=$((n_ok + 1))
    else
      record_failure "$f"; n_fail=$((n_fail + 1))
    fi
  done < <(collect_candidates)
  log INFO "훑기 완료 — 처리 $n_ok건, 보류 $n_skip건, 실패 $n_fail건"
  cmd_purge quiet
}

# ------------------------------------------------- 일괄 이관 (폰에 있는 사진 전부)
cmd_migrate() {
  local yes=0 f list count=0 bytes=0 n_ok=0 n_fail=0 sz
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes|-y) yes=1 ;;
      *) die "알 수 없는 옵션: $1 (사용법: migrate [--yes])" ;;
    esac
    shift
  done

  list=$(mktemp)
  discover_all | sort > "$list"
  count=$(wc -l < "$list" | tr -d ' ')

  if [ "$count" = "0" ]; then
    rm -f "$list"
    log INFO "옮길 사진이 없다. 폰이 이미 비어 있다."
    return 0
  fi

  local p_n=0 p_b=0 v_n=0 v_b=0
  while IFS= read -r f; do
    sz=$(stat -c %s "$f" 2>/dev/null) || sz=0
    bytes=$((bytes + sz))
    if is_video "$f"; then v_n=$((v_n + 1)); v_b=$((v_b + sz))
    else                   p_n=$((p_n + 1)); p_b=$((p_b + sz)); fi
  done < "$list"

  echo
  echo "======================= 이관 계획 ======================="
  echo "대상 파일 : ${count}건  (사진 ${p_n} / 동영상 ${v_n})"
  echo "총 용량   : $(human "$bytes")  (사진 $(human "$p_b") / 동영상 $(human "$v_b"))"
  echo "사진 →    : $RCLONE_REMOTE:$DRIVE_FOLDER/"
  if [ "$v_n" -gt 0 ]; then
    echo "동영상 →  : $RCLONE_REMOTE:$VIDEO_DRIVE_FOLDER/"
  fi
  echo "정리 방식 : 폰 폴더 구조 그대로"
  echo "삭제 방식 : 검증 성공한 것만 휴지통으로 이동 (${RETENTION_DAYS}일 보관 후 완전 삭제)"
  echo
  echo "폴더별 내역 (상위 20개):"
  sed 's|/[^/]*$||' "$list" | sort | uniq -c | sort -rn | head -20 \
    | awk '{c=$1; $1=""; sub(/^ /,""); printf "  %6d건  %s\n", c, $0}'
  echo "========================================================"
  echo

  if have rclone && rclone_run about "$RCLONE_REMOTE:" >/dev/null 2>&1; then
    echo "드라이브 여유 공간:"
    rclone_run about "$RCLONE_REMOTE:" 2>/dev/null | sed 's/^/  /'
    echo
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log INFO "[DRY-RUN] 위 계획만 보여주고 종료한다. 실제로 올리려면 DRY_RUN=0으로 바꿔라."
    rm -f "$list"; return 0
  fi

  if [ "$yes" != "1" ]; then
    printf '위 %s건을 드라이브로 옮기고 폰에서 치운다. 진행하려면 yes 를 입력해라: ' "$count"
    local answer; read -r answer
    [ "$answer" = "yes" ] || { echo "중단했다."; rm -f "$list"; return 1; }
  fi

  wifi_ok || { rm -f "$list"; die "Wi-Fi 연결을 기다리는 중이라 이관을 시작하지 않는다."; }

  have termux-wake-lock && termux-wake-lock
  log INFO "일괄 이관 시작 — ${count}건 / $(human "$bytes")"
  local i=0
  while IFS= read -r f; do
    i=$((i + 1))
    [ -f "$f" ] || continue
    if process_file "$f" "$MIGRATE_LAYOUT"; then
      clear_failure "$f"; n_ok=$((n_ok + 1))
    else
      record_failure "$f"; n_fail=$((n_fail + 1))
    fi
    if [ $((i % 25)) = 0 ]; then
      log INFO "진행 $i/$count (성공 $n_ok, 실패 $n_fail)"
    fi
  done < "$list"
  have termux-wake-unlock && termux-wake-unlock
  rm -f "$list"

  log INFO "일괄 이관 종료 — 성공 $n_ok건, 실패 $n_fail건"

  local left
  left=$(discover_all | wc -l | tr -d ' ')
  if [ "$n_fail" = "0" ] && [ "$left" = "0" ]; then
    notify "이관 완료" "${n_ok}건을 옮기고 폰을 비웠다. 휴지통을 비워야 실제 공간이 생긴다."
  else
    notify "이관 종료 (확인 필요)" "성공 ${n_ok}건, 실패 ${n_fail}건, 폰에 ${left}건 남음"
  fi

  echo
  cmd_verify_empty
}

# ------------------------------------------------- 폰에 사진이 남았는지 최종 확인
cmd_verify_empty() {
  local left
  left=$(discover_all | wc -l | tr -d ' ')
  if [ "$left" = "0" ]; then
    echo "확인: 폰에 남은 사진이 없다. (검사 범위: $MIGRATE_ROOTS)"
    return 0
  fi
  echo "확인: 아직 ${left}건이 폰에 남아 있다."
  echo "남은 위치:"
  discover_all | sed 's|/[^/]*$||' | sort | uniq -c | sort -rn | head -20 \
    | awk '{c=$1; $1=""; sub(/^ /,""); printf "  %6d건  %s\n", c, $0}'
  echo
  echo "로그에서 이유를 확인해라: $LOG_FILE"
  echo "  · 업로드 실패/해시 불일치 → 원본은 일부러 남긴 것이다"
  echo "  · '휴지통 이동 실패' → 저장소 권한 문제 (doctor 참고)"
  echo "  · 5회 실패로 중단된 파일은 reset-failures 후 재시도"
  return 1
}

# --------------------------------------------------------------------- 감시 모드
cmd_watch() {
  have termux-wake-lock && termux-wake-lock
  trap 'have termux-wake-unlock && termux-wake-unlock; exit 0' INT TERM
  log INFO "감시 시작 (v$VERSION, 주기 ${POLL_SECONDS}s, 대상: $WATCH_DIRS)"
  while :; do
    cmd_once
    [ "$CALL_ENABLED" = "1" ] && cmd_calls >/dev/null 2>&1
    if have inotifywait; then
      # 새 파일이 생기면 즉시 깨어나고, 아무 일 없으면 주기마다 한 번 돈다.
      # 통화녹취를 켰다면 녹음 폴더도 함께 지켜본다 — 안 그러면 "통화가 끝나면
      # 바로 올라간다"가 실제로는 폴링 주기만큼 늦는다.
      local wdirs=()
      while IFS= read -r _d; do [ -n "$_d" ] && wdirs+=("$_d"); done < <(printf '%s\n' $WATCH_DIRS)
      if [ "$CALL_ENABLED" = "1" ]; then
        while IFS= read -r _d; do [ -n "$_d" ] && wdirs+=("$_d"); done < <(discover_call_dirs)
      fi
      # -r 이 없으면 하위 폴더(Recordings/Call)에 생기는 파일을 놓친다.
      inotifywait -q -r -e close_write,moved_to -t "$POLL_SECONDS" "${wdirs[@]}" >/dev/null 2>&1
      sleep "$MIN_AGE_SECONDS"
    else
      sleep "$POLL_SECONDS"
    fi
  done
}

# --------------------------------------------------------------------- 휴지통 정리
cmd_purge() {
  local quiet="${1:-}" n=0 f
  while IFS= read -r f; do
    rm -f "$f" && n=$((n + 1))
  done < <(find "$TRASH_DIR" -type f ! -name 'manifest.tsv' -mtime "+$RETENTION_DAYS" 2>/dev/null)
  if [ "$n" -gt 0 ]; then
    log INFO "휴지통에서 ${RETENTION_DAYS}일 지난 $n건 완전 삭제"
  elif [ "$quiet" != "quiet" ]; then
    log INFO "완전 삭제할 만큼 오래된 파일 없음"
  fi
}

# ------------------------------------------------------------------------ 복구
cmd_restore() {
  local pattern="${1:-}" restored=0
  [ -n "$pattern" ] || die "사용법: photo-autobackup.sh restore <파일이름 일부|all>"
  while IFS=$'\t' read -r _ orig trash _ _; do
    [ -f "$trash" ] || continue
    if [ "$pattern" = "all" ] || [[ "$trash" == *"$pattern"* ]]; then
      mkdir -p "$(dirname "$orig")"
      if mv "$trash" "$orig" 2>/dev/null; then
        media_scan "$orig"
        log INFO "복구: $orig"
        restored=$((restored + 1))
      else
        log WARN "복구 실패: $orig"
      fi
    fi
  done < <(tail -n +2 "$MANIFEST")
  log INFO "복구 완료 — $restored건"
}

# --------------------------------------------------- 권한만 따로 보기 (짧게)
# 권한 문제는 종류가 셋인데 증상이 비슷해서 헷갈린다. 하나씩 갈라서 보여 준다.
cmd_perm() {
  local shared="$HOME/storage/shared" ok=1

  echo "── 권한 점검 ──────────────────────────────"

  # 1) Termux 저장소 연결 (termux-setup-storage)
  if [ -d "$shared" ]; then
    echo "1. 저장소 연결      : OK"
  else
    echo "1. 저장소 연결      : 안 됨  ← 여기부터 해결"
    echo "   지금 팝업을 띄운다. '허용'을 눌러라."
    have termux-setup-storage && termux-setup-storage
    sleep 3
    [ -d "$shared" ] && echo "   → 연결됨" || {
      echo "   → 아직 안 됨. 팝업을 거부했거나 안 떴다."
      echo "     설정 > 애플리케이션 > Termux > 권한 > 파일 및 미디어 > 허용"
      echo "     그다음 termux-setup-storage 를 다시 실행해라."
    }
    ok=0
  fi

  # 2) 읽기 — 사진이 보이는가
  if [ -d "$shared" ]; then
    local n
    n=$(discover_all 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" -gt 0 ]; then
      echo "2. 사진 읽기        : OK (${n}건 보임)"
    else
      echo "2. 사진 읽기        : 0건  ← 갤러리에 사진이 있다면 권한 문제다"
      ok=0
    fi
  fi

  # 3) 쓰기/삭제 — 실제로 파일을 만들어 지워 본다. 이게 진짜 판정이다.
  if [ -d "$shared" ]; then
    local probe="$shared/DCIM/.pab-permtest"
    mkdir -p "$shared/DCIM" 2>/dev/null
    if echo t > "$probe" 2>/dev/null && rm -f "$probe" 2>/dev/null; then
      echo "3. 삭제 권한        : OK"
    else
      echo "3. 삭제 권한        : 없음  ← 업로드는 되는데 폰에서 안 지워지는 원인"
      echo
      echo "   안드로이드 11+ 는 '모든 파일 접근'을 따로 켜야 한다."
      echo "   [삼성 One UI]"
      echo "     설정 > 애플리케이션 > 우측상단 ⋮ > 특별한 접근 권한"
      echo "       > 모든 파일에 접근할 수 있는 권한 > Termux 켜기"
      if open_settings android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION; then
        echo "   → 해당 설정 화면을 폰에 띄웠다. 켜고 돌아와서 다시 실행해라."
      fi
      ok=0
    fi
  fi

  echo "───────────────────────────────────────────"
  if [ "$ok" = "1" ]; then
    echo "권한은 전부 정상이다. 다음: photo-autobackup.sh setup"
  else
    echo "위에서 '안 됨/없음'이 뜬 항목을 처리하고 이 명령을 다시 실행해라."
  fi
  return $((1 - ok))
}

# ------------------------------------------------------- 자동 설정 (한 방에)
# 폰의 실제 상태를 읽어서 설정을 스스로 맞춘다. 사람이 값을 정해 넣지 않아도
# 되도록 하는 게 목적이다 — 잘못된 경로 가정이 "안 된다"의 가장 흔한 원인이라서다.
cmd_setup() {
  local folder="${1:-}" vfolder="${2:-}" roots cam dirs top

  echo "=========== photo-autobackup 자동 설정 (v$VERSION) ==========="

  # 1) 저장소 접근
  if [ ! -d "$HOME/storage" ]; then
    echo
    echo "[1/5] 저장소 접근 권한을 요청한다. 뜨는 팝업에서 '허용'을 눌러라."
    have termux-setup-storage && termux-setup-storage
    sleep 3
  else
    echo
    echo "[1/5] 저장소 접근: 이미 연결됨"
  fi
  [ -d "$HOME/storage/shared" ] || {
    echo "  ! 아직 연결되지 않았다. 권한을 허용한 뒤 이 명령을 다시 실행해라."
    return 1
  }

  # 2) 사진이 실제로 어디 있는지 찾는다
  echo
  echo "[2/5] 폰에서 사진이 있는 위치를 찾는 중..."
  roots=$(detect_roots | tr '\n' ' ')
  MIGRATE_ROOTS="$roots"
  dirs=$(detect_photo_dirs)
  if [ -z "$dirs" ]; then
    echo "  사진을 한 장도 못 찾았다. 검사 범위: $roots"
    echo "  갤러리에 사진이 있는데도 이렇다면 저장소 권한 문제다 — doctor --fix 를 실행해라."
  else
    echo "$dirs" | head -8 | awk '{c=$1; $1=""; sub(/^ /,""); printf "    %6d건  %s\n", c, $0}'
  fi

  # 카메라 폴더를 고른다: DCIM/Camera 가 있으면 그것, 없으면 사진이 제일 많은 폴더.
  cam=$(printf '%s\n' "$dirs" | awk '{$1=""; sub(/^ /,""); print}' | grep -m1 -i '/DCIM/Camera$' || true)
  if [ -z "$cam" ]; then
    top=$(printf '%s\n' "$dirs" | head -n1 | awk '{$1=""; sub(/^ /,""); print}')
    cam="${top:-$HOME/storage/dcim/Camera}"
  fi
  echo "  → 감시할 카메라 폴더: $cam"

  # 3) 설정 파일 기록
  echo
  echo "[3/5] 설정 파일을 쓴다: $CONFIG_FILE"
  [ -n "$folder" ] || folder="${DRIVE_FOLDER:-폰 사진}"
  # 동영상 폴더를 안 주면 사진 폴더 이름에서 '사진'을 '동영상'으로 바꿔 짝을 맞춘다.
  # 그래도 안 되면 그냥 '동영상'.
  if [ -z "$vfolder" ]; then
    case "$folder" in
      *사진*) vfolder="${folder%사진*}동영상${folder#*사진}" ;;
      *) vfolder="${VIDEO_DRIVE_FOLDER:-동영상}" ;;
    esac
  fi
  mkdir -p "$(dirname "$CONFIG_FILE")"
  [ -f "$CONFIG_FILE" ] && cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d-%H%M%S)"
  cat > "$CONFIG_FILE" <<CFG
# photo-autobackup — setup 이 폰 상태를 읽어 자동 생성했다 ($(date '+%Y-%m-%d %H:%M'))
RCLONE_REMOTE="$RCLONE_REMOTE"
DRIVE_FOLDER="$folder"
WATCH_DIRS="$cam"
MIGRATE_ROOTS="$roots"
LAYOUT="date"
MIGRATE_LAYOUT="mirror"
EXTENSIONS="$EXTENSIONS"
VIDEO_EXTENSIONS="$VIDEO_EXTENSIONS"
VIDEO_DRIVE_FOLDER="$vfolder"

# 통화녹취 — 기존 설정을 그대로 물려받는다(setup 을 다시 돌려도 꺼지지 않는다)
CALL_ENABLED=$CALL_ENABLED
CALL_DIRS="$CALL_DIRS"
CALL_EXTENSIONS="$CALL_EXTENSIONS"
TRANSCRIPT_EXTENSIONS="$TRANSCRIPT_EXTENSIONS"
CALL_DRIVE_IN="$CALL_DRIVE_IN"
CALL_DRIVE_OUT="$CALL_DRIVE_OUT"
CALL_DRIVE_UNKNOWN="$CALL_DRIVE_UNKNOWN"
CALL_IN_PATTERN="$CALL_IN_PATTERN"
CALL_OUT_PATTERN="$CALL_OUT_PATTERN"
CALL_LOG_WINDOW=$CALL_LOG_WINDOW
MIN_AGE_SECONDS=$MIN_AGE_SECONDS
POLL_SECONDS=$POLL_SECONDS
RETENTION_DAYS=$RETENTION_DAYS
MAX_ATTEMPTS=$MAX_ATTEMPTS
REQUIRE_WIFI=$REQUIRE_WIFI
DRY_RUN=$DRY_RUN
RCLONE_EXTRA_ARGS="$RCLONE_EXTRA_ARGS"
CFG
  echo "  사진 폴더     : $folder"
  echo "  동영상 폴더   : $vfolder"
  echo "  감시 폴더     : $cam"
  echo "  이관 검사 범위: $roots"
  load_config

  # 4) 고칠 수 있는 건 고친다
  echo
  echo "[4/5] 환경 점검 및 자동 수리"
  cmd_doctor --fix | sed 's/^/  /'

  # 5) 구글드라이브 연결 여부
  echo
  echo "[5/5] 구글드라이브 연결"
  if have rclone && rclone listremotes 2>/dev/null | grep -qx "$RCLONE_REMOTE:"; then
    if rclone_run lsd "$RCLONE_REMOTE:" >/dev/null 2>&1; then
      echo "  연결됨 — 바로 쓸 수 있다."
      echo
      echo "다음: photo-autobackup.sh migrate    (폰 사진 전부 옮기고 비우기)"
      echo "      photo-autobackup.sh watch      (앞으로 찍는 사진 자동 처리)"
      return 0
    fi
    echo "  리모트는 있는데 접속이 안 된다 → rclone config reconnect $RCLONE_REMOTE:"
    return 1
  fi
  cat <<GUIDE
  아직 구글 계정이 연결되지 않았다. 이 부분만은 구글 로그인이라 사람이 해야 한다:

    rclone config
      n                 (새 리모트)
      $RCLONE_REMOTE            (이름 — 이대로 적어라)
      drive             (구글드라이브)
      (client_id/secret 은 그냥 엔터)
      3                 (scope: drive.file — 이 앱이 만든 파일만 접근)
      (엔터)             (service account 없음)
      n                 (고급 설정 안 함)
      y                 (공용 client_id 종료 예정 경고가 뜨면 y — 지금은 동작한다)
      y                 (auto config — 폰에서는 y 다. n 이 아니다)
      → rclone 이 http://127.0.0.1:53682/auth?state=... 주소를 찍어 준다.
         그 주소를 길게 눌러 복사해 폰 브라우저에 붙여넣고 구글 로그인.
         같은 기기라 127.0.0.1 로 접속된다. 로그인하면 Termux 가 알아서 받아 간다.
      n                 (공유 드라이브 아님)
      y                 (저장)
      q                 (종료)

  끝나면 다시: photo-autobackup.sh setup
GUIDE
  return 1
}

# ===================================================================== 통화녹취
# 사진과 정책이 다르다: 올리되 폰에서 지우지 않는다(복사). 녹취는 작고, 사용자가
# 폰에서도 바로 듣기를 원하기 때문이다.

# 녹음 폴더는 기종·One UI 버전마다 다르다. 하나를 고정하면 다른 기기에서 통째로
# 실패하므로, 있는 것만 골라 쓴다.
discover_call_dirs() {
  local d real shared picked=() p dup
  if [ -n "$CALL_DIRS" ]; then
    # 줄바꿈으로 나눠 읽는다. 공백이 든 경로(`Call recordings`)를 단어로 쪼개면
    # 존재하지 않는 경로가 되어 "폴더를 못 찾았다"로 끝난다.
    while IFS= read -r d; do
      [ -n "$d" ] || continue
      real=$(resolve_dir "$d")
      if [ -d "$real" ]; then
        picked+=("$real")
      else
        # 한 줄에 여러 경로를 공백으로 적은 경우를 위한 편의 처리. 공백이 든
        # 경로가 우선이므로, 통째로 폴더가 아닐 때만 쪼개 본다.
        local w
        for w in $d; do
          real=$(resolve_dir "$w"); [ -d "$real" ] && picked+=("$real")
        done
      fi
    done < <(printf '%s\n' "$CALL_DIRS")
  else
    shared=$(resolve_dir "$HOME/storage/shared")
    for d in "$shared/Recordings/Call" "$shared/Recordings" "$shared/Call" "$shared/Sounds"; do
      [ -d "$d" ] && picked+=("$d")
    done
  fi
  # Recordings/Call 과 Recordings 를 둘 다 내보내면 같은 파일을 두 번 훑는다.
  # 해시 계산과 안정성 대기(1초)와 통화기록 조회가 전부 두 배가 된다.
  for d in "${picked[@]:-}"; do
    [ -n "$d" ] || continue
    dup=0
    for p in "${picked[@]:-}"; do
      [ "$p" = "$d" ] && continue
      case "$d" in "$p"/*) dup=1; break ;; esac
    done
    [ "$dup" = "0" ] && printf '%s\n' "$d"
  done
}

# 통화기록에서 파일 시각과 가장 가까운 항목의 방향을 읽는다.
# termux-call-log 출력은 JSON 배열이며 각 항목에 type(INCOMING/OUTGOING)과
# date("2026-08-19 14:32:00")가 들어 있다. jq 없이 처리한다 — 폰에 없을 수 있다.
# JSON 한 줄에서 값만 뽑는다. 값 안에 콜론이 있는 필드가 있어("00:10:00",
# "2026-08-19 14:32:00") 마지막 콜론을 구분자로 삼으면 값이 잘린다.
json_value() {
  printf '%s' "$1" | sed 's/^[^:]*: *//' | tr -d '",' | sed 's/^ *//; s/ *$//'
}

# "00:01:30" 또는 "90" 을 초로 바꾼다. 형식은 안드로이드 버전마다 다르다.
duration_seconds() {
  local d="$1"
  case "$d" in
    *:*:*) printf '%s' "$d" | awk -F: '{print $1*3600 + $2*60 + $3}' ;;
    *:*)   printf '%s' "$d" | awk -F: '{print $1*60 + $2}' ;;
    ''|*[!0-9]*) printf '0' ;;
    *)     printf '%s' "$d" ;;
  esac
}

# 스윕 한 번에 통화기록은 한 번만 읽는다.
CALL_LOG_CACHE=""
load_call_log() {
  have termux-call-log || return 1
  [ -n "$CALL_LOG_CACHE" ] && [ -f "$CALL_LOG_CACHE" ] && return 0
  CALL_LOG_CACHE=$(mktemp)
  termux-call-log -l 50 > "$CALL_LOG_CACHE" 2>/dev/null || { rm -f "$CALL_LOG_CACHE"; CALL_LOG_CACHE=""; return 1; }
  return 0
}

direction_from_call_log() {
  local mtime="$1" line type date_s dur epoch endt diff best_diff="" best=""
  load_call_log || return 1
  type=""; date_s=""; dur=""
  while IFS= read -r line; do
    case "$line" in
      *'"type"'*)     type=$(json_value "$line") ;;
      *'"duration"'*) dur=$(json_value "$line") ;;
      *'"date"'*)     date_s=$(json_value "$line") ;;
      *'}'*)
        # 항목 하나가 끝났다. 녹음 파일 mtime 은 통화가 '끝난' 시각이므로
        # 통화 시작 + 통화 시간 = 종료 시각과 견준다. 통화 시간을 무시하면
        # 90초 넘는 통화는 전부 판정에 실패한다.
        [ -n "$date_s" ] || { type=""; dur=""; continue; }
        epoch=$(date -d "$date_s" +%s 2>/dev/null) || { type=""; date_s=""; dur=""; continue; }
        endt=$(( epoch + $(duration_seconds "${dur:-0}") ))
        diff=$(( mtime > endt ? mtime - endt : endt - mtime ))
        if [ -z "$best_diff" ] || [ "$diff" -lt "$best_diff" ]; then
          best_diff="$diff"; best="$type"
        fi
        type=""; date_s=""; dur="" ;;
    esac
  done < "$CALL_LOG_CACHE"
  [ -n "$best_diff" ] || return 1
  [ "$best_diff" -le "$CALL_LOG_WINDOW" ] || return 1
  case "$best" in
    INCOMING) printf 'in' ;;
    OUTGOING) printf 'out' ;;
    *) return 1 ;;
  esac
}

# in / out / unknown 중 하나. 추측하지 않는다 — 모르면 unknown 이다.
# 잘못 분류하면 나중에 통화 내역 전체를 신뢰할 수 없게 된다.
call_direction() {
  local f="$1" base mtime dir
  base=$(basename "$f")
  if printf '%s' "$base" | grep -qiE "$CALL_IN_PATTERN";  then printf 'in';  return; fi
  if printf '%s' "$base" | grep -qiE "$CALL_OUT_PATTERN"; then printf 'out'; return; fi
  mtime=$(stat -c %Y "$f" 2>/dev/null) || { printf 'unknown'; return; }
  if dir=$(direction_from_call_log "$mtime"); then printf '%s' "$dir"; return; fi
  printf 'unknown'
}

call_folder_for() {
  case "$1" in
    in)  printf '%s' "$CALL_DRIVE_IN" ;;
    out) printf '%s' "$CALL_DRIVE_OUT" ;;
    *)   printf '%s' "$CALL_DRIVE_UNKNOWN" ;;
  esac
}

# 녹음 파일과 같은 이름의 전사 파일을 찾는다. 없으면 빈 문자열.
# 같은 이름(확장자만 다른) 형제 파일 중 주어진 부류에 드는 것을 돌려준다.
# 확장자 대소문자가 섞인 경우(.M4a)가 실제로 있으므로 소문자로 낮춰 비교한다.
siblings_of_class() {
  local f="$1" class="$2"
  local stem cand lower e found=1
  stem="${f%.*}"
  for cand in "$stem".*; do
    [ -f "$cand" ] || continue
    [ "$cand" = "$f" ] && continue
    lower=$(printf '%s' "${cand##*.}" | tr 'A-Z' 'a-z')
    case "$class" in
      audio)      for e in $CALL_EXTENSIONS;       do [ "$lower" = "$e" ] && { printf '%s\n' "$cand"; found=0; break; }; done ;;
      transcript) for e in $TRANSCRIPT_EXTENSIONS; do [ "$lower" = "$e" ] && { printf '%s\n' "$cand"; found=0; break; }; done ;;
    esac
  done
  return $found
}

paired_audio_of() { siblings_of_class "$1" audio | head -n1; }

is_transcript() {
  local lower ext
  lower=$(printf '%s' "${1##*.}" | tr 'A-Z' 'a-z')
  for ext in $TRANSCRIPT_EXTENSIONS; do [ "$lower" = "$ext" ] && return 0; done
  return 1
}

find_call_files() {
  local d args=() ext
  for ext in $CALL_EXTENSIONS $TRANSCRIPT_EXTENSIONS; do args+=(-iname "*.${ext}" -o); done
  [ ${#args[@]} -gt 0 ] && unset 'args[${#args[@]}-1]'
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    find "$d" -type f \( "${args[@]}" \) ! -name '.*' 2>/dev/null
  done < <(discover_call_dirs)
}

# 녹취는 연/연-월로 정리한다. 통화는 "언제"로 찾는 자료이기 때문이다.
call_remote_dir() {
  local f="$1" folder="$2" ymd
  ymd=$(date -d "@$(stat -c %Y "$f")" '+%Y/%Y-%m' 2>/dev/null) || ymd=$(date '+%Y/%Y-%m')
  printf '%s/%s' "$folder" "$ymd"
}

cmd_calls() {
  local f rc n_up=0 n_skip=0 n_fail=0 n_tr=0 seen_tr=0
  if [ "$CALL_ENABLED" != "1" ]; then
    echo "통화녹취 기능이 꺼져 있다. 켜려면 설정 파일에 CALL_ENABLED=1 을 넣어라:"
    echo "  $CONFIG_FILE"
    echo "먼저 'photo-autobackup.sh probe' 로 폰에 무엇이 있는지 확인하는 것을 권한다."
    return 1
  fi
  wifi_ok || { log INFO "Wi-Fi 대기 중 — 통화녹취 스윕을 건너뛴다"; return 0; }

  local dirs; dirs=$(discover_call_dirs | tr '\n' ' ')
  [ -n "$dirs" ] || { log WARN "녹음 폴더를 찾지 못했다. CALL_DIRS 를 직접 지정해라."; return 1; }
  log INFO "통화녹취 스윕 시작 — 대상 폴더: $dirs"

  # 통화기록은 여기서 한 번만 읽는다. call_direction 은 $(...) 안에서 불리므로
  # 그 안에서 캐시를 만들어 봤자 서브셸과 함께 사라지고, 파일 수만큼 조회하게 된다.
  load_call_log || true

  # 파일마다 독립적으로 처리한다. 전사를 녹음 처리 안에 끼워 넣으면, 녹음이
  # 건너뛰어지거나 실패할 때 전사가 어느 경로로도 올라가지 못한 채 조용히 사라진다.
  # 짝짓기는 "어느 폴더로 갈지"만 정하고, 업로드와 실패 집계는 모두가 같은 길을 탄다.
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    is_stable "$f" || { n_skip=$((n_skip + 1)); continue; }

    local attempts
    attempts=$(attempts_of "$f"); attempts=${attempts:-0}
    if [ "$attempts" -ge "$MAX_ATTEMPTS" ]; then n_skip=$((n_skip + 1)); continue; fi

    local anchor dir folder rdir conflict is_tr=0
    if is_transcript "$f"; then
      is_tr=1; seen_tr=$((seen_tr + 1))
      # 짝이 되는 녹음이 있으면 그 녹음과 같은 폴더로. 없으면 미분류로 보존한다.
      anchor=$(paired_audio_of "$f")
      [ -n "$anchor" ] || anchor="$f"
      # 전사는 같은 항목의 갱신이므로 이름을 유지한 채 덮어쓴다. 해시 접미사가
      # 붙으면 녹음과 이름이 어긋나 짝을 잃는다.
      conflict="overwrite"
    else
      anchor="$f"; conflict="rename"
    fi

    if [ "$anchor" = "$f" ] && [ "$is_tr" = "1" ]; then
      folder="$CALL_DRIVE_UNKNOWN"
    else
      dir=$(call_direction "$anchor")
      folder=$(call_folder_for "$dir")
    fi
    rdir=$(call_remote_dir "$anchor" "$folder")

    copy_file "$f" "$rdir" "$conflict"; rc=$?
    case $rc in
      0) clear_failure "$f"; n_up=$((n_up + 1)); [ "$is_tr" = "1" ] && n_tr=$((n_tr + 1)) ;;
      2) n_skip=$((n_skip + 1)) ;;
      *) record_failure "$f"; n_fail=$((n_fail + 1)) ;;
    esac
  done < <(find_call_files)

  [ -n "$CALL_LOG_CACHE" ] && { rm -f "$CALL_LOG_CACHE"; CALL_LOG_CACHE=""; }

  log INFO "통화녹취 스윕 종료 — 업로드 $n_up건(전사 $n_tr), 건너뜀 $n_skip건, 실패 $n_fail건"
  if [ "$seen_tr" = "0" ]; then
    log INFO "전사 파일을 하나도 찾지 못했다. 앱이 텍스트를 파일로 저장하지 않거나 다른 위치일 수 있다 — probe 로 확인해라."
  fi
  return 0
}

# ------------------------------------------------------- 폰에 무엇이 있는지 조사
# 읽기 전용. 아무것도 올리거나 지우지 않는다.
cmd_probe() {
  local shared d n sample f cnt
  shared=$(resolve_dir "$HOME/storage/shared")
  echo "========== 통화녹취 환경 조사 (v$VERSION) =========="
  echo

  echo "[1] 녹음 폴더 후보"
  local found=0
  for d in "$shared/Recordings/Call" "$shared/Recordings" "$shared/Call" "$shared/Sounds"; do
    if [ -d "$d" ]; then
      n=$(find "$d" -type f 2>/dev/null | wc -l | tr -d ' ')
      printf '  [있음] %-45s 파일 %s건\n' "${d#$shared/}" "$n"
      found=1
    else
      printf '  [없음] %s\n' "${d#$shared/}"
    fi
  done
  [ "$found" = "1" ] || echo "  → 후보가 하나도 없다. 통화 녹음 설정이 꺼져 있을 수 있다."
  echo

  echo "[2] 확장자별 분포 (녹음 폴더 안)"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    find "$d" -type f 2>/dev/null | sed 's/.*\.//' | tr 'A-Z' 'a-z' | sort | uniq -c | sort -rn | head -8 \
      | awk '{printf "  %6d건  .%s\n", $1, $2}'
  done < <(discover_call_dirs)
  echo

  echo "[3] 파일 이름 샘플 (최근 5건) — 수신/발신이 이름에 적히는지 본다"
  cnt=0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '  %s\n' "$(basename "$f")"
    printf '      판정: %s\n' "$(call_direction "$f")"
    cnt=$((cnt + 1)); [ "$cnt" -ge 5 ] && break
  done < <(find_call_files 2>/dev/null | head -20)
  [ "$cnt" = "0" ] && echo "  (녹음 파일 없음)"
  echo

  echo "[4] 전사(텍스트) 파일"
  local tn=0
  while IFS= read -r f; do
    is_transcript "$f" && { tn=$((tn + 1)); [ "$tn" -le 3 ] && printf '  %s\n' "$(basename "$f")"; }
  done < <(find_call_files 2>/dev/null)
  if [ "$tn" = "0" ]; then
    echo "  없음 — 앱이 전사를 파일로 저장하지 않거나, 앱 내부 저장소에만 둔다."
    echo "  이 경우 녹취(음성)만 올리고 전사는 앱의 내보내기/공유 기능을 써야 한다."
  else
    echo "  총 ${tn}건 발견"
  fi
  echo

  echo "[5] 통화기록 API (파일명으로 판정 안 될 때 쓰는 수단)"
  if have termux-call-log; then
    if termux-call-log -l 1 >/dev/null 2>&1; then
      echo "  [OK] 사용 가능 — 파일명에 수신/발신이 없어도 시각 대조로 판정한다"
    else
      echo "  [실패] 명령은 있으나 권한이 없다."
      echo "         설정 > 애플리케이션 > Termux:API > 권한 > 통화기록 허용"
    fi
  else
    echo "  [없음] pkg install termux-api"
    echo "         없으면 파일명으로 판정 못 한 녹취는 전부 '$CALL_DRIVE_UNKNOWN' 로 간다"
  fi
  echo

  echo "[6] 현재 설정"
  echo "  CALL_ENABLED = $CALL_ENABLED $([ "$CALL_ENABLED" = "1" ] && echo '(켜짐)' || echo '(꺼짐 — 켜야 동작한다)')"
  echo "  수신 → $RCLONE_REMOTE:$CALL_DRIVE_IN/"
  echo "  발신 → $RCLONE_REMOTE:$CALL_DRIVE_OUT/"
  echo "  미분류 → $RCLONE_REMOTE:$CALL_DRIVE_UNKNOWN/"
  echo "  정책: 업로드 후에도 폰에 그대로 둔다(복사)"
  echo "=================================================="
}

# ------------------------------------------------------------------- 자체 업데이트
# 폰에서 긴 URL 을 붙여넣는 건 고역이다. 스크립트가 스스로 최신본을 받아오게 한다.
UPDATE_URL="${UPDATE_URL:-https://raw.githubusercontent.com/cinero21-lgtm/yangdose-tax-calculator/claude/auto-photo-upload-delete-4prnja/.claude/skills/photo-drive-autobackup/scripts/photo-autobackup.sh}"

cmd_update() {
  local self tmp newver
  # PATH 에 있는 것이 아니라 "지금 실행 중인 이 파일"을 갱신해야 한다.
  # 여러 벌이 깔려 있을 때 엉뚱한 것을 고치면 갱신했는데 그대로인 상황이 된다.
  self="$0"
  [ -f "$self" ] || self="$(command -v photo-autobackup.sh 2>/dev/null)"
  [ -n "$self" ] || die "갱신할 파일을 찾지 못했다."
  # 심볼릭 링크면 실체를 고쳐야 한다. 링크를 덮어쓰면 링크가 끊긴다.
  self="$(readlink -f "$self" 2>/dev/null || printf '%s' "$self")"
  [ -w "$self" ] || die "쓸 수 없다: $self"

  tmp="$(mktemp)"
  echo "내려받는 중..."
  if ! curl -fsSL "$UPDATE_URL" -o "$tmp"; then
    rm -f "$tmp"; die "내려받기 실패. 인터넷 연결을 확인해라."
  fi
  # 받다 만 파일로 덮어쓰면 도구 자체가 죽는다. 실행 가능한지 먼저 본다.
  if ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"; die "받은 파일이 온전하지 않다. 덮어쓰지 않았다."
  fi
  newver=$(grep -m1 '^VERSION=' "$tmp" | cut -d'"' -f2)
  [ -n "$newver" ] || { rm -f "$tmp"; die "버전을 못 읽었다. 덮어쓰지 않았다."; }

  cp "$self" "$self.bak" 2>/dev/null
  cat "$tmp" > "$self"
  rm -f "$tmp"
  chmod 755 "$self"
  # 안드로이드에는 /usr/bin 이 없다. 실제 bash 경로로 다시 박는다.
  local rb; rb="$(command -v bash)"
  [ -n "$rb" ] && sed -i "1s|^#!.*|#!$rb|" "$self"

  if [ "$newver" = "$VERSION" ]; then
    echo "이미 최신이다 (v$VERSION). 파일은 새로 받아 두었다."
  else
    echo "업데이트 완료: v$VERSION -> v$newver"
  fi
  echo "  이전본: $self.bak"
}

# ------------------------------------------------------------------------ 진단
cmd_doctor() {
  local ok=1 d fix=0
  [ "${1:-}" = "--fix" ] && fix=1
  echo "photo-autobackup doctor (v$VERSION)$([ "$fix" = 1 ] && echo ' --fix (고칠 수 있는 건 자동으로 고친다)')"
  echo "설정 파일: $CONFIG_FILE $([ -f "$CONFIG_FILE" ] && echo '(있음)' || echo '(없음 — 기본값 사용)')"

  if ! have rclone && [ "$fix" = 1 ] && have pkg; then
    echo "  [고침] rclone 설치 중..."; pkg install -y rclone >/dev/null 2>&1
  fi
  if have rclone; then echo "  [OK] rclone 설치됨: $(rclone version | head -n1)"
  else echo "  [실패] rclone 없음 — pkg install rclone"; ok=0; fi

  if have rclone && rclone listremotes 2>/dev/null | grep -qx "$RCLONE_REMOTE:"; then
    echo "  [OK] rclone 리모트 '$RCLONE_REMOTE' 설정됨"
    if rclone_run lsd "$RCLONE_REMOTE:" >/dev/null 2>&1; then
      echo "  [OK] 구글드라이브 접속 성공"
    else
      echo "  [실패] 구글드라이브 접속 불가 — 토큰 만료 여부 확인 (rclone config reconnect $RCLONE_REMOTE:)"; ok=0
    fi
  else
    echo "  [실패] rclone 리모트 '$RCLONE_REMOTE' 없음 — references/android-setup.md 참고"; ok=0
  fi

  if [ ! -d "$HOME/storage" ] && [ "$fix" = 1 ] && have termux-setup-storage; then
    echo "  [고침] 저장소 접근 설정 — 뜨는 팝업에서 '허용'을 눌러라"
    termux-setup-storage; sleep 3
  fi

  local perm_bad=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    d=$(resolve_dir "$d")
    if [ -d "$d" ]; then
      if [ -w "$d" ]; then echo "  [OK] 감시 폴더 쓰기 가능: $d"
      else echo "  [실패] 쓰기 권한 없음(삭제 불가): $d"; ok=0; perm_bad=1; fi
    else
      echo "  [실패] 폴더 없음: $d — termux-setup-storage 실행했는지 확인"; ok=0
    fi
  done < <(printf '%s\n' $WATCH_DIRS)

  if [ "$perm_bad" = 1 ]; then
    if [ "$fix" = 1 ] && open_settings android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION; then
      echo "         → 폰에 설정 화면을 띄웠다. '모든 파일 관리 허용'을 켜고 돌아와서 다시 실행해라."
    else
      echo "         → 설정 > 앱 > Termux > 권한 > 파일 및 미디어 > '모든 파일 관리 허용'"
    fi
  fi

  for d in $MIGRATE_ROOTS; do
    d=$(resolve_dir "$d")
    [ -d "$d" ] && echo "  [OK] 이관 검사 범위 접근 가능: $d" || { echo "  [실패] 이관 범위 없음: $d"; ok=0; }
  done

  [ -w "$TRASH_DIR" ] && echo "  [OK] 휴지통 쓰기 가능: $TRASH_DIR" || { echo "  [실패] 휴지통 접근 불가: $TRASH_DIR"; ok=0; }
  if [ "$fix" = 1 ] && have pkg; then
    have termux-media-scan || { echo "  [고침] termux-api 설치 중..."; pkg install -y termux-api >/dev/null 2>&1; }
    have inotifywait     || { echo "  [고침] inotify-tools 설치 중..."; pkg install -y inotify-tools >/dev/null 2>&1; }
  fi
  have termux-media-scan && echo "  [OK] termux-api 있음 (갤러리 색인 갱신 가능)" || echo "  [참고] termux-api 없음 — 지운 사진 썸네일이 갤러리에 남을 수 있다 (pkg install termux-api)"
  have inotifywait && echo "  [OK] inotify-tools 있음 (촬영 즉시 반응)" || echo "  [참고] inotify-tools 없음 — ${POLL_SECONDS}초 주기 폴링으로 동작 (pkg install inotify-tools)"

  # 설정된 감시 폴더에 사진이 하나도 없고 다른 곳에 잔뜩 있으면, 경로를 잘못 잡은 것이다.
  local watch_n found_n
  watch_n=$(collect_candidates 2>/dev/null | wc -l | tr -d ' ')
  found_n=$(discover_all 2>/dev/null | wc -l | tr -d ' ')
  if [ "$watch_n" = "0" ] && [ "${found_n:-0}" -gt 0 ]; then
    echo "  [실패] 감시 폴더에는 사진이 0건인데 폰에는 ${found_n}건이 있다 — 경로를 잘못 잡았다"
    echo "         실제 사진 위치:"
    detect_photo_dirs | head -5 | awk '{c=$1; $1=""; sub(/^ /,""); printf "           %6d건  %s\n", c, $0}'
    echo "         → 'photo-autobackup.sh setup' 을 실행하면 자동으로 다시 잡는다"
    ok=0
  fi
  [ "$REQUIRE_WIFI" = "1" ] && { have termux-wifi-connectioninfo && echo "  [OK] Wi-Fi 전용 모드 판정 가능" || { echo "  [실패] REQUIRE_WIFI=1인데 termux-api가 없어 업로드가 계속 보류된다"; ok=0; }; }

  echo
  if [ "$ok" = "1" ]; then
    echo "결과: 바로 쓸 수 있다."
  elif [ "$fix" = 1 ]; then
    echo "결과: 자동으로 고칠 수 있는 건 고쳤다. 위 [실패]가 남았으면 안내대로 하고 다시 실행해라."
  else
    echo "결과: 위 [실패] 항목을 해결해야 한다. 'doctor --fix' 를 쓰면 고칠 수 있는 건 알아서 고친다."
  fi
  return $((1 - ok))
}

# ------------------------------------------------------------------------ 현황
cmd_status() {
  local pending trashed everything
  pending=$(collect_candidates | wc -l | tr -d ' ')
  everything=$(discover_all | wc -l | tr -d ' ')
  trashed=$(find "$TRASH_DIR" -type f ! -name 'manifest.tsv' 2>/dev/null | wc -l | tr -d ' ')
  echo "리모트          : $RCLONE_REMOTE:$DRIVE_FOLDER"
  echo "감시 폴더       : $WATCH_DIRS"
  echo "감시 대기       : ${pending}건"
  echo "폰 전체 사진    : ${everything}건 (검사 범위: $MIGRATE_ROOTS)"
  echo "휴지통          : ${trashed}건 (보관 ${RETENTION_DAYS}일, $(du -sh "$TRASH_DIR" 2>/dev/null | cut -f1))"
  echo "누적 백업       : $(($(wc -l < "$MANIFEST") - 1))건"
  echo "실패 추적       : $(wc -l < "$FAILURES" | tr -d ' ')건"
  echo "최근 로그       :"
  tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
}

usage() {
  cat <<'USAGE'
사용법: photo-autobackup.sh <명령>

  probe            통화녹취 환경 조사 (읽기 전용 — 아무것도 올리거나 지우지 않는다)
  calls            통화녹취를 올린다. 폰에서는 지우지 않는다(복사)
  update           스크립트를 최신본으로 갱신 (긴 URL 붙여넣기 불필요)
  perm             권한만 짧게 점검하고, 필요한 설정 화면을 폰에 띄운다
  setup [사진폴더] [동영상폴더]
                   폰 상태를 읽어 설정을 자동으로 맞추고, 고칠 수 있는 건 고친다.
                   처음 쓸 때와 "안 될 때" 제일 먼저 실행할 명령.
  migrate [--yes]  폰에 있는 사진을 전부 드라이브로 옮기고 폰에서 치운다(1회성).
                   계획을 먼저 보여주고 yes 를 받아야 진행한다. --yes 면 바로 진행.
  verify-empty     폰에 사진이 남아 있는지, 어디에 남았는지 확인한다
  once             감시 폴더를 한 번 훑어서 업로드+검증+휴지통 이동
  watch            계속 감시 (Termux:Boot에서 자동 실행되는 모드)
  doctor [--fix]   설치/권한/접속 상태 진단. --fix 면 고칠 수 있는 건 자동으로 고친다
  status           감시 대기·폰 전체 사진 수·휴지통·누적 현황
  restore <패턴>   휴지통에서 원래 자리로 되돌린다 (all이면 전부)
  purge            보관 기간 지난 휴지통 파일 완전 삭제
  reset-failures   실패 카운터 초기화 후 재시도 허용

설정 파일: ~/.config/photo-autobackup/config.env
USAGE
}

main() {
  load_config
  case "${1:-}" in
    probe)          cmd_probe ;;
    calls)          cmd_calls ;;
    update)         cmd_update ;;
    perm)           cmd_perm ;;
    setup)          shift; cmd_setup "${1:-}" "${2:-}" ;;
    migrate)        shift; cmd_migrate "$@" ;;
    verify-empty)   cmd_verify_empty ;;
    once)           cmd_once ;;
    watch)          cmd_watch ;;
    doctor)         shift; cmd_doctor "${1:-}" ;;
    status)         cmd_status ;;
    restore)        shift; cmd_restore "${1:-}" ;;
    purge)          cmd_purge ;;
    reset-failures) : > "$FAILURES"; log INFO "실패 카운터 초기화" ;;
    -h|--help|help|"") usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
