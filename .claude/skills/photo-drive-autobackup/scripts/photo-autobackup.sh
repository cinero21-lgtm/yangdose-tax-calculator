#!/usr/bin/env bash
# photo-autobackup — 촬영한 사진을 구글드라이브로 올리고, 검증에 성공한 것만 폰에서 치운다.
#
# 안전 원칙: 원본은 "업로드 완료 + 원격 MD5 == 로컬 MD5"가 확인된 뒤에만 로컬 휴지통으로
# 옮긴다. 해시를 확인할 수 없으면 실패로 간주하고 원본을 건드리지 않는다(fail-closed).
# 완전 삭제는 보관 기간이 지난 뒤 purge 단계에서만 일어난다.

set -uo pipefail

VERSION="1.0.0"
CONFIG_FILE="${PHOTO_AUTOBACKUP_CONFIG:-$HOME/.config/photo-autobackup/config.env}"

# ---------------------------------------------------------------- 설정 기본값
RCLONE_REMOTE="gdrive"
DRIVE_FOLDER="PhoneCamera"
WATCH_DIRS="$HOME/storage/dcim/Camera"
EXTENSIONS="jpg jpeg png heic heif dng webp"
STATE_DIR="$HOME/.local/share/photo-autobackup"
MIN_AGE_SECONDS=20
POLL_SECONDS=60
RETENTION_DAYS=30
MAX_ATTEMPTS=5
DRY_RUN=0
RCLONE_EXTRA_ARGS=""

load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
  fi
  TRASH_DIR="${TRASH_DIR:-$STATE_DIR/trash}"
  LOG_FILE="${LOG_FILE:-$STATE_DIR/autobackup.log}"
  MANIFEST="$TRASH_DIR/manifest.tsv"
  FAILURES="$STATE_DIR/failures.tsv"
  mkdir -p "$STATE_DIR" "$TRASH_DIR" "$(dirname "$LOG_FILE")"
  [ -f "$MANIFEST" ] || printf 'moved_at\toriginal_path\ttrash_path\tremote_path\tmd5\n' > "$MANIFEST"
  [ -f "$FAILURES" ] || : > "$FAILURES"
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

# 갤러리(MediaStore) 색인에서 사라지게 한다. termux-api가 없으면 조용히 넘어간다.
media_scan() {
  have termux-media-scan && termux-media-scan -f "$1" >/dev/null 2>&1
  return 0
}

md5_of() { md5sum "$1" 2>/dev/null | cut -d' ' -f1; }

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

# 촬영 날짜 기준 폴더로 정리한다: PhoneCamera/2026/2026-08/IMG_0001.jpg
remote_dir_for() {
  local f="$1" ymd
  ymd=$(date -d "@$(stat -c %Y "$f")" '+%Y/%Y-%m' 2>/dev/null) || ymd=$(date '+%Y/%Y-%m')
  printf '%s/%s' "$DRIVE_FOLDER" "$ymd"
}

rclone_run() {
  # shellcheck disable=SC2086
  rclone "$@" $RCLONE_EXTRA_ARGS
}

remote_md5() {
  # rclone hashsum 출력: "<md5>  <name>"
  rclone_run hashsum MD5 "$1" 2>/dev/null | awk 'NF {print $1; exit}'
}

# --------------------------------------------------------------- 파일 한 건 처리
# 성공(휴지통으로 이동) 시 0, 그 외 1.
process_file() {
  local src="$1"
  local base rdir rpath lmd5 rmd5 target

  base=$(basename "$src")
  lmd5=$(md5_of "$src")
  [ -n "$lmd5" ] || { log WARN "해시 계산 실패, 건너뜀: $src"; return 1; }

  rdir=$(remote_dir_for "$src")
  rpath="$RCLONE_REMOTE:$rdir/$base"

  # 같은 이름이 이미 있으면: 내용이 같으면 업로드 생략, 다르면 이름을 구분해 준다.
  rmd5=$(remote_md5 "$rpath")
  if [ -n "$rmd5" ] && [ "$rmd5" != "$lmd5" ]; then
    local stem ext
    stem="${base%.*}"; ext="${base##*.}"
    if [ "$stem" = "$base" ]; then
      base="${base}-${lmd5:0:8}"
    else
      base="${stem}-${lmd5:0:8}.${ext}"
    fi
    rpath="$RCLONE_REMOTE:$rdir/$base"
    rmd5=$(remote_md5 "$rpath")
    log INFO "원격에 동명이인 파일이 있어 이름을 바꿔 올린다: $base"
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log INFO "[DRY-RUN] 업로드 예정: $src -> $rpath (휴지통 이동은 하지 않음)"
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

  # 여기가 안전장치의 핵심 — 해시가 비었거나 다르면 절대 로컬을 건드리지 않는다.
  if [ -z "$rmd5" ]; then
    log WARN "원격 해시를 읽지 못해 삭제를 보류한다: $base"
    return 1
  fi
  if [ "$rmd5" != "$lmd5" ]; then
    log WARN "해시 불일치(local=$lmd5 remote=$rmd5), 삭제 보류: $base"
    return 1
  fi

  target="$TRASH_DIR/$(date '+%Y%m%d-%H%M%S')-$base"
  if ! mv "$src" "$target" 2>/dev/null; then
    log WARN "휴지통 이동 실패(저장소 권한 확인 필요): $src"
    return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$src" "$target" "$rdir/$base" "$lmd5" >> "$MANIFEST"
  media_scan "$src"
  log INFO "업로드+검증 완료, 휴지통으로 이동: $base"
  return 0
}

