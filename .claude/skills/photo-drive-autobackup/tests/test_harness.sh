#!/usr/bin/env bash
# photo-autobackup 로직 검증용 하네스 (rclone/termux 없이 동작)
set -uo pipefail
SKILL="$(cd "$(dirname "$0")/.." && pwd)"
ROOT=$(mktemp -d)
export HOME="$ROOT/home"
mkdir -p "$HOME/storage/dcim/Camera" "$HOME/storage/shared" "$ROOT/bin" "$ROOT/remote"

# ---- rclone 스텁: $ROOT/remote 를 구글드라이브라고 친다
cat > "$ROOT/bin/rclone" <<'RC'
#!/usr/bin/env bash
REMOTE_ROOT="$RCLONE_FAKE_ROOT"
cmd="$1"; shift
strip() { printf '%s' "${1#gdrive:}"; }
case "$cmd" in
  version) echo "rclone v1.0-fake" ;;
  listremotes) echo "gdrive:" ;;
  lsd) exit 0 ;;
  hashsum)
    shift # MD5
    p="$REMOTE_ROOT/$(strip "$1")"
    [ -f "$p" ] || exit 1
    echo "$(md5sum "$p" | cut -d' ' -f1)  $(basename "$p")"
    ;;
  copyto)
    [ "${RCLONE_FAKE_FAIL:-0}" = "1" ] && exit 1
    dst="$REMOTE_ROOT/$(strip "$2")"
    mkdir -p "$(dirname "$dst")"
    cp "$1" "$dst"
    [ "${RCLONE_FAKE_CORRUPT:-0}" = "1" ] && printf 'x' >> "$dst"
    exit 0
    ;;
  *) exit 0 ;;
esac
RC
chmod +x "$ROOT/bin/rclone"
export PATH="$ROOT/bin:$PATH"
export RCLONE_FAKE_ROOT="$ROOT/remote"

mkdir -p "$HOME/.config/photo-autobackup"
cat > "$HOME/.config/photo-autobackup/config.env" <<CFG
RCLONE_REMOTE="gdrive"
DRIVE_FOLDER="PhoneCamera"
WATCH_DIRS="$HOME/storage/dcim/Camera"
MIN_AGE_SECONDS=0
RETENTION_DAYS=30
CFG
export PHOTO_AUTOBACKUP_CONFIG="$HOME/.config/photo-autobackup/config.env"

CAM="$HOME/storage/dcim/Camera"
TRASH="$HOME/.local/share/photo-autobackup/trash"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  PASS $1"; pass=$((pass+1)); else echo "  FAIL $1 (기대=$2 실제=$3)"; fail=$((fail+1)); fi; }

echo "== 1. 정상 경로: 업로드 → 검증 → 휴지통 =="
echo "photo-data-1" > "$CAM/IMG_0001.jpg"
"$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "원본이 카메라 폴더에서 사라짐" 0 "$(ls "$CAM" | wc -l)"
check "휴지통에 1건"                  1 "$(find "$TRASH" -name '*IMG_0001.jpg' | wc -l)"
check "드라이브에 업로드됨"            1 "$(find "$ROOT/remote" -name 'IMG_0001.jpg' | wc -l)"
check "날짜 폴더 구조"                 1 "$(find "$ROOT/remote/PhoneCamera/$(date +%Y)/$(date +%Y-%m)" -name 'IMG_0001.jpg' 2>/dev/null | wc -l)"
check "manifest 기록됨"                1 "$(grep -c 'IMG_0001.jpg' "$TRASH/manifest.tsv")"

echo "== 2. 업로드 실패 시 원본 보존 =="
echo "photo-data-2" > "$CAM/IMG_0002.jpg"
RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "원본 그대로 남음"               1 "$(ls "$CAM" | wc -l)"
check "휴지통에 안 들어감"             0 "$(find "$TRASH" -name '*IMG_0002.jpg' | wc -l)"

echo "== 3. 전송 중 손상(해시 불일치) 시 삭제 보류 =="
rm -f "$CAM/IMG_0002.jpg"; "$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "photo-data-3" > "$CAM/IMG_0003.jpg"
RCLONE_FAKE_CORRUPT=1 "$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "원본 보존됨"                    1 "$(ls "$CAM" | wc -l)"

echo "== 4. 동명이인 파일은 이름을 바꿔 올린다 =="
rm -f "$CAM/IMG_0003.jpg"
echo "완전히-다른-내용" > "$CAM/IMG_0001.jpg"
"$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "원격 IMG_0001* 2개"             2 "$(find "$ROOT/remote" -name 'IMG_0001*' | wc -l)"
check "기존 원격 파일 안 덮어씀"        "photo-data-1" "$(cat "$ROOT/remote/PhoneCamera/$(date +%Y)/$(date +%Y-%m)/IMG_0001.jpg")"

echo "== 5. DRY_RUN 은 아무것도 지우지 않는다 =="
echo "photo-data-5" > "$CAM/IMG_0005.jpg"
DRY_RUN=1 sh -c "echo 'DRY_RUN=1' >> \"$HOME/.config/photo-autobackup/config.env\""
"$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "DRY_RUN에서 원본 유지"          1 "$(ls "$CAM" | wc -l)"
sed -i '/^DRY_RUN=1$/d' "$HOME/.config/photo-autobackup/config.env"
rm -f "$CAM/IMG_0005.jpg"

echo "== 6. 이미 올라간 파일 재검증(중복 업로드 없이 정리) =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "photo-data-1" > "$CAM/IMG_0001.jpg"   # 원격과 동일 내용
"$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "중복 없이 휴지통 이동"           0 "$(ls "$CAM" | wc -l)"

echo "== 7. 복구 =="
"$SKILL/scripts/photo-autobackup.sh" restore IMG_0001.jpg >/dev/null 2>&1
check "카메라 폴더로 되돌아옴"          1 "$(ls "$CAM" | grep -c IMG_0001.jpg)"