# ------------------------------------------------------------------ 한 번 훑기
collect_candidates() {
  local d ext args=()
  for ext in $EXTENSIONS; do
    args+=(-iname "*.${ext}" -o)
  done
  unset 'args[${#args[@]}-1]'   # 마지막 -o 제거
  for d in $WATCH_DIRS; do
    [ -d "$d" ] || continue
    find "$d" -type f \( "${args[@]}" \) ! -name '.*' ! -name '*.pending' ! -name '*.trashed*' 2>/dev/null
  done
}

cmd_once() {
  local f n_ok=0 n_skip=0 n_fail=0 attempts
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

# --------------------------------------------------------------------- 감시 모드
cmd_watch() {
  have termux-wake-lock && termux-wake-lock
  trap 'have termux-wake-unlock && termux-wake-unlock; exit 0' INT TERM
  log INFO "감시 시작 (v$VERSION, 주기 ${POLL_SECONDS}s, 대상: $WATCH_DIRS)"
  while :; do
    cmd_once
    if have inotifywait; then
      # 새 파일이 생기면 즉시 깨어나고, 아무 일 없으면 주기마다 한 번 돈다.
      # shellcheck disable=SC2086
      inotifywait -q -e close_write,moved_to -t "$POLL_SECONDS" $WATCH_DIRS >/dev/null 2>&1
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

# ------------------------------------------------------------------------ 진단
cmd_doctor() {
  local ok=1 d
  echo "photo-autobackup doctor (v$VERSION)"
  echo "설정 파일: $CONFIG_FILE $([ -f "$CONFIG_FILE" ] && echo '(있음)' || echo '(없음 — 기본값 사용)')"

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

  for d in $WATCH_DIRS; do
    if [ -d "$d" ]; then
      if [ -w "$d" ]; then echo "  [OK] 감시 폴더 쓰기 가능: $d"
      else echo "  [실패] 쓰기 권한 없음(삭제 불가): $d — 앱 정보에서 '모든 파일 접근 허용'"; ok=0; fi
    else
      echo "  [실패] 폴더 없음: $d — termux-setup-storage 실행했는지 확인"; ok=0
    fi
  done

  [ -w "$TRASH_DIR" ] && echo "  [OK] 휴지통 쓰기 가능: $TRASH_DIR" || { echo "  [실패] 휴지통 접근 불가: $TRASH_DIR"; ok=0; }
  have termux-media-scan && echo "  [OK] termux-api 있음 (갤러리 색인 갱신 가능)" || echo "  [참고] termux-api 없음 — 지운 사진 썸네일이 갤러리에 남을 수 있다 (pkg install termux-api)"
  have inotifywait && echo "  [OK] inotify-tools 있음 (촬영 즉시 반응)" || echo "  [참고] inotify-tools 없음 — ${POLL_SECONDS}초 주기 폴링으로 동작 (pkg install inotify-tools)"

  echo
  [ "$ok" = "1" ] && echo "결과: 바로 쓸 수 있다." || echo "결과: 위 [실패] 항목을 먼저 해결해야 한다."
  return $((1 - ok))
}

# ------------------------------------------------------------------------ 현황
cmd_status() {
  local pending trashed
  pending=$(collect_candidates | wc -l | tr -d ' ')
  trashed=$(find "$TRASH_DIR" -type f ! -name 'manifest.tsv' 2>/dev/null | wc -l | tr -d ' ')
  echo "리모트        : $RCLONE_REMOTE:$DRIVE_FOLDER"
  echo "감시 폴더     : $WATCH_DIRS"
  echo "대기 중       : ${pending}건"
  echo "휴지통        : ${trashed}건 (보관 ${RETENTION_DAYS}일, $(du -sh "$TRASH_DIR" 2>/dev/null | cut -f1))"
  echo "누적 백업     : $(($(wc -l < "$MANIFEST") - 1))건"
  echo "실패 추적     : $(wc -l < "$FAILURES" | tr -d ' ')건"
  echo "최근 로그     :"
  tail -n 10 "$LOG_FILE" 2>/dev/null | sed 's/^/  /'
}

usage() {
  cat <<'USAGE'
사용법: photo-autobackup.sh <명령>

  once            한 번 훑어서 업로드+검증+휴지통 이동
  watch           계속 감시 (Termux:Boot에서 자동 실행되는 모드)
  doctor          설치/권한/접속 상태 진단
  status          대기·휴지통·누적 현황
  restore <패턴>  휴지통에서 원래 자리로 되돌린다 (all이면 전부)
  purge           보관 기간 지난 휴지통 파일 완전 삭제
  reset-failures  실패 카운터 초기화 후 재시도 허용

설정 파일: ~/.config/photo-autobackup/config.env
USAGE
}

main() {
  load_config
  case "${1:-}" in
    once)           cmd_once ;;
    watch)          cmd_watch ;;
    doctor)         cmd_doctor ;;
    status)         cmd_status ;;
    restore)        shift; cmd_restore "${1:-}" ;;
    purge)          cmd_purge ;;
    reset-failures) : > "$FAILURES"; log INFO "실패 카운터 초기화" ;;
    -h|--help|help|"") usage ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