echo "== 8. 실패 5회 후 재시도 중단 =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CAM"/*; echo "bad" > "$CAM/IMG_0009.jpg"
for i in 1 2 3 4 5; do RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1; done
check "실패 카운터 5 도달"              "IMG_0009.jpg	5" "$(sed "s|$CAM/||" "$HOME/.local/share/photo-autobackup/failures.tsv" | head -n1)"
out=$("$SKILL/scripts/photo-autobackup.sh" once 2>&1)
check "6회차에는 보류로 건너뜀"         1 "$(echo "$out" | grep -c '보류 1건')"

echo "== 9. doctor / status 실행 가능 =="
"$SKILL/scripts/photo-autobackup.sh" doctor >/dev/null 2>&1; check "doctor 종료코드 0" 0 "$?"
"$SKILL/scripts/photo-autobackup.sh" status >/dev/null 2>&1; check "status 종료코드 0" 0 "$?"

echo "== 10. 일괄 이관(migrate): 폰 전체 사진을 폴더 구조 그대로 옮긴다 =="
SHARED="$HOME/storage/shared"
mkdir -p "$SHARED/DCIM/Camera" "$SHARED/Pictures/Screenshots" "$SHARED/Pictures/카카오톡 받은 사진" \
         "$SHARED/Android/data/com.foo/files" "$SHARED/DCIM/.thumbnails"
rm -f "$CAM"/*
echo "cam-a"    > "$SHARED/DCIM/Camera/A.jpg"
echo "shot-b"   > "$SHARED/Pictures/Screenshots/B.png"
echo "kakao-c"  > "$SHARED/Pictures/카카오톡 받은 사진/C.jpg"
echo "appcache" > "$SHARED/Android/data/com.foo/files/D.jpg"
echo "thumb"    > "$SHARED/DCIM/.thumbnails/E.jpg"
cat >> "$HOME/.config/photo-autobackup/config.env" <<CFG
DRIVE_FOLDER="Z폴드 8 사진"
MIGRATE_ROOTS="$SHARED"
CFG
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
R="$ROOT/remote/Z폴드 8 사진"
check "카메라 사진 이동됨"          0 "$(ls "$SHARED/DCIM/Camera" | wc -l)"
check "스크린샷 이동됨"             0 "$(ls "$SHARED/Pictures/Screenshots" | wc -l)"
check "공백 포함 폴더도 이동됨"     0 "$(ls "$SHARED/Pictures/카카오톡 받은 사진" | wc -l)"
check "드라이브 폴더 구조 재현(DCIM/Camera)"      1 "$(ls "$R/DCIM/Camera/A.jpg" 2>/dev/null | wc -l)"
check "드라이브 폴더 구조 재현(Screenshots)"      1 "$(ls "$R/Pictures/Screenshots/B.png" 2>/dev/null | wc -l)"
check "공백 포함 경로 업로드"                     1 "$(ls "$R/Pictures/카카오톡 받은 사진/C.jpg" 2>/dev/null | wc -l)"

echo "== 11. 앱 캐시·썸네일은 건드리지 않는다 =="
check "Android/data 안 사진 보존"   1 "$(ls "$SHARED/Android/data/com.foo/files" | wc -l)"
check "썸네일 폴더 보존"            1 "$(ls "$SHARED/DCIM/.thumbnails" | wc -l)"
check "캐시가 드라이브에 안 올라감" 0 "$(find "$ROOT/remote" -name 'D.jpg' -o -name 'E.jpg' | wc -l)"

echo "== 12. verify-empty: 다 옮겼으면 0건 =="
out=$("$SKILL/scripts/photo-autobackup.sh" verify-empty 2>&1)
check "남은 사진 없음 보고"         1 "$(echo "$out" | grep -c '남은 사진이 없다')"
"$SKILL/scripts/photo-autobackup.sh" verify-empty >/dev/null 2>&1; check "verify-empty 종료코드 0" 0 "$?"

echo "== 13. 업로드 실패분은 폰에 남고 verify-empty가 잡아낸다 =="
echo "will-fail" > "$SHARED/DCIM/Camera/F.jpg"
RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
out=$("$SKILL/scripts/photo-autobackup.sh" verify-empty 2>&1)
check "원본 폰에 남음"              1 "$(ls "$SHARED/DCIM/Camera" | wc -l)"
check "남은 건수 보고"              1 "$(echo "$out" | grep -c '아직 1건')"
"$SKILL/scripts/photo-autobackup.sh" verify-empty >/dev/null 2>&1; check "verify-empty 종료코드 1" 1 "$?"

echo "== 14. migrate 는 확인 없이 지우지 않는다 (yes 미입력 시 중단) =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "no" | "$SKILL/scripts/photo-autobackup.sh" migrate >/dev/null 2>&1
check "거부하면 원본 그대로"        1 "$(ls "$SHARED/DCIM/Camera" | wc -l)"

echo "== 15. 경로를 잘못 잡았을 때 doctor 가 잡아낸다 =="
mkdir -p "$SHARED/DCIM/Camera" "$HOME/empty-watch"
echo "real-photo" > "$SHARED/DCIM/Camera/G.jpg"
cat >> "$HOME/.config/photo-autobackup/config.env" <<CFG
WATCH_DIRS="$HOME/empty-watch"
CFG
out=$("$SKILL/scripts/photo-autobackup.sh" doctor 2>&1)
check "잘못된 경로 진단"        1 "$(echo "$out" | grep -c '경로를 잘못 잡았다')"
check "실제 위치 알려줌"        1 "$(echo "$out" | grep -c 'DCIM/Camera')"
check "setup 안내"              1 "$(echo "$out" | grep -c "setup' 을 실행")"

echo "== 16. setup 이 사진 실제 위치를 찾아 스스로 설정한다 =="
out=$("$SKILL/scripts/photo-autobackup.sh" setup "내 폰 사진" 2>&1)
cfg="$HOME/.config/photo-autobackup/config.env"
check "감시 폴더를 실제 위치로 교정" 1 "$(grep -c "^WATCH_DIRS=\"$SHARED/DCIM/Camera\"$" "$cfg")"
check "드라이브 폴더 인자 반영"      1 "$(grep -c '^DRIVE_FOLDER="내 폰 사진"$' "$cfg")"
check "이관 범위 자동 기록"          1 "$(grep -c "^MIGRATE_ROOTS=.*$SHARED" "$cfg")"
check "기존 설정 백업됨"             1 "$(ls "$HOME/.config/photo-autobackup/" | grep -c 'config.env.bak')"
check "다음 단계 안내"               1 "$(echo "$out" | grep -c '다음: photo-autobackup.sh migrate')"

echo "== 17. setup 직후 실제로 동작한다 (교정된 경로로 업로드) =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "교정된 폴더에서 사진 처리됨"  0 "$(ls "$SHARED/DCIM/Camera" | wc -l)"
check "드라이브에 올라감"            1 "$(find "$ROOT/remote/내 폰 사진" -name 'G.jpg' 2>/dev/null | wc -l)"

echo "== 18. perm: 권한 3종을 갈라서 판정한다 =="
out=$("$SKILL/scripts/photo-autobackup.sh" perm 2>&1)
check "저장소 연결 OK"      1 "$(echo "$out" | grep -c '1. 저장소 연결      : OK')"
check "삭제 권한 실측 판정"  1 "$(echo "$out" | grep -c '3. 삭제 권한        : OK')"
check "권한 테스트 파일 정리" 0 "$(find "$SHARED" -name '.pab-permtest' 2>/dev/null | wc -l)"

echo "== 19. perm: 삭제 권한이 없으면 삼성 경로를 알려준다 =="
# root 로 도는 테스트라 chmod 로는 쓰기를 막을 수 없다. DCIM 을 파일로 바꿔
# "쓸 수 없는 경로"를 만든다 — 실기기의 EACCES 와 같은 분기를 탄다.
mv "$SHARED/DCIM" "$SHARED/DCIM.bak"
: > "$SHARED/DCIM"
out=$("$SKILL/scripts/photo-autobackup.sh" perm 2>&1)
check "삭제 권한 없음 판정"  1 "$(echo "$out" | grep -c '3. 삭제 권한        : 없음')"
check "삼성 메뉴 경로 안내"  1 "$(echo "$out" | grep -c '특별한 접근 권한')"
"$SKILL/scripts/photo-autobackup.sh" perm >/dev/null 2>&1; check "perm 종료코드 1" 1 "$?"
rm -f "$SHARED/DCIM"; mv "$SHARED/DCIM.bak" "$SHARED/DCIM"

echo "== 20. 동영상은 별도 폴더로 간다 =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
# 앞선 setup 테스트가 config 를 새로 쓰므로 여기서 쓸 폴더명을 다시 고정한다.
cat >> "$HOME/.config/photo-autobackup/config.env" <<CFG
DRIVE_FOLDER="Z폴드 8 사진"
VIDEO_DRIVE_FOLDER="Z폴드 8 동영상"
CFG
mkdir -p "$SHARED/DCIM/Camera"
echo "photo-x" > "$SHARED/DCIM/Camera/P1.jpg"
echo "video-y" > "$SHARED/DCIM/Camera/V1.mp4"
echo "video-z" > "$SHARED/DCIM/Camera/V2.MOV"     # 대문자 확장자도 동영상이다
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "사진은 사진 폴더로"        1 "$(ls "$ROOT/remote/Z폴드 8 사진/DCIM/Camera/P1.jpg" 2>/dev/null | wc -l)"
check "동영상은 동영상 폴더로"    1 "$(ls "$ROOT/remote/Z폴드 8 동영상/DCIM/Camera/V1.mp4" 2>/dev/null | wc -l)"
check "대문자 .MOV 도 동영상"     1 "$(ls "$ROOT/remote/Z폴드 8 동영상/DCIM/Camera/V2.MOV" 2>/dev/null | wc -l)"
check "동영상이 사진 폴더에 없음" 0 "$(find "$ROOT/remote/Z폴드 8 사진" -iname '*.mp4' -o -iname '*.mov' 2>/dev/null | wc -l)"
check "폰에서 셋 다 사라짐"       0 "$(ls "$SHARED/DCIM/Camera" | wc -l)"

echo "== 21. 계획 화면이 사진/동영상을 나눠 보여준다 =="
echo "photo-a" > "$SHARED/DCIM/Camera/P9.jpg"
echo "video-b" > "$SHARED/DCIM/Camera/V9.mp4"
out=$(echo "no" | "$SKILL/scripts/photo-autobackup.sh" migrate 2>&1)
check "사진/동영상 건수 표시"     1 "$(echo "$out" | grep -c '사진 1 / 동영상 1')"
check "동영상 목적지 표시"        1 "$(echo "$out" | grep -c '동영상 →.*Z폴드 8 동영상')"
rm -f "$SHARED/DCIM/Camera"/*

echo "== 22. VIDEO_EXTENSIONS 를 비우면 동영상을 아예 건드리지 않는다 =="
sed -i 's|^VIDEO_EXTENSIONS=.*|VIDEO_EXTENSIONS=""|' "$HOME/.config/photo-autobackup/config.env" 2>/dev/null
echo 'VIDEO_EXTENSIONS=""' >> "$HOME/.config/photo-autobackup/config.env"
echo "vid" > "$SHARED/DCIM/Camera/V3.mp4"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "동영상 폰에 그대로"        1 "$(ls "$SHARED/DCIM/Camera" | wc -l)"
sed -i '/^VIDEO_EXTENSIONS=""$/d' "$HOME/.config/photo-autobackup/config.env"
rm -f "$SHARED/DCIM/Camera"/*

echo "== 23. 이관이 끝나면 알림을 띄운다 =="
cat > "$ROOT/bin/termux-notification" <<'TN'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RCLONE_FAKE_ROOT/../notify.log"
TN
chmod +x "$ROOT/bin/termux-notification"
: > "$ROOT/notify.log"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "done-a" > "$SHARED/DCIM/Camera/N1.jpg"
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "완료 알림 발송"        1 "$(grep -c '이관 완료' "$ROOT/notify.log")"
check "건수 포함"             1 "$(grep -c '1건을 옮기고' "$ROOT/notify.log")"

echo "== 24. 남은 게 있으면 '확인 필요' 알림 =="
: > "$ROOT/notify.log"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "will-fail" > "$SHARED/DCIM/Camera/N2.jpg"
RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "확인 필요 알림"        1 "$(grep -c '확인 필요' "$ROOT/notify.log")"
check "남은 건수 포함"        1 "$(grep -c '1건 남음' "$ROOT/notify.log")"
rm -f "$SHARED/DCIM/Camera"/* "$ROOT/bin/termux-notification"

echo "== 25. update: 온전한 파일만 덮어쓴다 =="
cp "$SKILL/scripts/photo-autobackup.sh" "$ROOT/bin/pab-target.sh"
before=$(md5sum "$ROOT/bin/pab-target.sh" | cut -d' ' -f1)

# (a) 깨진 파일을 받으면 덮어쓰지 않아야 한다
printf 'VERSION="9.9.9"\nif [ then oops\n' > "$ROOT/broken.sh"
out=$(UPDATE_URL="file://$ROOT/broken.sh" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/bin/pab-target.sh" update 2>&1)
after=$(md5sum "$ROOT/bin/pab-target.sh" | cut -d' ' -f1)
check "깨진 파일은 거부"       "$before" "$after"
check "거부 사유 안내"          1 "$(echo "$out" | grep -c '온전하지 않다')"

# (b) 정상 파일이면 갱신되고 백업이 남는다
sed 's|^VERSION=.*|VERSION="9.9.9"|' "$SKILL/scripts/photo-autobackup.sh" > "$ROOT/good.sh"
out=$(UPDATE_URL="file://$ROOT/good.sh" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/bin/pab-target.sh" update 2>&1)
check "정상 파일은 갱신"        1 "$(grep -c '^VERSION="9.9.9"' "$ROOT/bin/pab-target.sh")"
check "이전본 백업 생성"        1 "$(ls "$ROOT/bin/pab-target.sh.bak" 2>/dev/null | wc -l)"
check "완료 메시지"             1 "$(echo "$out" | grep -c '업데이트 완료')"
rm -f "$ROOT/bin/pab-target.sh"*

echo
echo "합계: PASS=$pass FAIL=$fail"
rm -rf "$ROOT"
[ "$fail" = "0" ]
