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
    # 통신 오류로 해시만 못 읽는 상황. 파일 존재 여부와는 다른 사건이다.
    [ "${RCLONE_HASH_BLIND:-0}" = "1" ] && exit 1
    p="$REMOTE_ROOT/$(strip "$1")"
    [ -f "$p" ] || exit 1
    echo "$(md5sum "$p" | cut -d' ' -f1)  $(basename "$p")"
    ;;
  lsf)
    p="$REMOTE_ROOT/$(strip "$1")"
    [ -f "$p" ] || exit 1
    basename "$p"
    ;;
  deletefile)
    p="$REMOTE_ROOT/$(strip "$1")"
    [ -f "$p" ] || exit 1
    rm -f "$p"
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
# 유예는 기본 시험에서 끈다. 시험 파일은 방금 만든 것이라 유예가 켜져 있으면
# 전부 걸러져, 정작 보려는 업로드·삭제 동작이 하나도 안 돈다. 유예 자체는
# 94번 시험에서 따로 켜서 확인한다.
HOLD_DAYS=0
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

echo "== 26. setup 이 사진·동영상 폴더를 모두 보여준다 =="
out=$("$SKILL/scripts/photo-autobackup.sh" setup "테스트 사진" "테스트 동영상" 2>&1)
check "사진 폴더 표시"        1 "$(echo "$out" | grep -c '사진 폴더     : 테스트 사진')"
check "동영상 폴더 표시"      1 "$(echo "$out" | grep -c '동영상 폴더   : 테스트 동영상')"
check "설정 파일에 기록"      1 "$(grep -c '^VIDEO_DRIVE_FOLDER="테스트 동영상"' "$HOME/.config/photo-autobackup/config.env")"

echo "== 27. update 가 같은 버전일 때 그렇다고 말한다 =="
cp "$SKILL/scripts/photo-autobackup.sh" "$ROOT/bin/pab-v.sh"
out=$(UPDATE_URL="file://$SKILL/scripts/photo-autobackup.sh" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/bin/pab-v.sh" update 2>&1)
check "같은 버전이면 '이미 최신'" 1 "$(echo "$out" | grep -c '이미 최신')"
sed 's|^VERSION=.*|VERSION="99.0.0"|' "$SKILL/scripts/photo-autobackup.sh" > "$ROOT/newer.sh"
out=$(UPDATE_URL="file://$ROOT/newer.sh" PATH="$ROOT/bin:$PATH" \
      bash "$ROOT/bin/pab-v.sh" update 2>&1)
check "다른 버전이면 화살표 표기" 1 "$(echo "$out" | grep -c '\-> v99.0.0')"
rm -f "$ROOT/bin/pab-v.sh"*

# ======================= 통화녹취 =======================
CALLDIR="$SHARED/Recordings/Call"
mkdir -p "$CALLDIR"
cat >> "$HOME/.config/photo-autobackup/config.env" <<CFG
CALL_DRIVE_IN="수신녹취"
CALL_DRIVE_OUT="발신통화녹취"
CALL_DRIVE_UNKNOWN="통화녹취_미분류"
CFG
YM="$(date +%Y)/$(date +%Y-%m)"

echo "== 28. CALL_ENABLED=0 이면 아무것도 하지 않는다 =="
echo "audio" > "$CALLDIR/수신 홍길동 260819.m4a"
out=$("$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
check "꺼져 있다고 안내"        1 "$(echo "$out" | grep -c 'CALL_ENABLED=1')"
check "업로드 안 함"            0 "$(find "$ROOT/remote" -name '*.m4a' 2>/dev/null | wc -l)"
echo 'CALL_ENABLED=1' >> "$HOME/.config/photo-autobackup/config.env"

echo "== 29. 파일명으로 수신/발신을 가른다 =="
echo "out-audio" > "$CALLDIR/발신 김철수 260819.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "수신은 수신녹취로"        1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 홍길동 260819.m4a" 2>/dev/null | wc -l)"
check "발신은 발신통화녹취로"    1 "$(ls "$ROOT/remote/발신통화녹취/$YM/발신 김철수 260819.m4a" 2>/dev/null | wc -l)"

echo "== 30. 복사 정책 — 올린 뒤에도 폰에 그대로 남는다 =="
check "녹음 파일 폰에 유지"      2 "$(ls "$CALLDIR"/*.m4a 2>/dev/null | wc -l)"

echo "== 31. 장부 덕에 두 번째 스윕은 재업로드하지 않는다 =="
out=$("$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
check "업로드 0건"              1 "$(echo "$out" | grep -c '업로드 0건')"
check "건너뜀으로 집계"          1 "$(echo "$out" | grep -cE '건너뜀 [1-9][0-9]*건')"

echo "== 32. 내용이 바뀌면 다시 올린다 =="
echo "audio-changed" > "$CALLDIR/수신 홍길동 260819.m4a"
out=$("$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
check "변경분 재업로드"          1 "$(echo "$out" | grep -c '업로드 1건')"

echo "== 33. 전사 파일이 녹음과 같은 폴더로 함께 간다 =="
echo "전사 본문입니다" > "$CALLDIR/수신 홍길동 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "전사가 수신녹취로"        1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 홍길동 260819.txt" 2>/dev/null | wc -l)"
check "전사도 폰에 유지"         1 "$(ls "$CALLDIR"/*.txt 2>/dev/null | wc -l)"

echo "== 34. 판정 불가면 추측하지 않고 미분류로 =="
echo "mystery" > "$CALLDIR/20260819_150000.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "미분류 폴더로"            1 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/20260819_150000.m4a" 2>/dev/null | wc -l)"
check "수신녹취에 안 섞임"       0 "$(ls "$ROOT/remote/수신녹취/$YM/20260819_150000.m4a" 2>/dev/null | wc -l)"

echo "== 35. 통화기록으로 판정한다 (파일명에 단서가 없을 때) =="
cat > "$ROOT/bin/termux-call-log" <<'TCL'
#!/usr/bin/env bash
now=$(stat -c %Y "$CALL_LOG_TARGET" 2>/dev/null || date +%s)
printf '[\n  {\n    "type": "OUTGOING",\n    "date": "%s"\n  }\n]\n' "$(date -d "@$now" '+%Y-%m-%d %H:%M:%S')"
TCL
chmod +x "$ROOT/bin/termux-call-log"
echo "via-calllog" > "$CALLDIR/20260819_160000.m4a"
export CALL_LOG_TARGET="$CALLDIR/20260819_160000.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "통화기록 보고 발신 판정"  1 "$(ls "$ROOT/remote/발신통화녹취/$YM/20260819_160000.m4a" 2>/dev/null | wc -l)"
rm -f "$ROOT/bin/termux-call-log"; unset CALL_LOG_TARGET

echo "== 36. 짝 없는 전사도 버리지 않는다 =="
echo "고아 전사" > "$CALLDIR/orphan-note.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "미분류로 보존"            1 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/orphan-note.txt" 2>/dev/null | wc -l)"

echo "== 37. 업로드 실패는 장부에 적지 않는다 =="
LED="$HOME/.local/share/photo-autobackup/uploaded.tsv"
echo "will-fail" > "$CALLDIR/수신 실패테스트 260819.m4a"
RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "장부에 없음"              0 "$(grep -c '실패테스트' "$LED")"
check "원본은 폰에 그대로"       1 "$(ls "$CALLDIR/수신 실패테스트 260819.m4a" 2>/dev/null | wc -l)"

echo "== 38. copy_file 은 원본을 절대 건드리지 않는다 (코드 수준 확인) =="
# 장부 임시파일을 교체하는 mv 는 정상이다. 봐야 할 것은 "\$src 를 옮기거나 지우는가".
body=$(sed -n '/^copy_file()/,/^}/p' "$SKILL/scripts/photo-autobackup.sh")
check "원본을 mv 하지 않음"      0 "$(echo "$body" | grep -cE '(mv|rm)[^|]*\$src')"
check "휴지통을 쓰지 않음"       0 "$(echo "$body" | grep -c 'TRASH_DIR')"
check "media_scan 호출 없음"     0 "$(echo "$body" | grep -c 'media_scan')"
# 실동작으로도 확인 — 업로드 성공 후 원본이 그대로인지는 30번에서 이미 봤다

echo "== 39. probe 는 읽기 전용이다 =="
snap_local=$(find "$CALLDIR" -type f | sort | md5sum)
snap_remote=$(find "$ROOT/remote" -type f | sort | md5sum)
out=$("$SKILL/scripts/photo-autobackup.sh" probe 2>&1)
check "폰 파일 변화 없음"        "$snap_local" "$(find "$CALLDIR" -type f | sort | md5sum)"
check "드라이브 변화 없음"       "$snap_remote" "$(find "$ROOT/remote" -type f | sort | md5sum)"
check "녹음 폴더 보고"           1 "$(echo "$out" | grep -qc '녹음 폴더' && echo 1 || echo 0)"
check "전사 파일 절 출력"        1 "$(echo "$out" | grep -c '전사(텍스트) 파일')"

# ============ 감수 지적사항 재발 방지 ============
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/* 2>/dev/null

echo "== 40. 이름 한 글자로 방향을 정하지 않는다 =="
echo "a" > "$CALLDIR/김건우 통화 260819.m4a"
echo "b" > "$CALLDIR/건강보험공단 260819.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "김건우는 발신 아님"       0 "$(ls "$ROOT/remote/발신통화녹취/$YM/김건우 통화 260819.m4a" 2>/dev/null | wc -l)"
check "건강보험공단도 발신 아님" 0 "$(ls "$ROOT/remote/발신통화녹취/$YM/건강보험공단 260819.m4a" 2>/dev/null | wc -l)"
check "둘 다 미분류로"           2 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/" 2>/dev/null | grep -cE '김건우|건강보험')"

echo "== 41. 대문자 확장자 녹음의 전사도 같은 폴더로 =="
echo "audio" > "$CALLDIR/수신 대문자 260819.M4A"
echo "전사" > "$CALLDIR/수신 대문자 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "녹음 수신녹취로"          1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 대문자 260819.M4A" 2>/dev/null | wc -l)"
check "전사도 같은 폴더로"       1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 대문자 260819.txt" 2>/dev/null | wc -l)"
check "전사가 미분류로 안 감"    0 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/수신 대문자 260819.txt" 2>/dev/null | wc -l)"

echo "== 42. 사이드카가 둘이면 둘 다 올린다 =="
echo "audio" > "$CALLDIR/수신 둘 260819.m4a"
echo "텍스트" > "$CALLDIR/수신 둘 260819.txt"
echo '{"t":1}' > "$CALLDIR/수신 둘 260819.json"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "txt 업로드"               1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 둘 260819.txt" 2>/dev/null | wc -l)"
check "json 도 업로드"           1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 둘 260819.json" 2>/dev/null | wc -l)"

echo "== 43. 전사가 갱신되면 이름을 유지한 채 덮어쓴다 =="
echo "전사 수정본" > "$CALLDIR/수신 둘 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "해시 접미사 안 붙음"      0 "$(ls "$ROOT/remote/수신녹취/$YM/" 2>/dev/null | grep -c '수신 둘 260819-')"
check "내용이 갱신됨"            "전사 수정본" "$(cat "$ROOT/remote/수신녹취/$YM/수신 둘 260819.txt")"

echo "== 44. 90초 넘는 통화도 통화기록으로 판정한다 =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
cat > "$ROOT/bin/termux-call-log" <<'TCL'
#!/usr/bin/env bash
# 통화 시작은 파일 mtime 보다 10분 앞, 통화 시간 10분 → 종료가 mtime 과 일치
start=$(( $(stat -c %Y "$CALL_LOG_TARGET") - 600 ))
printf '[\n  {\n    "type": "INCOMING",\n    "date": "%s",\n    "duration": "00:10:00"\n  }\n]\n' \
  "$(date -d "@$start" '+%Y-%m-%d %H:%M:%S')"
TCL
chmod +x "$ROOT/bin/termux-call-log"
echo "long-call" > "$CALLDIR/20260819_170000.m4a"
export CALL_LOG_TARGET="$CALLDIR/20260819_170000.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "10분 통화도 수신 판정"    1 "$(ls "$ROOT/remote/수신녹취/$YM/20260819_170000.m4a" 2>/dev/null | wc -l)"
check "미분류로 안 감"           0 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/20260819_170000.m4a" 2>/dev/null | wc -l)"
rm -f "$ROOT/bin/termux-call-log"; unset CALL_LOG_TARGET

echo "== 45. setup 을 다시 돌려도 CALL_ENABLED 가 꺼지지 않는다 =="
check "실행 전 켜짐"             1 "$(grep -c '^CALL_ENABLED=1' "$HOME/.config/photo-autobackup/config.env")"
"$SKILL/scripts/photo-autobackup.sh" setup "Z폴드 8 사진" "Z폴드 8 동영상" >/dev/null 2>&1
check "실행 후에도 켜짐"         1 "$(grep -c '^CALL_ENABLED=1' "$HOME/.config/photo-autobackup/config.env")"
check "폴더 설정도 보존"         1 "$(grep -c '^CALL_DRIVE_IN="수신녹취"' "$HOME/.config/photo-autobackup/config.env")"

echo "== 46. 실패가 쌓이면 재시도를 멈춘다 (데이터 낭비 방지) =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/*
echo "bad" > "$CALLDIR/수신 계속실패 260819.m4a"
for i in 1 2 3 4 5; do RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1; done
out=$(RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
check "6회차는 시도조차 안 함"   1 "$(echo "$out" | grep -c '실패 0건')"
check "건너뜀으로 집계"          1 "$(echo "$out" | grep -cE '건너뜀 [1-9]')"

echo "== 47. 상위/하위 폴더를 이중으로 훑지 않는다 =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/*
echo "dedupe" > "$CALLDIR/수신 중복확인 260819.m4a"
out=$("$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
check "업로드 1건 (2건 아님)"    1 "$(echo "$out" | grep -c '업로드 1건')"

echo "== 48. 공백이 든 CALL_DIRS 경로도 인식한다 =="
SPACED="$SHARED/Call recordings"
mkdir -p "$SPACED"
echo "spaced" > "$SPACED/수신 공백폴더 260819.m4a"
# 설정 파일이 환경변수보다 우선한다(이 스크립트의 기존 규칙). 실제 사용 경로대로
# 설정 파일에 적어서 시험한다.
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg.bak"
printf 'CALL_DIRS="%s"\n' "$SPACED" >> "$HOME/.config/photo-autobackup/config.env"
out=$("$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
check "폴더 못 찾음 오류 없음"   0 "$(echo "$out" | grep -c '녹음 폴더를 찾지 못했다')"
check "공백 경로에서 업로드"     1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 공백폴더 260819.m4a" 2>/dev/null | wc -l)"
cp "$ROOT/cfg.bak" "$HOME/.config/photo-autobackup/config.env"
rm -rf "$SPACED"

# ============ 2차 감수 재발 방지 ============
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/* 2>/dev/null

echo "== 49. 배포용 설정 파일 자체를 검사한다 (하네스 설정이 가리지 못하게) =="
CFG_SHIPPED="$SKILL/scripts/config.example.env"
check "배포 설정에 '건' 없음"    0 "$(grep -c 'CALL_OUT_PATTERN=.*|건|' "$CFG_SHIPPED")"
check "배포 설정 CALL_ENABLED=0" 1 "$(grep -c '^CALL_ENABLED=0' "$CFG_SHIPPED")"
# 스크립트 기본값과 배포 설정의 패턴이 어긋나면 신규 설치만 다르게 동작한다
p_script=$(grep -m1 '^CALL_OUT_PATTERN=' "$SKILL/scripts/photo-autobackup.sh")
p_cfg=$(grep -m1 '^CALL_OUT_PATTERN=' "$CFG_SHIPPED")
check "스크립트와 배포 설정 일치" "$p_script" "$p_cfg"

echo "== 50. 녹음이 건너뛰어져도 전사는 독립적으로 올라간다 =="
echo "audio" > "$CALLDIR/수신 독립 260819.m4a"
echo "전사본문" > "$CALLDIR/수신 독립 260819.txt"
# 녹음만 실패 횟수를 채워 영구 건너뛰기 상태로 만든다
for i in 1 2 3 4 5; do
  printf '%s\t%s\n' "$CALLDIR/수신 독립 260819.m4a" "$i" >> "$HOME/.local/share/photo-autobackup/failures.tsv"
done
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "녹음은 건너뜀"            0 "$(ls "$ROOT/remote/수신녹취/$YM/수신 독립 260819.m4a" 2>/dev/null | wc -l)"
check "전사는 그래도 올라감"     1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 독립 260819.txt" 2>/dev/null | wc -l)"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 51. 전사 실패도 실패 카운터에 잡힌다 =="
rm -f "$CALLDIR"/*
FAILTSV="$HOME/.local/share/photo-autobackup/failures.tsv"
echo "audio" > "$CALLDIR/수신 전사실패 260819.m4a"
echo "전사" > "$CALLDIR/수신 전사실패 260819.txt"
RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "전사가 실패 장부에 기록"  1 "$(grep -c '수신 전사실패 260819.txt' "$FAILTSV")"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 52. 확장자 대소문자가 섞여도 짝을 찾는다 =="
rm -f "$CALLDIR"/*
echo "audio" > "$CALLDIR/수신 섞임 260819.M4a"
echo "전사" > "$CALLDIR/수신 섞임 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check ".M4a 녹음 수신녹취로"     1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 섞임 260819.M4a" 2>/dev/null | wc -l)"
check "전사도 같은 폴더로"       1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 섞임 260819.txt" 2>/dev/null | wc -l)"
check "전사가 미분류로 안 감"    0 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/수신 섞임 260819.txt" 2>/dev/null | wc -l)"

echo "== 53. 통화기록은 스윕당 한 번만 읽는다 =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/*
: > "$ROOT/calllog-hits"
cat > "$ROOT/bin/termux-call-log" <<'TCL'
#!/usr/bin/env bash
echo x >> "$CALLLOG_HITS"
printf '[\n  {\n    "type": "INCOMING",\n    "date": "2020-01-01 00:00:00",\n    "duration": "00:00:10"\n  }\n]\n'
TCL
chmod +x "$ROOT/bin/termux-call-log"
export CALLLOG_HITS="$ROOT/calllog-hits"
for i in 1 2 3 4; do echo "m$i" > "$CALLDIR/무단서_$i.m4a"; done
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "4개 파일에 조회 1회"      1 "$(wc -l < "$ROOT/calllog-hits" | tr -d ' ')"
rm -f "$ROOT/bin/termux-call-log"; unset CALLLOG_HITS

echo "== 54. setup 재실행이 Wi-Fi 전용·대역폭 설정을 지우지 않는다 =="
CFG="$HOME/.config/photo-autobackup/config.env"
sed -i 's/^REQUIRE_WIFI=.*/REQUIRE_WIFI=0/' "$CFG" 2>/dev/null
printf 'RCLONE_EXTRA_ARGS="--bwlimit 2M"\n' >> "$CFG"
"$SKILL/scripts/photo-autobackup.sh" setup "Z폴드 8 사진" "Z폴드 8 동영상" >/dev/null 2>&1
check "대역폭 제한 보존"         1 "$(grep -c 'bwlimit 2M' "$CFG")"
sed -i '/bwlimit 2M/d' "$CFG"

# ============ 3차 감수 재발 방지 ============
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/* 2>/dev/null

echo "== 55. 음성메모 폴더를 통화녹취로 빨아들이지 않는다 =="
mkdir -p "$SHARED/Recordings/Voice"
echo "voice-memo" > "$SHARED/Recordings/Voice/음성 001.m4a"
echo "call" > "$CALLDIR/수신 정상 260819.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "통화 녹음은 올라감"       1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 정상 260819.m4a" 2>/dev/null | wc -l)"
check "음성메모는 안 올라감"     0 "$(find "$ROOT/remote/통화녹취_미분류" -name '음성 001.m4a' 2>/dev/null | wc -l)"
check "음성메모 폰에 그대로"     1 "$(ls "$SHARED/Recordings/Voice/음성 001.m4a" 2>/dev/null | wc -l)"

echo "== 56. 통화 녹음이 사진 이관에 휩쓸리지 않는다 =="
echo "call-3gp" > "$CALLDIR/수신 3gp테스트 260819.3gp"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check ".3gp 녹음 폰에 남음"      1 "$(ls "$CALLDIR/수신 3gp테스트 260819.3gp" 2>/dev/null | wc -l)"
check "동영상 폴더로 안 감"      0 "$(find "$ROOT/remote/Z폴드 8 동영상" -name '*3gp테스트*' 2>/dev/null | wc -l)"
check "휴지통에 없음"            0 "$(find "$HOME/.local/share/photo-autobackup/trash" -name '*3gp테스트*' 2>/dev/null | wc -l)"

echo "== 57. 빈 패턴은 '전부 일치'가 아니라 '판정 안 함'이다 =="
rm -f "$CALLDIR"/*
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg2.bak"
printf 'CALL_IN_PATTERN=""\nCALL_OUT_PATTERN=""\n' >> "$HOME/.config/photo-autobackup/config.env"
echo "x" > "$CALLDIR/발신 명백한 260819.m4a"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "수신으로 오분류 안 됨"    0 "$(ls "$ROOT/remote/수신녹취/$YM/발신 명백한 260819.m4a" 2>/dev/null | wc -l)"
check "미분류로 감"              1 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/발신 명백한 260819.m4a" 2>/dev/null | wc -l)"
cp "$ROOT/cfg2.bak" "$HOME/.config/photo-autobackup/config.env"

echo "== 58. 남의 동명 파일을 덮어쓰지 않는다 =="
rm -f "$CALLDIR"/*
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
mkdir -p "$ROOT/remote/수신녹취/$YM"
echo "남이 올린 전사" > "$ROOT/remote/수신녹취/$YM/수신 충돌 260819.txt"
echo "audio" > "$CALLDIR/수신 충돌 260819.m4a"
echo "내 전사" > "$CALLDIR/수신 충돌 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "기존 파일 보존"           "남이 올린 전사" "$(cat "$ROOT/remote/수신녹취/$YM/수신 충돌 260819.txt")"
check "내 것은 이름 바꿔 올림"   1 "$(ls "$ROOT/remote/수신녹취/$YM/" | grep -c '수신 충돌 260819-')"

echo "== 59. 내가 올린 전사의 갱신은 이름을 유지한 채 덮어쓴다 =="
rm -f "$CALLDIR"/* ; rm -rf "$ROOT/remote/수신녹취"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "audio" > "$CALLDIR/수신 갱신 260819.m4a"
echo "1판" > "$CALLDIR/수신 갱신 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
echo "2판" > "$CALLDIR/수신 갱신 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "이름 그대로"              1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 갱신 260819.txt" 2>/dev/null | wc -l)"
check "해시 접미사 없음"         0 "$(ls "$ROOT/remote/수신녹취/$YM/" | grep -c '수신 갱신 260819-')"
check "내용 갱신됨"              "2판" "$(cat "$ROOT/remote/수신녹취/$YM/수신 갱신 260819.txt")"

echo "== 60. DRY_RUN 예행연습이 파일을 영구 차단하지 않는다 =="
rm -f "$CALLDIR"/*
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "dry" > "$CALLDIR/수신 예행 260819.m4a"
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg3.bak"
echo 'DRY_RUN=1' >> "$HOME/.config/photo-autobackup/config.env"
for i in 1 2 3 4 5 6; do "$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1; done
check "실패 장부 비어 있음"      0 "$(grep -c '수신 예행' "$HOME/.local/share/photo-autobackup/failures.tsv")"
cp "$ROOT/cfg3.bak" "$HOME/.config/photo-autobackup/config.env"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "예행연습 뒤 정상 업로드"  1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 예행 260819.m4a" 2>/dev/null | wc -l)"

echo "== 61. probe 가 CALL_DIRS 지정을 반영한다 =="
SPACED2="$SHARED/내 녹음"
mkdir -p "$SPACED2"; echo "x" > "$SPACED2/수신 지정 260819.m4a"
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg4.bak"
printf 'CALL_DIRS="%s"\n' "$SPACED2" >> "$HOME/.config/photo-autobackup/config.env"
out=$("$SKILL/scripts/photo-autobackup.sh" probe 2>&1)
check "지정 폴더를 사용으로 보고" 1 "$(echo "$out" | grep -c '내 녹음')"
check "'없다' 라고 하지 않음"     0 "$(echo "$out" | grep -c '통화 녹음 설정이 꺼져')"
cp "$ROOT/cfg4.bak" "$HOME/.config/photo-autobackup/config.env"; rm -rf "$SPACED2"

echo "== 62. probe 가 통화기록을 파일마다 부르지 않는다 =="
: > "$ROOT/calllog-hits2"
cat > "$ROOT/bin/termux-call-log" <<'TCL'
#!/usr/bin/env bash
echo x >> "$CALLLOG_HITS2"
printf '[\n  {\n    "type": "INCOMING",\n    "date": "2020-01-01 00:00:00",\n    "duration": "00:00:10"\n  }\n]\n'
TCL
chmod +x "$ROOT/bin/termux-call-log"
export CALLLOG_HITS2="$ROOT/calllog-hits2"
# 상수 몇 회(캐시 적재 + 가용성 확인)는 정상이다. 확인할 성질은 "파일 수에
# 비례하지 않는가" 다 — 비례하면 첫 스윕에서 수백 번 왕복하게 된다.
rm -f "$CALLDIR"/*
for i in 1 2 3; do echo "p$i" > "$CALLDIR/probe단서없음_$i.m4a"; done
"$SKILL/scripts/photo-autobackup.sh" probe >/dev/null 2>&1
hits_3=$(wc -l < "$ROOT/calllog-hits2" | tr -d ' ')
: > "$ROOT/calllog-hits2"
for i in 4 5 6 7 8 9 10 11 12; do echo "p$i" > "$CALLDIR/probe단서없음_$i.m4a"; done
"$SKILL/scripts/photo-autobackup.sh" probe >/dev/null 2>&1
hits_12=$(wc -l < "$ROOT/calllog-hits2" | tr -d ' ')
check "파일이 4배여도 조회 동일" "$hits_3" "$hits_12"
check "조회가 상수(3회 이하)"    1 "$([ "$hits_12" -le 3 ] && echo 1 || echo 0)"
rm -f "$ROOT/bin/termux-call-log"; unset CALLLOG_HITS2
rm -f "$CALLDIR"/*

# ============ 4차 감수 재발 방지 ============
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/* 2>/dev/null

echo "== 63. 배포 설정과 스크립트 기본값이 어긋나면 실패한다 (모든 키) =="
# 지금까지 세 번 연속으로 "스크립트만 고치고 배포 설정은 안 고침" 이 나왔다.
# 키 하나씩 확인하지 말고, 두 파일에 다 있는 키는 전부 같은지 기계적으로 본다.
SCRIPT="$SKILL/scripts/photo-autobackup.sh"
CFG_SHIPPED="$SKILL/scripts/config.example.env"
mismatch=0; mismatch_keys=""
while IFS= read -r key; do
  [ -n "$key" ] || continue
  # 인라인 주석과 앞뒤 공백은 값이 아니다. 그것 때문에 어긋난 것처럼 보이면
  # 진짜 어긋남을 알아보지 못하게 된다.
  v_s=$(grep -m1 "^${key}=" "$SCRIPT"      | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//')
  v_c=$(grep -m1 "^${key}=" "$CFG_SHIPPED" | cut -d= -f2- | sed 's/[[:space:]]*#.*$//' | sed 's/[[:space:]]*$//')
  [ -n "$v_c" ] || continue                 # 배포 설정에 없는 키는 대상 아님
  if [ "$v_s" != "$v_c" ]; then
    mismatch=$((mismatch + 1)); mismatch_keys="$mismatch_keys $key"
  fi
done < <(grep -oE '^[A-Z][A-Z0-9_]+(?==)' "$SCRIPT" 2>/dev/null | sort -u || grep -oE '^[A-Z][A-Z0-9_]+=' "$SCRIPT" | tr -d '=' | sort -u)
[ "$mismatch" = "0" ] || echo "    어긋난 키:$mismatch_keys"
check "배포 설정과 기본값 전 키 일치" 0 "$mismatch"

echo "== 64. Recordings/Call 이 없는 기기에서 음성메모를 빨아들이지 않는다 =="
ALT="$SHARED/AltRec"
mkdir -p "$ALT/Voice"
echo "voice" > "$ALT/Voice/음성메모 001.m4a"
echo "call"  > "$ALT/수신 최상위 260819.m4a"
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg5.bak"
printf 'CALL_DIRS="%s"\n' "$ALT" >> "$HOME/.config/photo-autobackup/config.env"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "최상위 녹음은 올라감"      1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 최상위 260819.m4a" 2>/dev/null | wc -l)"
check "하위 음성메모는 제외"      0 "$(find "$ROOT/remote" -name '음성메모 001.m4a' 2>/dev/null | wc -l)"
cp "$ROOT/cfg5.bak" "$HOME/.config/photo-autobackup/config.env"; rm -rf "$ALT"

echo "== 65. 통화녹취를 끈 상태에서 그 폴더의 사진이 방치되지 않는다 =="
rm -f "$CALLDIR"/*
echo "photo-in-recordings" > "$SHARED/Recordings/Call/사진하나.jpg"
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg6.bak"
sed -i 's/^CALL_ENABLED=1/CALL_ENABLED=0/' "$HOME/.config/photo-autobackup/config.env"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "꺼져 있으면 사진 이관 대상" 0 "$(ls "$SHARED/Recordings/Call/사진하나.jpg" 2>/dev/null | wc -l)"
cp "$ROOT/cfg6.bak" "$HOME/.config/photo-autobackup/config.env"

echo "== 66. 재스윕이 보관함 전체를 다시 해싱하지 않는다 =="
rm -f "$CALLDIR"/*
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
for i in 1 2 3; do echo "keep$i" > "$CALLDIR/수신 보관 $i 260819.m4a"; done
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
LED="$HOME/.local/share/photo-autobackup/uploaded.tsv"
check "장부에 크기·수정시각 기록"  3 "$(awk -F'\t' 'NF>=6 && $5!="" && $6!="" && $1 ~ /수신 보관/' "$LED" | wc -l | tr -d ' ')"
# md5sum 을 세는 껍데기를 끼워 재스윕이 해싱하지 않는지 본다
: > "$ROOT/md5-hits"
cat > "$ROOT/bin/md5sum" <<'MD5'
#!/usr/bin/env bash
echo x >> "$MD5_HITS"
exec /usr/bin/md5sum "$@"
MD5
chmod +x "$ROOT/bin/md5sum"; export MD5_HITS="$ROOT/md5-hits"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "재스윕에서 해싱 0회"        0 "$(wc -l < "$ROOT/md5-hits" | tr -d ' ')"
rm -f "$ROOT/bin/md5sum"; unset MD5_HITS

# ============ 5차 감수 재발 방지 ============
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/* 2>/dev/null
TRASH="$HOME/.local/share/photo-autobackup/trash"

echo "== 67. [치명] 보관 기간은 '버린 날' 기준이다 (찍은 날 아님) =="
mkdir -p "$TRASH"
# 방금 버렸지만 촬영은 1년 전인 사진
NOWSTAMP=$(date '+%Y%m%d-%H%M%S')
echo old > "$TRASH/${NOWSTAMP}-작년사진.jpg"
touch -d '1 year ago' "$TRASH/${NOWSTAMP}-작년사진.jpg"
# 31일 전에 버린 사진(접두사 기준)
OLDSTAMP=$(date -d '31 days ago' '+%Y%m%d-%H%M%S')
echo veryold > "$TRASH/${OLDSTAMP}-오래전버림.jpg"
"$SKILL/scripts/photo-autobackup.sh" purge >/dev/null 2>&1
check "방금 버린 것은 보존"       1 "$(ls "$TRASH/${NOWSTAMP}-작년사진.jpg" 2>/dev/null | wc -l)"
check "31일 전 버린 것은 삭제"    0 "$(ls "$TRASH/${OLDSTAMP}-오래전버림.jpg" 2>/dev/null | wc -l)"

echo "== 68. 접두사를 못 읽는 파일은 지우지 않는다 (모르면 보존) =="
echo mystery > "$TRASH/이름이이상한파일.jpg"
touch -d '2 years ago' "$TRASH/이름이이상한파일.jpg"
"$SKILL/scripts/photo-autobackup.sh" purge >/dev/null 2>&1
check "판단 불가 파일 보존"       1 "$(ls "$TRASH/이름이이상한파일.jpg" 2>/dev/null | wc -l)"
rm -f "$TRASH"/*.jpg

echo "== 69. 통화녹취를 꺼도 녹음 파일은 사진 이관에 휩쓸리지 않는다 =="
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg7.bak"
sed -i 's/^CALL_ENABLED=1/CALL_ENABLED=0/' "$HOME/.config/photo-autobackup/config.env"
echo "rec" > "$CALLDIR/수신 꺼짐테스트 260819.3gp"
echo "pic" > "$CALLDIR/폴더안사진.jpg"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "녹음(.3gp)은 폰에 남음"    1 "$(ls "$CALLDIR/수신 꺼짐테스트 260819.3gp" 2>/dev/null | wc -l)"
check "녹음이 휴지통에 없음"      0 "$(find "$TRASH" -name '*꺼짐테스트*' 2>/dev/null | wc -l)"
check "같은 폴더 사진은 이관됨"   0 "$(ls "$CALLDIR/폴더안사진.jpg" 2>/dev/null | wc -l)"
cp "$ROOT/cfg7.bak" "$HOME/.config/photo-autobackup/config.env"
rm -f "$CALLDIR"/*

echo "== 70. 공백이 든 감시 폴더도 동작한다 =="
SPACEDCAM="$SHARED/DCIM/My Photos"
mkdir -p "$SPACEDCAM"
echo "sp" > "$SPACEDCAM/공백폴더사진.jpg"
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg8.bak"
printf 'WATCH_DIRS="%s"\n' "$SPACEDCAM" >> "$HOME/.config/photo-autobackup/config.env"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "공백 감시폴더에서 처리됨"  0 "$(ls "$SPACEDCAM/공백폴더사진.jpg" 2>/dev/null | wc -l)"
cp "$ROOT/cfg8.bak" "$HOME/.config/photo-autobackup/config.env"; rm -rf "$SPACEDCAM"

echo "== 71. 휴지통 이름이 같은 초에 겹쳐도 한 장도 잃지 않는다 =="
rm -f "$TRASH"/*.jpg
mkdir -p "$SHARED/DCIM/A" "$SHARED/DCIM/B"
echo "첫번째" > "$SHARED/DCIM/A/같은이름.jpg"
echo "두번째" > "$SHARED/DCIM/B/같은이름.jpg"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "휴지통에 두 장 모두 있음"  2 "$(find "$TRASH" -name '*같은이름*' 2>/dev/null | wc -l)"
contents=$(find "$TRASH" -name '*같은이름*' -exec cat {} \; | sort | tr '\n' ',')
check "내용이 서로 다름"          "두번째,첫번째," "$contents"
rm -rf "$SHARED/DCIM/A" "$SHARED/DCIM/B"

echo "== 72. setup 이 LAYOUT 설정을 되돌리지 않는다 =="
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfg9.bak"
sed -i 's/^LAYOUT=.*/LAYOUT="mirror"/' "$HOME/.config/photo-autobackup/config.env"
"$SKILL/scripts/photo-autobackup.sh" setup "Z폴드 8 사진" "Z폴드 8 동영상" >/dev/null 2>&1
check "LAYOUT 보존"               1 "$(grep -c '^LAYOUT="mirror"' "$HOME/.config/photo-autobackup/config.env")"
cp "$ROOT/cfg9.bak" "$HOME/.config/photo-autobackup/config.env"

echo "== 73. 원격 해시를 못 읽으면 덮어쓰지 않는다 (fail-closed) =="
rm -f "$CALLDIR"/*
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
mkdir -p "$ROOT/remote/수신녹취/$YM"
echo "소중한 기존 파일" > "$ROOT/remote/수신녹취/$YM/수신 해시불가 260819.m4a"
echo "새 내용" > "$CALLDIR/수신 해시불가 260819.m4a"
RCLONE_HASH_BLIND=1 "$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "기존 파일 보존됨"          "소중한 기존 파일" "$(cat "$ROOT/remote/수신녹취/$YM/수신 해시불가 260819.m4a")"
rm -f "$CALLDIR"/*

echo "== 74. 미분류 전사가 짝을 만나면 제자리를 찾는다 =="
rm -rf "$ROOT/remote/수신녹취" "$ROOT/remote/통화녹취_미분류"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "전사만 먼저" > "$CALLDIR/수신 나중짝 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "처음엔 미분류로"           1 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/수신 나중짝 260819.txt" 2>/dev/null | wc -l)"
echo "audio" > "$CALLDIR/수신 나중짝 260819.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "짝이 생기면 수신녹취로"    1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 나중짝 260819.txt" 2>/dev/null | wc -l)"
rm -f "$CALLDIR"/*

echo "== 75. 갱신 주소가 브랜치 하나에 매여 있지 않다 =="
check "main 주소 포함"            1 "$(grep -c 'UPDATE_BASE/main/\$UPDATE_PATH' "$SKILL/scripts/photo-autobackup.sh")"

# ============ 6차 감수 재발 방지 ============
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/* 2>/dev/null

echo "== 76. restore 가 원래 자리의 새 파일을 파괴하지 않는다 =="
rm -f "$TRASH"/*.jpg
mkdir -p "$SHARED/DCIM/R"
echo "예전 사진" > "$SHARED/DCIM/R/겹침.jpg"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
# 이관 뒤 같은 자리에 새 사진이 생긴 상황
echo "이관 뒤 찍은 새 사진" > "$SHARED/DCIM/R/겹침.jpg"
"$SKILL/scripts/photo-autobackup.sh" restore 겹침.jpg >/dev/null 2>&1
check "새 파일이 살아 있다"       "이관 뒤 찍은 새 사진" "$(cat "$SHARED/DCIM/R/겹침.jpg")"
check "복구본은 옆에 생김"        1 "$(ls "$SHARED/DCIM/R/" | grep -c '복구본')"
rm -rf "$SHARED/DCIM/R"

echo "== 77. purge 가 파일마다 프로세스를 띄우지 않는다 =="
rm -f "$TRASH"/*.jpg
OLD=$(date -d '40 days ago' '+%Y%m%d-%H%M%S')
NEW=$(date '+%Y%m%d-%H%M%S')
for i in $(seq 1 300); do echo x > "$TRASH/${NEW}-최근_$i.jpg"; done
for i in $(seq 1 50);  do echo y > "$TRASH/${OLD}-오래_$i.jpg"; done
t0=$(date +%s%N)
"$SKILL/scripts/photo-autobackup.sh" purge >/dev/null 2>&1
t1=$(date +%s%N)
elapsed_ms=$(( (t1 - t0) / 1000000 ))
check "오래된 것만 삭제"          50 "$(( 50 - $(ls "$TRASH" | grep -c "^${OLD}-") ))"
check "최근 것 300건 보존"        300 "$(ls "$TRASH" | grep -c "^${NEW}-최근")"
check "350건 처리가 5초 미만"     1 "$([ "$elapsed_ms" -lt 5000 ] && echo 1 || echo 0)"
rm -f "$TRASH"/*.jpg

echo "== 78. 통화녹취를 켜도 그 폴더의 사진은 방치되지 않는다 =="
echo "rec" > "$CALLDIR/수신 켜짐 260819.m4a"
echo "pic" > "$CALLDIR/통화폴더사진.jpg"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "녹음은 폰에 남음(복사)"    1 "$(ls "$CALLDIR/수신 켜짐 260819.m4a" 2>/dev/null | wc -l)"
check "사진은 이관됨"             0 "$(ls "$CALLDIR/통화폴더사진.jpg" 2>/dev/null | wc -l)"
out=$("$SKILL/scripts/photo-autobackup.sh" verify-empty 2>&1)
check "verify-empty 가 거짓말 안 함" 1 "$(echo "$out" | grep -c '남은 사진이 없다')"
rm -f "$CALLDIR"/*

echo "== 79. doctor 가 공백 든 감시폴더를 고장으로 오진하지 않는다 =="
SP="$SHARED/DCIM/My Cam"
mkdir -p "$SP"
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfgA.bak"
printf 'WATCH_DIRS="%s"\n' "$SP" >> "$HOME/.config/photo-autobackup/config.env"
out=$("$SKILL/scripts/photo-autobackup.sh" doctor 2>&1)
check "폴더 없음 오진 안 함"      0 "$(echo "$out" | grep -c '폴더 없음')"
check "쓰기 가능으로 인식"        1 "$(echo "$out" | grep -c '감시 폴더 쓰기 가능')"
cp "$ROOT/cfgA.bak" "$HOME/.config/photo-autobackup/config.env"; rm -rf "$SP"

echo "== 80. fail-closed 시험이 실제로 그 경로를 탄다 (가짜 통과 방지) =="
# 스텁이 상황을 구현하는지부터 확인한다. 구현 안 하면 시험이 통과해도 의미가 없다.
RCLONE_HASH_BLIND=1 rclone hashsum MD5 "gdrive:아무거나" >/dev/null 2>&1
check "스텁이 해시 실패를 흉내냄" 1 "$?"
rm -f "$CALLDIR"/*
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
mkdir -p "$ROOT/remote/수신녹취/$YM"
echo "지키고 싶은 원본" > "$ROOT/remote/수신녹취/$YM/수신 보호 260819.m4a"
echo "새 내용" > "$CALLDIR/수신 보호 260819.m4a"
out=$(RCLONE_HASH_BLIND=1 "$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
check "원격 원본 보존"            "지키고 싶은 원본" "$(cat "$ROOT/remote/수신녹취/$YM/수신 보호 260819.m4a")"
check "보류했다고 기록"           1 "$(echo "$out" | grep -c '덮어쓰지 않고 보류')"
rm -f "$CALLDIR"/*

# ============ 7차 감수 재발 방지 ============
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/* 2>/dev/null

echo "== 81. 자동탐색 밖의 통화 녹음(.3gp)도 동영상으로 오해하지 않는다 =="
ODD="$SHARED/MIUI/sound_recorder/call_rec"
mkdir -p "$ODD"
echo "call-rec" > "$ODD/통화녹음_260819.3gp"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "폰에 그대로 남음"          1 "$(ls "$ODD/통화녹음_260819.3gp" 2>/dev/null | wc -l)"
check "동영상 폴더로 안 감"       0 "$(find "$ROOT/remote" -name '*통화녹음_260819*' 2>/dev/null | wc -l)"
check "휴지통에 없음"             0 "$(find "$TRASH" -name '*통화녹음_260819*' 2>/dev/null | wc -l)"
rm -rf "$SHARED/MIUI"

echo "== 82. 환경변수 DRY_RUN 이 설정 파일을 이긴다 (예행연습이 진짜 실행 방지) =="
grep -q '^DRY_RUN=' "$HOME/.config/photo-autobackup/config.env" || echo 'DRY_RUN=0' >> "$HOME/.config/photo-autobackup/config.env"
sed -i 's/^DRY_RUN=.*/DRY_RUN=0/' "$HOME/.config/photo-autobackup/config.env"
mkdir -p "$SHARED/DCIM/Camera"
echo "rehearse" > "$SHARED/DCIM/Camera/예행_사진.jpg"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
out=$(DRY_RUN=1 "$SKILL/scripts/photo-autobackup.sh" migrate --yes 2>&1)
check "원본이 그대로 있다"        1 "$(ls "$SHARED/DCIM/Camera/예행_사진.jpg" 2>/dev/null | wc -l)"
check "DRY-RUN 표시가 나온다"     1 "$(echo "$out" | grep -c 'DRY-RUN')"
check "설정 파일은 여전히 0"      1 "$(grep -c '^DRY_RUN=0' "$HOME/.config/photo-autobackup/config.env")"
rm -f "$SHARED/DCIM/Camera/예행_사진.jpg"

echo "== 83. migrate 도 재시도 상한을 지킨다 =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "badmig" > "$SHARED/DCIM/Camera/실패반복.jpg"
: > "$ROOT/copyto-hits"
for i in 1 2 3 4 5 6 7 8; do
  RCLONE_FAKE_FAIL=1 COPYTO_HITS="$ROOT/copyto-hits" \
    "$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
done
att=$(awk -F'\t' '$1 ~ /실패반복/ {print $2}' "$HOME/.local/share/photo-autobackup/failures.tsv" | tail -n1)
check "8회 돌려도 상한 5에서 멈춤" 5 "${att:-0}"
rm -f "$SHARED/DCIM/Camera/실패반복.jpg"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 84. 이름이 바뀐 업로드도 장부 지름길을 탄다 =="
rm -f "$CALLDIR"/* ; rm -rf "$ROOT/remote/수신녹취"
mkdir -p "$ROOT/remote/수신녹취/$YM"
echo "남의 파일" > "$ROOT/remote/수신녹취/$YM/수신 이름충돌 260819.m4a"
echo "내 녹음" > "$CALLDIR/수신 이름충돌 260819.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "접미사 붙여 올라감"        1 "$(ls "$ROOT/remote/수신녹취/$YM/" | grep -c '수신 이름충돌 260819-')"
out=$("$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
check "재스윕에서 건너뜀"         1 "$(echo "$out" | grep -c '업로드 0건')"
rm -f "$CALLDIR"/*

echo "== 85. 제자리를 찾은 전사의 옛 사본이 남지 않는다 =="
rm -rf "$ROOT/remote/수신녹취" "$ROOT/remote/통화녹취_미분류"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
echo "전사만" > "$CALLDIR/수신 사본정리 260819.txt"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "먼저 미분류에 올라감"      1 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/수신 사본정리 260819.txt" 2>/dev/null | wc -l)"
echo "audio" > "$CALLDIR/수신 사본정리 260819.m4a"
"$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "제자리로 옮겨짐"           1 "$(ls "$ROOT/remote/수신녹취/$YM/수신 사본정리 260819.txt" 2>/dev/null | wc -l)"
check "미분류의 옛 사본 제거됨"   0 "$(ls "$ROOT/remote/통화녹취_미분류/$YM/수신 사본정리 260819.txt" 2>/dev/null | wc -l)"
rm -f "$CALLDIR"/*

# ============ 8차 감수 재발 방지 ============
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
rm -f "$CALLDIR"/* 2>/dev/null

echo "== 86. 배포 설정의 VIDEO_EXTENSIONS 에 3gp 가 없다 =="
check "3gp 가 동영상 목록에 없음" 0 "$(grep -c '^VIDEO_EXTENSIONS=.*3gp' "$SKILL/scripts/config.example.env")"

echo "== 87. setup 이 좁혀 둔 이관 범위를 되돌리지 않는다 =="
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfgB.bak"
NARROW="$SHARED/DCIM"
sed -i "s|^MIGRATE_ROOTS=.*|MIGRATE_ROOTS=\"$NARROW\"|" "$HOME/.config/photo-autobackup/config.env"
"$SKILL/scripts/photo-autobackup.sh" setup "Z폴드 8 사진" "Z폴드 8 동영상" >/dev/null 2>&1
check "좁힌 범위 보존"            1 "$(grep -c "^MIGRATE_ROOTS=\"$NARROW\"" "$HOME/.config/photo-autobackup/config.env")"
cp "$ROOT/cfgB.bak" "$HOME/.config/photo-autobackup/config.env"

echo "== 88. migrate 도 기록 중인 파일을 건드리지 않는다 =="
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfgC.bak"
sed -i 's/^MIN_AGE_SECONDS=.*/MIN_AGE_SECONDS=3600/' "$HOME/.config/photo-autobackup/config.env"
mkdir -p "$SHARED/DCIM/Camera"
echo "방금생성" > "$SHARED/DCIM/Camera/기록중.jpg"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
"$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1
check "갓 만든 파일은 건드리지 않음" 1 "$(ls "$SHARED/DCIM/Camera/기록중.jpg" 2>/dev/null | wc -l)"
check "휴지통에도 없음"           0 "$(find "$TRASH" -name '기록중.jpg' 2>/dev/null | wc -l)"
cp "$ROOT/cfgC.bak" "$HOME/.config/photo-autobackup/config.env"
rm -f "$SHARED/DCIM/Camera/기록중.jpg"

echo "== 89. doctor 가 Wi-Fi 판정을 '실제로' 해 보고 말한다 =="
cat > "$ROOT/bin/termux-wifi-connectioninfo" <<'WIFI'
#!/usr/bin/env bash
[ "${WIFI_BROKEN:-0}" = "1" ] && exit 1
echo '{"supplicant_state": "COMPLETED"}'
WIFI
chmod +x "$ROOT/bin/termux-wifi-connectioninfo"
cp "$HOME/.config/photo-autobackup/config.env" "$ROOT/cfgD.bak"
echo 'REQUIRE_WIFI=1' >> "$HOME/.config/photo-autobackup/config.env"
out=$(WIFI_BROKEN=1 "$SKILL/scripts/photo-autobackup.sh" doctor 2>&1)
check "권한 없으면 실패로 보고"    1 "$(echo "$out" | grep -c 'Wi-Fi 상태를 읽지 못한다')"
check "'바로 쓸 수 있다' 안 함"    0 "$(echo "$out" | grep -c '바로 쓸 수 있다')"
out=$("$SKILL/scripts/photo-autobackup.sh" doctor 2>&1)
check "정상이면 OK"               1 "$(echo "$out" | grep -c 'Wi-Fi 전용 모드 판정 가능')"
cp "$ROOT/cfgD.bak" "$HOME/.config/photo-autobackup/config.env"
rm -f "$ROOT/bin/termux-wifi-connectioninfo"

echo "== 90. 동시에 돌아도 기록이 사라지지 않는다 =="
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1
FAILTSV2="$HOME/.local/share/photo-autobackup/failures.tsv"
mkdir -p "$SHARED/DCIM/Conc"
for i in $(seq 1 12); do echo "c$i" > "$SHARED/DCIM/Conc/동시_$i.jpg"; done
# 두 프로세스가 같은 상태 파일을 동시에 고친다
( RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1 ) &
pid1=$!
( RCLONE_FAKE_FAIL=1 "$SKILL/scripts/photo-autobackup.sh" migrate --yes >/dev/null 2>&1 ) &
pid2=$!
wait $pid1 $pid2
check "실패기록이 12건 다 남음"    12 "$(grep -c '동시_' "$FAILTSV2")"
check "장부 파일이 깨지지 않음"    0 "$(awk -F'\t' 'NF>0 && NF<2' "$FAILTSV2" | wc -l | tr -d ' ')"
rm -rf "$SHARED/DCIM/Conc"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 91. bootstrap 도 브랜치 하나에 매여 있지 않다 =="
check "main 우선 시도"            1 "$(grep -c 'RAW_BASE/main/\$RAW_PATH' "$SKILL/scripts/bootstrap.sh")"

echo "== 92. update 가 '실행 중인 자기 자신'을 안전하게 교체한다 =="
# 기존 시험은 update 를 '다른 파일'에 대고 돌려서, 실행 중인 자기 자신이라는
# 조건 자체를 만들지 않았다. 그래서 실기기에서 터진 이 결함을 못 잡았다.
SELF="$ROOT/bin/pab-self.sh"
cp "$SKILL/scripts/photo-autobackup.sh" "$SELF"
# 갱신 '뒤에' 실행되어야 할 표지를 스크립트 맨 끝에 심는다
printf '\necho "SENTINEL-끝까지-실행됨"\n' >> "$SELF"
chmod 755 "$SELF"
ino_before=$(stat -c %i "$SELF")

# 새 버전은 길이를 크게 달리해, 바이트 위치가 어긋나면 반드시 티가 나게 한다
sed 's|^VERSION=.*|VERSION="98.0.0"|' "$SKILL/scripts/photo-autobackup.sh" > "$ROOT/newer2.sh"
for i in $(seq 1 60); do echo "# 길이를 늘려 오프셋을 어긋나게 한다 $i" >> "$ROOT/newer2.sh"; done

out=$(UPDATE_URL="file://$ROOT/newer2.sh" PATH="$ROOT/bin:$PATH" bash "$SELF" update 2>&1)
ino_after=$(stat -c %i "$SELF")

check "갱신 뒤 남은 줄이 실행됨"   1 "$(echo "$out" | grep -c 'SENTINEL-끝까지-실행됨')"
check "unbound variable 없음"      0 "$(echo "$out" | grep -c 'unbound variable')"
check "command not found 없음"     0 "$(echo "$out" | grep -c 'command not found')"
check "파일은 실제로 교체됨"       1 "$(grep -c '^VERSION="98.0.0"' "$SELF")"
check "inode 가 바뀜(제자리 덮어쓰기 아님)" 1 "$([ "$ino_before" != "$ino_after" ] && echo 1 || echo 0)"
check "이번 실행은 옛 버전임을 알림" 1 "$(echo "$out" | grep -c '다음 명령부터 새 버전')"
rm -f "$SELF" "$SELF.bak" "$ROOT/newer2.sh"

echo "== 93. update 의 내려받기가 영영 매달리지 않는다 =="
# 실기기에서 update 가 화면에 아무것도 안 내놓고 멈췄다. 시간 제한 없는 curl 이
# 멎은 회선을 무한정 기다린 것이다. 진행 표시도 없어 어디서 멈췄는지 알 수 없었다.
CURLLOG="$ROOT/curl.args"
cat > "$ROOT/bin/curl" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CURLLOG"
dest=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && dest="$a"; prev="$a"; done
[ -n "$dest" ] && cp "$CURLSRC" "$dest"
STUB
chmod 755 "$ROOT/bin/curl"
sed 's|^VERSION=.*|VERSION="97.0.0"|' "$SKILL/scripts/photo-autobackup.sh" > "$ROOT/newer3.sh"
cp "$SKILL/scripts/photo-autobackup.sh" "$ROOT/bin/pab-to.sh"; chmod 755 "$ROOT/bin/pab-to.sh"

out=$(CURLLOG="$CURLLOG" CURLSRC="$ROOT/newer3.sh" UPDATE_URL="http://예시/pab.sh" \
      PATH="$ROOT/bin:$PATH" bash "$ROOT/bin/pab-to.sh" update 2>&1)

check "연결 시간 제한을 준다"     1 "$(grep -c -- '--connect-timeout 10' "$CURLLOG")"
check "전체 시간 제한을 준다"     1 "$(grep -c -- '--max-time 120' "$CURLLOG")"
check "시도 중인 주소를 보여준다" 1 "$(echo "$out" | grep -c '내려받는 중 \[1\]: http://예시/pab.sh')"

# 첫 주소가 죽어도 다음 주소로 넘어가며, 넘어갔다고 말해야 한다
cat > "$ROOT/bin/curl" <<'STUB'
#!/bin/bash
dest=""; prev=""; url=""
for a in "$@"; do
  [ "$prev" = "-o" ] && dest="$a"
  case "$a" in http*|file*) url="$a" ;; esac
  prev="$a"
done
case "$url" in *bad*) echo "curl: (22) 404 STUBERR" >&2; exit 7 ;; esac
[ -n "$dest" ] && cp "$CURLSRC" "$dest"
STUB
chmod 755 "$ROOT/bin/curl"
out=$(CURLSRC="$ROOT/newer3.sh" UPDATE_URL="http://bad/pab.sh http://good/pab.sh" \
      PATH="$ROOT/bin:$PATH" bash "$ROOT/bin/pab-to.sh" update 2>&1)
check "죽은 주소를 건너뛴다"      1 "$(echo "$out" | grep -c '다음 주소를 시도한다')"
check "다음 주소로 갱신 성공"     1 "$(echo "$out" | grep -c 'v97.0.0')"
# main 은 머지 전까지 늘 404 다. 그 404 를 오류로 보여 주면 성공한 갱신이
# 실패로 읽힌다 — 실기기에서 사용자가 실제로 그렇게 읽었다.
check "성공한 갱신에는 curl 오류가 안 보인다" 0 "$(echo "$out" | grep -c 'STUBERR')"

# 조용하게 만드느라 진단을 잃으면 안 된다. 전부 실패하면 이유가 보여야 한다.
out=$(CURLSRC="$ROOT/newer3.sh" UPDATE_URL="http://bad1/pab.sh http://bad2/pab.sh" \
      PATH="$ROOT/bin:$PATH" bash "$ROOT/bin/pab-to.sh" update 2>&1)
check "전부 실패하면 이유가 보인다" 1 "$(echo "$out" | grep -c 'STUBERR')"
check "전부 실패하면 갱신 안 한다"  0 "$(echo "$out" | grep -c 'v97.0.0')"
rm -f "$ROOT/bin/curl" "$ROOT/bin/pab-to.sh" "$ROOT/bin/pab-to.sh.bak" "$ROOT/newer3.sh" "$CURLLOG"

echo "== 94. 업로드 유예(HOLD_DAYS) — 갓 찍은 것은 건드리지 않는다 =="
# 찍자마자 올려서 폰에서 치우면, 정작 방금 찍은 걸 보려 할 때 없다.
rm -f "$CAM"/* 2>/dev/null
echo "fresh" > "$CAM/HOLD_new.jpg"                       # 방금 찍은 것
echo "old"   > "$CAM/HOLD_old.jpg"
touch -d '10 days ago' "$CAM/HOLD_old.jpg"               # 유예가 지난 것

out=$(HOLD_DAYS=7 "$SKILL/scripts/photo-autobackup.sh" once 2>&1)
check "유예 중인 원본은 폰에 남는다"   1 "$([ -f "$CAM/HOLD_new.jpg" ] && echo 1 || echo 0)"
check "유예 중인 것은 안 올라간다"     0 "$(find "$ROOT/remote" -name 'HOLD_new.jpg' | wc -l | tr -d ' ')"
check "유예 지난 것은 올라간다"        1 "$(find "$ROOT/remote" -name 'HOLD_old.jpg' | wc -l | tr -d ' ')"
check "유예 지난 원본은 치워진다"      0 "$([ -f "$CAM/HOLD_old.jpg" ] && echo 1 || echo 0)"
check "유예 건수를 보고한다"           1 "$(echo "$out" | grep -c '유예 1건')"

# 유예가 지나면 그때 올라가야 한다 — 영영 안 올라가면 백업이 아니다
touch -d '10 days ago' "$CAM/HOLD_new.jpg"
HOLD_DAYS=7 "$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "유예가 지나면 올라간다"         1 "$(find "$ROOT/remote" -name 'HOLD_new.jpg' | wc -l | tr -d ' ')"

# HOLD_DAYS=0 이면 유예 없이 즉시 — 기존 동작이 그대로 남아 있어야 한다
echo "now" > "$CAM/HOLD_zero.jpg"
HOLD_DAYS=0 "$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "0이면 즉시 올린다"              1 "$(find "$ROOT/remote" -name 'HOLD_zero.jpg' | wc -l | tr -d ' ')"

# 설정 오타로 백업이 통째로 멈추면 안 된다
echo "junk" > "$CAM/HOLD_junk.jpg"
HOLD_DAYS="이레" "$SKILL/scripts/photo-autobackup.sh" once >/dev/null 2>&1
check "숫자가 아니면 유예를 안 건다"   1 "$(find "$ROOT/remote" -name 'HOLD_junk.jpg' | wc -l | tr -d ' ')"

# verify-empty / migrate 는 감시 폴더가 아니라 MIGRATE_ROOTS($SHARED)를 훑는다
rm -f "$CAM"/* 2>/dev/null
rm -rf "$SHARED/HoldT"; mkdir -p "$SHARED/HoldT"
echo "fresh2" > "$SHARED/HoldT/HOLD_pend.jpg"
out=$(HOLD_DAYS=7 "$SKILL/scripts/photo-autobackup.sh" verify-empty 2>&1); vrc=$?
check "verify-empty 가 성공으로 끝난다" 0 "$vrc"
check "유예 중임을 밝힌다"              1 "$(echo "$out" | grep -c '유예 중')"

# migrate 계획의 건수와 실제 대상이 어긋나면, 승인한 것과 다른 일이 벌어진다
echo "mig_old" > "$SHARED/HoldT/HOLD_mig.jpg"
touch -d '10 days ago' "$SHARED/HoldT/HOLD_mig.jpg"
out=$(HOLD_DAYS=7 DRY_RUN=1 "$SKILL/scripts/photo-autobackup.sh" migrate 2>&1)
check "계획 대상은 유예 지난 1건"      1 "$(echo "$out" | grep -c '대상 파일 : 1건')"
check "계획이 유예 제외를 밝힌다"      1 "$(echo "$out" | grep -c '유예 제외 : 1건')"
rm -rf "$SHARED/HoldT"; rm -f "$CAM"/* 2>/dev/null

# 배포용 설정에도 같은 키가 있어야 한다(설치본에만 유예가 없는 사고를 막는다)
check "config.example.env 에 HOLD_DAYS" 1 "$(grep -c '^HOLD_DAYS=' "$SKILL/scripts/config.example.env")"

echo "== 95. 응답 없는 termux-api 가 명령 전체를 붙잡지 않는다 =="
# 실기기에서 probe 가 [2] 까지 찍고 멈췄다. Termux:API 동반 앱이 없으면
# termux-call-log 가 영영 응답하지 않고, 그동안 터미널에 친 것은 전부 그 명령의
# stdin 으로 빨려 들어간다. 사용자에게는 "무엇을 쳐도 반응이 없다"로만 보인다.
cat > "$ROOT/bin/termux-call-log" <<'HANG'
#!/bin/bash
cat > /dev/null   # 터미널 입력을 빨아들인다 — 실기기에서 벌어진 일 그대로
sleep 60
HANG
chmod 755 "$ROOT/bin/termux-call-log"

t0=$(date +%s)
out=$(TAPI_TIMEOUT=2 timeout 30 "$SKILL/scripts/photo-autobackup.sh" probe 2>&1); prc=$?
t1=$(date +%s)

check "probe 가 끝까지 실행된다"       1 "$(echo "$out" | grep -c '\[6\] 현재 설정')"
check "매달리지 않고 반환한다"         1 "$([ "$prc" != 124 ] && echo 1 || echo 0)"
check "제한 시간 안에 끝난다"          1 "$([ $((t1 - t0)) -lt 25 ] && echo 1 || echo 0)"
check "권한 문제로 진단된다"           1 "$(echo "$out" | grep -c '\[실패\]')"

# 입력을 삼키지 않아야 한다 — 파이프로 준 것이 그대로 남아 다음 명령이 읽어야 한다
got=$( { TAPI_TIMEOUT=2 timeout 30 "$SKILL/scripts/photo-autobackup.sh" probe >/dev/null 2>&1; cat; } <<< "SENTINEL-입력-보존" )
check "표준입력을 삼키지 않는다"       1 "$(echo "$got" | grep -c 'SENTINEL-입력-보존')"
rm -f "$ROOT/bin/termux-call-log"

echo "== 96. probe 의 전사 조사는 '폰 어디에도 없다'까지 단정한다 =="
# 녹음 폴더만 보고 "없음"이라 하면, 앱이 다른 폴더에 저장하는 경우를 놓친다.
# 실제로 그 모호함 때문에 사용자와 한 번 어긋났다.
PCALL="$SHARED/Recordings/Call"
rm -rf "$SHARED/Recordings" "$SHARED/전사보관"; mkdir -p "$PCALL"
printf 'a' > "$PCALL/통화 01011112222_260820_101010.m4a"

# (가) 폰 어디에도 전사가 없다 → 단정하고 Gemini 방침을 안내한다
out=$(CALL_ENABLED=1 CALL_DIRS="$PCALL" "$SKILL/scripts/photo-autobackup.sh" probe 2>&1)
check "폰 전체를 훑었다고 말한다"   1 "$(echo "$out" | grep -c '폰 전체를 훑는다')"
check "어디에도 없다고 단정한다"   1 "$(echo "$out" | grep -c '폰 어디에도 파일로는 없다')"
check "Gemini 방침을 안내한다"     1 "$(echo "$out" | grep -c 'Gemini')"
check "0건이 실패가 아님을 밝힌다" 1 "$(echo "$out" | grep -c '문제가 아니다')"

# (나) 다른 폴더에 있으면 찾아내고 경로를 보여 준다 (녹음 폴더 밖)
mkdir -p "$SHARED/전사보관"
printf '전사 본문' > "$SHARED/전사보관/통화 01011112222_260820_101010.txt"
out=$(CALL_ENABLED=1 CALL_DIRS="$PCALL" "$SKILL/scripts/photo-autobackup.sh" probe 2>&1)
check "다른 폴더의 전사를 찾아낸다" 1 "$(echo "$out" | grep -c '다른 폴더에서 1건 발견')"
check "경로를 보여 준다"            1 "$(echo "$out" | grep -c '전사보관')"
check "CALL_DIRS 로 흡수하라고 한다" 1 "$(echo "$out" | grep -c 'CALL_DIRS 에 더하면')"
check "이때는 단정하지 않는다"       0 "$(echo "$out" | grep -c '폰 어디에도 파일로는 없다')"

# (다) 녹음 폴더 옆에 있으면 폰 전체를 훑을 것도 없이 짝으로 처리한다
mv "$SHARED/전사보관/통화 01011112222_260820_101010.txt" "$PCALL/"
out=$(CALL_ENABLED=1 CALL_DIRS="$PCALL" "$SKILL/scripts/photo-autobackup.sh" probe 2>&1)
check "녹음 폴더 옆의 짝을 센다"    1 "$(echo "$out" | grep -c '녹음 폴더 안에서 1건 발견')"
check "불필요하게 전체를 안 훑는다" 0 "$(echo "$out" | grep -c '폰 전체를 훑는다')"
rm -rf "$SHARED/Recordings" "$SHARED/전사보관"

echo "== 97. 전사 조사는 Android/data 안까지 본다 =="
# 업로드용 스캔은 Android/data 를 일부러 건너뛴다(앱 캐시 쓰레기 방지). 그러나
# 전사를 '찾는' 입장에서는 거기가 가장 유력한 자리다. 제외를 그대로 물려받으면
# 정작 찾으려는 물건이 있는 곳만 안 보게 된다.
rm -rf "$SHARED/Recordings" "$SHARED/Android"
mkdir -p "$SHARED/Recordings/Call" "$SHARED/Android/data/com.sec.voicenote/files"
printf 'a' > "$SHARED/Recordings/Call/통화 01011112222_260820_101010.m4a"
printf '전사 본문' > "$SHARED/Android/data/com.sec.voicenote/files/통화 01011112222_260820_101010.txt"
out=$(CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"       "$SKILL/scripts/photo-autobackup.sh" probe 2>&1)
check "Android/data 의 전사를 찾아낸다" 1 "$(echo "$out" | grep -c '다른 폴더에서 1건 발견')"
check "없다고 잘못 단정하지 않는다"     0 "$(echo "$out" | grep -c '폰 어디에도 파일로는 없다')"

echo "== 98. probe --deep 는 A·B·C 를 빠짐없이 찍는다 =="
# 못 찾더라도 '무엇을 어디까지 봤는지'가 남아야 다음 판단이 선다.
out=$(CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"       "$SKILL/scripts/photo-autobackup.sh" probe --deep 2>&1)
check "A 확장자 무관 스윕"        1 "$(echo "$out" | grep -c '\[A\] 최근 만들어진')"
check "B Android/data 열거"       1 "$(echo "$out" | grep -c '\[B\] Android/data')"
check "C 앱·provider 열거"        1 "$(echo "$out" | grep -c '\[C\] 녹음·통화 앱')"
# 출력 전체를 세면 [A] 의 경로에도 같은 이름이 있어 부풀려진다. B 절만 잘라 본다.
bsec=$(echo "$out" | sed -n '/\[B\] Android\/data/,/\[C\] /p')
check "B 가 관련 앱 폴더를 찾는다" 1 "$(echo "$bsec" | grep -q 'com.sec.voicenote' && echo 1 || echo 0)"
check "막혔을 때의 다음 수를 밝힌다" 1 "$(echo "$out" | grep -c 'Tasker')"
# --deep 없이 부르면 이 절이 나오면 안 된다 (기본 probe 를 길게 만들지 않는다)
out=$(CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"       "$SKILL/scripts/photo-autobackup.sh" probe 2>&1)
check "--deep 없이는 안 나온다"   0 "$(echo "$out" | grep -c '깊은 조사')"
check "알 수 없는 옵션은 거부한다" 1 "$("$SKILL/scripts/photo-autobackup.sh" probe --없는옵션 2>&1 | grep -c '알 수 없는 옵션')"

echo "== 99. 녹취를 올리면 알리고, 올릴 게 없으면 안 알린다 =="
# 전사를 자동으로 못 가져오는 기기에서는 사람이 Gemini 에게 시켜야 하는데 그걸
# 잊는 것이 실제 실패 지점이다. 그렇다고 매번 띄우면 알림을 꺼 버려 대책이 죽는다.
cat > "$ROOT/bin/termux-notification" <<'TN'
#!/usr/bin/env bash
printf '%s
' "$*" >> "$NOTIFY_LOG"
TN
chmod 755 "$ROOT/bin/termux-notification"
NL="$ROOT/notify99.log"; : > "$NL"
rm -f "$SHARED/Android/data/com.sec.voicenote/files"/*
NOTIFY_LOG="$NL" CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"   "$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "업로드하면 알린다"          1 "$(grep -c '통화녹취 1건 업로드' "$NL")"
check "Gemini 전사를 상기시킨다"   1 "$(grep -c 'Gemini' "$NL")"

# 두 번째 실행 — 이미 올렸으니 새로 올릴 것이 없다 → 알림이 늘면 안 된다
before=$(wc -l < "$NL")
NOTIFY_LOG="$NL" CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"   "$SKILL/scripts/photo-autobackup.sh" calls >/dev/null 2>&1
check "올릴 게 없으면 안 알린다"   "$before" "$(wc -l < "$NL")"

echo "== 100. status 가 '전사 짝 없음' 건수를 센다 =="
out=$(CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"       "$SKILL/scripts/photo-autobackup.sh" status 2>&1)
check "짝 없는 녹취를 센다"        1 "$(echo "$out" | grep -c '전사 짝 없음 1건')"
# 짝을 놓아 주면 그만큼 줄어야 한다
printf '전사' > "$SHARED/Recordings/Call/통화 01011112222_260820_101010.txt"
out=$(CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"       "$SKILL/scripts/photo-autobackup.sh" status 2>&1)
check "짝이 생기면 0건이 된다"     1 "$(echo "$out" | grep -c '전사 짝 없음 0건')"
check "통화녹취를 끄면 안 보인다"  0 "$(CALL_ENABLED=0 "$SKILL/scripts/photo-autobackup.sh" status 2>&1 | grep -c '전사 짝 없음')"
rm -f "$ROOT/bin/termux-notification"
rm -rf "$SHARED/Recordings" "$SHARED/Android"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 101. [B] 는 '막힘'과 '비었음'을 구분해 단정한다 =="
# 둘을 한 문장으로 뭉개면 '답이 아닌 것'을 답으로 착각한다. 실기기에서 그랬다.
rm -rf "$SHARED/Recordings" "$SHARED/Android"
mkdir -p "$SHARED/Recordings/Call"
printf 'a' > "$SHARED/Recordings/Call/통화 01011112222_260820_101010.m4a"
PROBE=(env CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call" "$SKILL/scripts/photo-autobackup.sh" probe --deep)

# (가) Android/data 가 아예 없다 → 막혔다고 단정
out=$("${PROBE[@]}" 2>&1)
check "막혔음을 단정한다"        1 "$(echo "$out" | grep -c 'Android/data 를 막고 있다 (확정)')"

# (나) 목록은 보이는데 관련 앱이 없다 → 여기엔 없다고 단정 (전혀 다른 문구여야 한다)
mkdir -p "$SHARED/Android/data/com.kakao.talk" "$SHARED/Android/data/com.nhn.android.search"
out=$("${PROBE[@]}" 2>&1)
check "보이는 앱 개수를 찍는다"   1 "$(echo "$out" | grep -c '목록에 보이는 앱 폴더: 2개')"
check "여기엔 없다고 단정한다"   1 "$(echo "$out" | grep -c '녹음·통화 앱 폴더가 없다 (확정)')"
check "막힘과 다른 문구다"       0 "$(echo "$out" | grep -c 'Android/data 를 막고 있다')"

# (다) 관련 앱이 있으면 그 안의 파일까지 바로 보여 준다
mkdir -p "$SHARED/Android/data/com.sec.android.app.voicenote/files"
printf '전사' > "$SHARED/Android/data/com.sec.android.app.voicenote/files/전사본.txt"
out=$("${PROBE[@]}" 2>&1)
check "관련 앱 폴더를 짚는다"     1 "$(echo "$out" | grep -c '관련: com.sec.android.app.voicenote')"
bsec=$(echo "$out" | sed -n '/\[B\] Android\/data/,/\[C\] /p')
check "그 안의 파일까지 보여준다" 1 "$(echo "$bsec" | grep -q '전사본.txt' && echo 1 || echo 0)"

echo "== 102. [C] 는 pm list 가 막혀도 이름으로 직접 찌른다 =="
# 안드로이드 11+ 는 앱 목록을 안 준다. 열거에 기대면 늘 여기서 막힌다.
# 그러나 '이름을 아는 패키지 조회'는 대개 답한다 — 그 경로로 가야 한다.
cat > "$ROOT/bin/pm" <<'PMSTUB'
#!/bin/bash
case "$1" in
  list) exit 0 ;;                       # 목록은 절대 안 준다 (실기기와 동일)
  path) case "$2" in com.sec.android.app.voicenote) echo "package:/x.apk";; *) exit 1;; esac ;;
esac
PMSTUB
cat > "$ROOT/bin/dumpsys" <<'DSTUB'
#!/bin/bash
[ "$2" = "com.sec.android.app.voicenote" ] && echo "      authority=com.sec.voicenote.provider"
exit 0
DSTUB
cat > "$ROOT/bin/content" <<'CSTUB'
#!/bin/bash
printf '%s
' "$*" >> "$CONTENT_LOG"
echo "Row: 0 _id=1, text=전사내용"
CSTUB
chmod 755 "$ROOT/bin/pm" "$ROOT/bin/dumpsys" "$ROOT/bin/content"
CLOG="$ROOT/content.args"; : > "$CLOG"
out=$(CONTENT_LOG="$CLOG" CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"       "$SKILL/scripts/photo-autobackup.sh" probe --deep 2>&1)
check "목록이 막혀도 앱을 찾는다"   1 "$(echo "$out" | grep -c '앱: com.sec.android.app.voicenote (설치됨)')"
check "provider 를 뽑아낸다"        1 "$(echo "$out" | grep -c 'provider: com.sec.voicenote.provider')"
check "content query 를 실제로 친다" 1 "$(grep -c 'content://com.sec.voicenote.provider/' "$CLOG")"
check "조회 결과를 보여 준다"        1 "$(echo "$out" | grep -c '전사내용')"
check "설치 안 된 후보는 안 찍는다"  0 "$(echo "$out" | grep -c 'com.samsung.android.dialer (설치됨)')"

echo "== 103. 기계로 막혔을 때 사람이 할 일을 알려 준다 =="
check "앱 UI 확인을 안내한다"       1 "$(echo "$out" | grep -c '텍스트 내보내기')"
check "폴더를 CALL_DIRS 에 더하라"  1 "$(echo "$out" | grep -q 'CALL_DIRS 에 더하면' && echo 1 || echo 0)"
check "루팅은 권하지 않는다"        1 "$(echo "$out" | grep -c '루팅은 권하지 않는다')"
rm -f "$ROOT/bin/pm" "$ROOT/bin/dumpsys" "$ROOT/bin/content" "$CLOG"
rm -rf "$SHARED/Recordings" "$SHARED/Android"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 104. dumpsys 가 막혀도 APK 매니페스트에서 authority 를 캔다 =="
# 실기기에서 [C] 가 여기서 멈췄다: "앱은 있으나 provider 를 못 읽었다(dumpsys 가 막혔다)".
# dumpsys 는 한 가지 경로일 뿐이고 원본은 APK 안의 AndroidManifest.xml 이다.
rm -rf "$SHARED/Recordings"; mkdir -p "$SHARED/Recordings/Call"
printf 'a' > "$SHARED/Recordings/Call/통화 01011112222_260820_101010.m4a"
APKDIR="$ROOT/fakeapk"; mkdir -p "$APKDIR"
# C-3 의 고정 후보 목록에 '없는' 이름이어야 한다. 목록에 있는 이름을 쓰면
# C-2 를 지워도 C-3 가 같은 답을 내서 이 시험이 아무것도 증명하지 못한다.
printf 'junk com.sec.android.app.voicenote.customprov junk\n' > "$APKDIR/AndroidManifest.xml"
( cd "$APKDIR" && zip -q "$ROOT/voicenote.apk" AndroidManifest.xml )
cat > "$ROOT/bin/pm" <<'PMSTUB'
#!/bin/bash
case "$1" in
  list) exit 0 ;;
  path) case "$2" in com.sec.android.app.voicenote) echo "package:$FAKE_APK";; *) exit 1;; esac ;;
esac
PMSTUB
cat > "$ROOT/bin/dumpsys" <<'DSTUB'
#!/bin/bash
exit 0                                   # 막혔다 — authority 를 하나도 안 준다
DSTUB
cat > "$ROOT/bin/content" <<'CSTUB'
#!/bin/bash
printf '%s\n' "$*" >> "$CONTENT_LOG"
case "$*" in
  *voicenote.customprov*) echo "Row: 0 _id=1, text=전사본문" ;;
  *voicenote.provider*) echo "Row: 0 _id=1, text=전사본문" ;;
  *) echo "Error: java.lang.SecurityException: Permission Denial" ;;
esac
CSTUB
chmod 755 "$ROOT/bin/pm" "$ROOT/bin/dumpsys" "$ROOT/bin/content"
CLOG="$ROOT/content104.args"; : > "$CLOG"
RUN=(env FAKE_APK="$ROOT/voicenote.apk" CONTENT_LOG="$CLOG" CALL_ENABLED=1      CALL_DIRS="$SHARED/Recordings/Call" "$SKILL/scripts/photo-autobackup.sh" probe --deep)
out=$("${RUN[@]}" 2>&1)
check "dumpsys 실패를 밝힌다"       1 "$(echo "$out" | grep -c 'C-1 dumpsys: provider 를 못 얻었다')"
check "APK 에서 authority 를 캔다"  1 "$(echo "$out" | grep -c 'provider: com.sec.android.app.voicenote.customprov')"
check "실제로 조회한다"             1 "$(grep -c 'content://com.sec.android.app.voicenote.customprov/' "$CLOG")"
check "C-2 로 끝나 C-3 는 안 간다"  0 "$(echo "$out" | grep -c 'C-3 알려진 authority')"
check "읽혔음을 알린다"             1 "$(echo "$out" | grep -c '읽힌다!')"
check "내용을 보여 준다"            1 "$(echo "$out" | grep -c '전사본문')"
check "전부 실패로 결론내지 않는다" 0 "$(echo "$out" | grep -c 'C-1·C-2·C-3 전부 실패')"

echo "== 105. unzip 이 없으면 조용히 넘어가지 않고 이유를 말한다 =="
# 조용히 건너뛰면 또 '못 봤다'로 끝나 사용자가 원인을 알 수 없다.
cat > "$ROOT/bin/unzip" <<'UZ'
#!/bin/bash
exit 127
UZ
chmod 755 "$ROOT/bin/unzip"
# have() 가 못 찾게 하려면 PATH 에서 진짜 unzip 도 가려야 한다 — 스텁이 앞에 온다.
out=$(env FAKE_APK="$ROOT/voicenote.apk" CONTENT_LOG="$CLOG" CALL_ENABLED=1       CALL_DIRS="$SHARED/Recordings/Call" PATH="$ROOT/bin:$PATH"       "$SKILL/scripts/photo-autobackup.sh" probe --deep 2>&1)
check "매니페스트를 못 열면 밝힌다" 1 "$(echo "$out" | grep -cE 'C-2 APK: (unzip 이 없어|매니페스트에서)')"
rm -f "$ROOT/bin/unzip"

echo "== 106. 전부 막히면 알려진 authority 를 직접 찔러 본다 =="
# 이름을 몰라도 후보는 몇 개뿐이다. 쳐 보면 열렸는지 막혔는지 답이 나온다.
cat > "$ROOT/bin/pm" <<'PMSTUB'
#!/bin/bash
case "$1" in
  list) exit 0 ;;
  path) exit 1 ;;                        # APK 경로조차 안 준다
esac
PMSTUB
chmod 755 "$ROOT/bin/pm"
: > "$CLOG"
out=$(env CONTENT_LOG="$CLOG" CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call"       "$SKILL/scripts/photo-autobackup.sh" probe --deep 2>&1)
check "C-3 로 넘어간다"           1 "$(echo "$out" | grep -c 'C-3 알려진 authority')"
check "후보를 실제로 조회한다"     1 "$(grep -c 'com.samsung.android.callrecording.provider' "$CLOG")"
# 후보 4개 중 열리는 것은 하나뿐이므로 '막혔다'는 여러 번 나온다. 있느냐만 본다.
check "막힌 것은 막혔다고 말한다"  1 "$(echo "$out" | grep -q '막혔다: .*SecurityException' && echo 1 || echo 0)"
check "열린 것은 읽힌다고 말한다"  1 "$(echo "$out" | grep -c '읽힌다!')"
rm -f "$ROOT/bin/pm" "$ROOT/bin/dumpsys" "$ROOT/bin/content" "$CLOG" "$ROOT/voicenote.apk"
rm -rf "$APKDIR" "$SHARED/Recordings"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 107. content 가 PATH 에 없어도 /system/bin 에서 찾아 실제로 조회한다 =="
# 실기기에서 '→ content 명령이 없다' 만 찍고 "C-1·C-2·C-3 전부 실패" 라고 끝났다.
# 조회를 한 번도 안 해 보고 낸 결론이었다. Termux 의 PATH 에 /system/bin 이
# 없는 것이 원인이지, provider 가 막힌 것이 아니었다.
rm -rf "$SHARED/Recordings" "$ROOT/sysbin"; mkdir -p "$SHARED/Recordings/Call" "$ROOT/sysbin"
printf 'a' > "$SHARED/Recordings/Call/통화 01011112222_260820_101010.m4a"
cat > "$ROOT/sysbin/content" <<'SB'
#!/bin/bash
printf '%s\n' "$*" >> "$CONTENT_LOG"
echo "Row: 0 _id=1, text=전사본문"
SB
chmod 755 "$ROOT/sysbin/content"
CLOG="$ROOT/content107.args"; : > "$CLOG"
# PATH 에는 content 가 없다 — ANDROID_BIN_DIR 로만 찾을 수 있어야 한다
out=$(env ANDROID_BIN_DIR="$ROOT/sysbin" CONTENT_LOG="$CLOG" CALL_ENABLED=1 \
      CALL_DIRS="$SHARED/Recordings/Call" "$SKILL/scripts/photo-autobackup.sh" probe --deep 2>&1)
check "PATH 에 없어도 찾아낸다"     0 "$(echo "$out" | grep -c 'content 를 찾지 못했다')"
check "조회를 실제로 실행한다"      1 "$([ -s "$CLOG" ] && echo 1 || echo 0)"
check "읽혔음을 알린다"             1 "$(echo "$out" | grep -q '읽힌다!' && echo 1 || echo 0)"

echo "== 108. content 가 정말 없으면 '실패'가 아니라 '미확인'이라고 말한다 =="
# 이번 재발의 본질 — 못 찾은 것과 거부당한 것을 같은 문장으로 쓰면 안 된다.
: > "$CLOG"
out=$(env ANDROID_BIN_DIR="$ROOT/nonexistent" CONTENT_LOG="$CLOG" CALL_ENABLED=1 \
      CALL_DIRS="$SHARED/Recordings/Call" "$SKILL/scripts/photo-autobackup.sh" probe --deep 2>&1)
check "못 찾았다고 밝힌다"          1 "$(echo "$out" | grep -q 'content 를 찾지 못했다' && echo 1 || echo 0)"
check "미확인이라고 말한다"         1 "$(echo "$out" | grep -c '실패가 아니라 미확인이다')"
check "'전부 실패'라고 안 한다"     0 "$(echo "$out" | grep -c '전부 거부당했다')"
check "확인 방법을 알려 준다"       1 "$(echo "$out" | grep -c 'ANDROID_BIN_DIR=')"
check "조회를 하지도 않았다"        0 "$([ -s "$CLOG" ] && echo 1 || echo 0)"
rm -rf "$ROOT/sysbin" "$SHARED/Recordings"; rm -f "$CLOG"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 109. 모르는 응답을 '읽힌다'로 단정하지 않는다 =="
# 실기기에서 'app_process: inaccessible or not found' 가 '읽힌다!' 로 찍혔다.
# 실패 낱말 목록으로 거르면 처음 보는 실패 문구가 전부 성공이 된다. 하마터면
# 전사를 꺼낼 수 있다고 보고할 뻔했다. 성공의 모습을 아는 경우에만 성공이다.
rm -rf "$SHARED/Recordings" "$ROOT/sysbin"; mkdir -p "$SHARED/Recordings/Call" "$ROOT/sysbin"
printf 'a' > "$SHARED/Recordings/Call/통화 01011112222_260820_101010.m4a"
mkcontent() {   # $1 = 종료코드, 나머지 = 출력할 문구
  local rc="$1"; shift
  { printf '#!/bin/bash
'
    printf 'printf "%%s\\n" "$PATH" >> "$PATHLOG"
'
    printf 'echo %s
' "$(printf '%q' "$*")"
    printf 'exit %s
' "$rc"; } > "$ROOT/sysbin/content"
  chmod 755 "$ROOT/sysbin/content"
}
PLOG="$ROOT/path109.log"
RUNP=(env ANDROID_BIN_DIR="$ROOT/sysbin" PATHLOG="$PLOG" CALL_ENABLED=1 \
      CALL_DIRS="$SHARED/Recordings/Call" "$SKILL/scripts/photo-autobackup.sh" probe --deep)

: > "$PLOG"; mkcontent 0 "/system/bin/content[3]: app_process: inaccessible or not found"
out=$("${RUNP[@]}" 2>&1)
check "모르는 응답은 읽힌다가 아니다"  0 "$(echo "$out" | grep -c '읽힌다!')"
check "판정 불가로 표시한다"           1 "$(echo "$out" | grep -q '판정 불가' && echo 1 || echo 0)"
check "미확인으로 결론낸다"            1 "$(echo "$out" | grep -c '실패가 아니라 미확인이다')"

: > "$PLOG"; mkcontent 0 "Row: 0 _id=1, text=전사본문"
out=$("${RUNP[@]}" 2>&1)
check "Row: 로 시작하면 성공"          1 "$(echo "$out" | grep -q '읽힌다!' && echo 1 || echo 0)"
check "성공을 결론에 반영한다"         1 "$(echo "$out" | grep -c '여기서 전사를 끌어올 수 있다')"

: > "$PLOG"; mkcontent 1 "Error: java.lang.SecurityException"
out=$("${RUNP[@]}" 2>&1)
check "종료코드가 0이 아니면 실패"     1 "$(echo "$out" | grep -q '실패(코드 1)' && echo 1 || echo 0)"
check "실패를 읽힌다로 안 쓴다"        0 "$(echo "$out" | grep -c '읽힌다!')"

echo "== 110. 안드로이드 도구를 부를 때 PATH 에 그 폴더를 넣는다 =="
# /system/bin/content 는 쉘 스크립트라 내부에서 app_process 를 PATH 로 찾는다.
# 절대 경로로만 부르면 그 안쪽이 죽는다 — 실기기 실패의 진짜 원인이었다.
check "PATH 에 도구 폴더가 들어간다"   1 "$(head -1 "$PLOG" | grep -q "^$ROOT/sysbin:" && echo 1 || echo 0)"

echo "== 111. C-2 는 UTF-16 로 저장된 authority 도 읽는다 =="
# AXML 문자열 풀은 UTF-16LE 인 경우가 흔하다. 그러면 'com.sec...' 가
# 'c o m ...' 라 ASCII grep 에 안 잡힌다. 실기기에서 앱 5개가 전부 빈손이었다.
UDIR="$ROOT/utf16apk"; rm -rf "$UDIR"; mkdir -p "$UDIR"
python3 -c "import sys; sys.stdout.buffer.write('com.sec.android.app.voicenote.u16prov'.encode('utf-16-le'))" \
  > "$UDIR/AndroidManifest.xml"
( cd "$UDIR" && zip -q "$ROOT/u16.apk" AndroidManifest.xml )
cat > "$ROOT/sysbin/pm" <<'PMS'
#!/bin/bash
case "$1" in
  list) exit 0 ;;
  path) case "$2" in com.sec.android.app.voicenote) echo "package:$FAKE_APK";; *) exit 1;; esac ;;
esac
PMS
chmod 755 "$ROOT/sysbin/pm"
: > "$PLOG"; mkcontent 0 "Row: 0 _id=1, text=UTF16전사"
out=$(env ANDROID_BIN_DIR="$ROOT/sysbin" PATHLOG="$PLOG" FAKE_APK="$ROOT/u16.apk" \
      CALL_ENABLED=1 CALL_DIRS="$SHARED/Recordings/Call" \
      "$SKILL/scripts/photo-autobackup.sh" probe --deep 2>&1)
check "UTF-16 authority 를 찾아낸다"   1 "$(echo "$out" | grep -c 'provider: com.sec.android.app.voicenote.u16prov')"
rm -rf "$ROOT/sysbin" "$UDIR" "$SHARED/Recordings"; rm -f "$ROOT/u16.apk" "$PLOG"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 112. status 가 감시 데몬 생사를 '확인해서' 말한다 =="
# 이 스킬의 존재 이유가 '자동으로 도는 것'인데 켜졌는지 확인할 방법이 없었다.
# 실기기에서 올릴 차례 4건이 대기만 하고 있었는데 아무도 그 사실을 몰랐다.
PIDF="$HOME/.local/share/photo-autobackup/watch.pid"
rm -f "$PIDF"
out=$("$SKILL/scripts/photo-autobackup.sh" status 2>&1)
check "pidfile 없으면 멈춤"        1 "$(echo "$out" | grep -c '감시 데몬       : 멈춤 — ')"

# 죽은 PID 가 든 pidfile — 강제 종료·재부팅 뒤에 흔히 남는다.
# 이걸 '돌고 있음'으로 읽으면 확인 없이 단정하는 것이다(이 작업에서 네 번 나온 부류).
mkdir -p "$(dirname "$PIDF")"
sh -c 'echo $$' > "$PIDF"          # 즉시 끝나는 프로세스의 PID → 이미 죽었다
out=$("$SKILL/scripts/photo-autobackup.sh" status 2>&1)
check "죽은 PID 를 살았다고 안 한다" 0 "$(echo "$out" | grep -c '돌고 있음')"
check "비정상 종료 흔적이라 말한다"  1 "$(echo "$out" | grep -c '비정상 종료 흔적')"

# 살아 있는 PID — sleep 을 띄워 두고 그 PID 를 쓴다
sleep 30 & LIVE=$!
echo "$LIVE" > "$PIDF"
out=$("$SKILL/scripts/photo-autobackup.sh" status 2>&1)
check "살아 있으면 돌고 있음"      1 "$(echo "$out" | grep -c "돌고 있음 (PID $LIVE)")"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null
rm -f "$PIDF"

echo "== 113. doctor 가 공용 client_id 를 경고한다 (실패로는 안 만든다) =="
# 2026년 중 폐지되면 백업이 통째로 멈춘다. NOTICE 는 로그에 묻혀 아무도 안 본다.
# 하네스 공용 rclone 스텁을 잠시 갈아끼운다. 원본을 챙겨 두지 않고 지우면
# 뒤따르는 시험이 전부 'rclone: command not found' 로 무너진다 — 실제로 그랬다.
cp "$ROOT/bin/rclone" "$ROOT/rclone.orig"
cat > "$ROOT/bin/rclone" <<'RC2'
#!/usr/bin/env bash
case "$1" in
  version) echo "rclone v1.0-fake" ;;
  listremotes) echo "gdrive:" ;;
  lsd) exit 0 ;;
  config) [ "$2" = "show" ] && { [ "${FAKE_CLIENT_ID:-}" = "1" ] && echo "client_id = 12345.apps.googleusercontent.com"; echo "type = drive"; } ;;
  *) exit 0 ;;
esac
RC2
chmod 755 "$ROOT/bin/rclone"
out=$("$SKILL/scripts/photo-autobackup.sh" doctor 2>&1); drc=$?
check "공용이면 경고한다"          1 "$(echo "$out" | grep -c '공용 client_id 를 쓰고 있다')"
check "느린 이유도 알려준다"       1 "$(echo "$out" | grep -c '전 세계가 나눠 쓰는 할당량')"
check "경고여도 doctor 는 통과"    0 "$drc"
out=$(FAKE_CLIENT_ID=1 "$SKILL/scripts/photo-autobackup.sh" doctor 2>&1)
check "자체 키면 경고 안 한다"     0 "$(echo "$out" | grep -c '공용 client_id')"

echo "== 114. probe [5] 가 '앱 없음'을 '권한 없음'이라 하지 않는다 =="
# 실기기에서 이 오진 때문에 사용자가 존재하지도 않는 설정 메뉴를 찾아 헤맸다.
# termux-api(명령어)와 Termux:API(앱)는 별개다.
rm -rf "$ROOT/sysbin"; mkdir -p "$ROOT/sysbin"
cat > "$ROOT/bin/termux-call-log" <<'TCL'
#!/usr/bin/env bash
exit 1                                   # 명령은 있는데 호출은 실패한다
TCL
chmod 755 "$ROOT/bin/termux-call-log"
cat > "$ROOT/sysbin/pm" <<'PMS'
#!/bin/bash
case "$1" in
  path) [ "${FAKE_APP:-no}" = "yes" ] && { echo "package:/x.apk"; exit 0; }; exit 1 ;;
  *) exit 0 ;;
esac
PMS
chmod 755 "$ROOT/sysbin/pm"
RUN5=(env ANDROID_BIN_DIR="$ROOT/sysbin" CALL_ENABLED=1 "$SKILL/scripts/photo-autobackup.sh" probe)

out=$(FAKE_APP=no "${RUN5[@]}" 2>&1)
check "앱이 없으면 그렇게 말한다"   1 "$(echo "$out" | grep -c "Termux:API '앱' 이 안 깔렸다")"
check "권한 탓으로 몰지 않는다"     0 "$(echo "$out" | grep -c '통화기록 권한이 없다')"
check "같은 출처여야 함을 알린다"   1 "$(echo "$out" | grep -c '스토어 판을 섞으면')"

out=$(FAKE_APP=yes "${RUN5[@]}" 2>&1)
check "앱이 있으면 권한 문제로 본다" 1 "$(echo "$out" | grep -c '앱은 있으나 통화기록 권한이 없다')"
check "대화상자 띄우는 법을 알린다"  1 "$(echo "$out" | grep -c 'termux-call-log -l 1 을 직접 실행')"

# pm 을 못 찾으면 앱 유무를 단정하면 안 된다
out=$(env ANDROID_BIN_DIR="$ROOT/nonexistent" CALL_ENABLED=1       "$SKILL/scripts/photo-autobackup.sh" probe 2>&1)
check "pm 없으면 단정하지 않는다"   1 "$(echo "$out" | grep -c '앱 설치 여부는 확인하지 못했다')"
rm -f "$ROOT/bin/termux-call-log"; rm -rf "$ROOT/sysbin"
mv "$ROOT/rclone.orig" "$ROOT/bin/rclone"      # 공용 스텁을 되돌린다

echo "== 115. transcripts: 손수 내보낸 전사를 녹음과 짝지어 준다 =="
# 전사 자동 추출이 막힌 기기(삼성)에서도 사람이 앱에서 하나씩 내보낼 수는 있다.
# 그 경로를 열어 둔다. 손이 가는 부분은 이름 맞추기 하나뿐이고 그게 제일 고약하다.
rm -rf "$SHARED/Recordings" "$SHARED/Drop"; mkdir -p "$SHARED/Recordings/Call" "$SHARED/Drop"
CALLDIR="$SHARED/Recordings/Call"
printf 'audio1' > "$CALLDIR/통화 01011112222_260820_112710.m4a"
printf 'audio2' > "$CALLDIR/통화 01033334444_260820_181242.m4a"
# 앱이 내보낸 전사 — 이름은 다르지만 녹음 시각이 들어 있다
printf '전사본문A' > "$SHARED/Drop/녹음 전사 260820_112710.txt"
# 시각이 없는 것 — 어느 통화인지 알 수 없다. 짐작해서 붙이면 안 된다.
printf '정체불명'   > "$SHARED/Drop/메모.txt"
# 해당하는 녹음이 없는 것
printf '고아'       > "$SHARED/Drop/통화 990101_010101.txt"

T=(env CALL_ENABLED=1 CALL_DIRS="$CALLDIR" TRANSCRIPT_DROP_DIRS="$SHARED/Drop" \
   "$SKILL/scripts/photo-autobackup.sh" transcripts)

out=$(DRY_RUN=1 "${T[@]}" 2>&1)
check "예행연습은 파일을 안 만든다" 0 "$(ls "$CALLDIR"/*.txt 2>/dev/null | wc -l | tr -d ' ')"
check "예행연습도 짝을 보여준다"    1 "$(echo "$out" | grep -c 'DRY-RUN')"

out=$("${T[@]}" 2>&1)
check "녹음과 같은 이름으로 짝지음" 1 "$([ -f "$CALLDIR/통화 01011112222_260820_112710.txt" ] && echo 1 || echo 0)"
check "내용이 보존된다"             1 "$(grep -c '전사본문A' "$CALLDIR/통화 01011112222_260820_112710.txt")"
check "원본은 그 자리에 남는다"     1 "$([ -f "$SHARED/Drop/녹음 전사 260820_112710.txt" ] && echo 1 || echo 0)"
check "시각 없는 것은 건너뛴다"     1 "$(echo "$out" | grep -c '녹음 시각(YYMMDD_HHMMSS)이 없다')"
check "짝 없는 것은 건너뛴다"       1 "$(echo "$out" | grep -c '해당하는 녹음이 없다')"
# 추측해서 아무 녹음에나 붙이면 남의 통화 내용이 엉뚱한 곳에 달린다 — 절대 금지
check "엉뚱한 녹음에 안 붙인다"     0 "$([ -f "$CALLDIR/통화 01033334444_260820_181242.txt" ] && echo 1 || echo 0)"
check "다음 단계를 알려준다"        1 "$(echo "$out" | grep -c 'calls')"

# 두 번 돌려도 덮어쓰지 않는다
out=$("${T[@]}" 2>&1)
# 요약 줄에도 같은 낱말이 나온다. 항목 줄만 센다.
check "이미 있으면 건드리지 않는다" 1 "$(echo "$out" | grep -c '\[이미있음\]')"

# 짝지어진 전사는 calls 가 녹음과 함께 올린다 (기존 짝 업로드 기능)
out=$(env CALL_ENABLED=1 CALL_DIRS="$CALLDIR" \
      "$SKILL/scripts/photo-autobackup.sh" calls 2>&1)
echo "$out" > "$ROOT/calls115.log"
check "calls 가 전사도 올린다"      1 "$(find "$ROOT/remote" -name '통화 01011112222_260820_112710.txt' | wc -l | tr -d ' ')"
rm -rf "$SHARED/Recordings" "$SHARED/Drop"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo "== 116. transcripts: 남은 일 목록과 손수 짝짓기 =="
# 주기적으로 하려면 '무엇이 아직 안 됐는지'가 있어야 한다. 그리고 삼성 노트를
# 거쳐 나온 전사는 노트 제목이 이름이라 시각이 없다 — 그건 손으로 붙여야 한다.
rm -rf "$SHARED/Recordings" "$SHARED/Drop"; mkdir -p "$SHARED/Recordings/Call" "$SHARED/Drop"
CALLDIR="$SHARED/Recordings/Call"
# 실제 화면에 보이는 세 가지 이름꼴. 셋 다 끝이 _YYMMDD_HHMMSS 다.
printf 'a1' > "$CALLDIR/통화 01075907672_260820_161055.m4a"
printf 'a2' > "$CALLDIR/통화 현대카드_260820_182610.m4a"
printf 'a3' > "$CALLDIR/음성 메시지 01075907672_260820_171533.m4a"
# 이미 전사가 붙어 있는 녹음 — 남은 일 목록에 뜨면 안 된다
printf 'a4' > "$CALLDIR/통화 01033334444_260820_112710.m4a"
printf '이미있음' > "$CALLDIR/통화 01033334444_260820_112710.txt"
# 삼성 노트를 거쳐 나온 전사 — 시각이 없다
printf '서류 제출 확인 내용' > "$SHARED/Drop/서류 제출 확인 및 대출 일정 문의 통화.txt"

T=(env CALL_ENABLED=1 CALL_DIRS="$CALLDIR" TRANSCRIPT_DROP_DIRS="$SHARED/Drop" \
   "$SKILL/scripts/photo-autobackup.sh" transcripts)
out=$("${T[@]}" 2>&1)

# 건너뜀 안내문에도 같은 낱말이 나온다. 제목 줄만 센다.
check "남은 일 목록을 보여준다"     1 "$(echo "$out" | grep -c '^아직 전사가 없는 녹음')"
check "전사 없는 녹음이 다 뜬다"     3 "$(echo "$out" | grep -cE '^  260820_(161055|182610|171533)  ')"
# 목록의 시각은 pair 에 그대로 넣는 열쇠다. 이름 안 번호가 아니라 진짜 시각이어야 한다.
check "이름에 든 번호를 시각으로 안 본다" 1 "$(echo "$out" | grep -c '^  260820_161055  통화 01075907672')"
check "짝 있는 녹음은 목록에 없다"   0 "$(echo "$out" | grep -c '260820_112710  ')"
check "시각 없는 것에 pair 를 안내"  1 "$(echo "$out" | grep -c 'transcripts pair')"
check "안내에 실제 경로가 들어간다"  1 "$(echo "$out" | grep -c '서류 제출 확인 및 대출 일정 문의 통화.txt\" <시각>')"
check "짐작해서 안 붙인다"           0 "$(ls "$CALLDIR"/*.txt 2>/dev/null | grep -vc '260820_112710' || true)"

P=(env CALL_ENABLED=1 CALL_DIRS="$CALLDIR" \
   "$SKILL/scripts/photo-autobackup.sh" transcripts pair)
DROPPED="$SHARED/Drop/서류 제출 확인 및 대출 일정 문의 통화.txt"

out=$(DRY_RUN=1 "${P[@]}" "$DROPPED" 260820_182610 2>&1)
check "pair 예행연습은 파일을 안 만든다" 0 "$([ -f "$CALLDIR/통화 현대카드_260820_182610.txt" ] && echo 1 || echo 0)"
check "pair 예행연습도 결과를 보여준다" 1 "$(echo "$out" | grep -c 'DRY-RUN')"

out=$("${P[@]}" "$DROPPED" 260820_182610 2>&1)
check "pair 가 시각만으로 붙인다"    1 "$([ -f "$CALLDIR/통화 현대카드_260820_182610.txt" ] && echo 1 || echo 0)"
check "pair 가 내용을 보존한다"      1 "$(grep -c '서류 제출 확인 내용' "$CALLDIR/통화 현대카드_260820_182610.txt")"
check "pair 도 원본을 남긴다"        1 "$([ -f "$DROPPED" ] && echo 1 || echo 0)"

# 이미 짝이 있는 녹음에 또 붙이면 어느 쪽이 맞는지 알 길이 없다. 막는다.
out=$("${P[@]}" "$DROPPED" 260820_112710 2>&1); rc=$?
check "pair 가 이미 있는 짝을 안 덮는다" 1 "$(echo "$out" | grep -c '덮지 않는다')"
check "그때 실패로 끝난다"           1 "$([ "$rc" != "0" ] && echo 1 || echo 0)"
check "기존 전사는 그대로다"         1 "$(grep -c '이미있음' "$CALLDIR/통화 01033334444_260820_112710.txt")"

out=$("${P[@]}" "$DROPPED" 991231_235959 2>&1); rc=$?
check "없는 시각은 실패한다"         1 "$([ "$rc" != "0" ] && echo 1 || echo 0)"
check "그때 아무 파일도 안 만든다"   2 "$(ls "$CALLDIR"/*.txt 2>/dev/null | wc -l | tr -d ' ')"
out=$("${P[@]}" "$DROPPED" 아무거나 2>&1)
check "시각 꼴이 아니면 거른다"      1 "$(echo "$out" | grep -c '시각(YYMMDD_HHMMSS) 꼴도 아니다')"

# --upload 는 이어서 calls 까지 간다. 옵션이 없으면 안 간다.
printf '전사 260820_161055' > "$SHARED/Drop/통화 260820_161055.txt"
out=$("${T[@]}" 2>&1)
check "옵션 없으면 calls 를 안 돈다" 0 "$(echo "$out" | grep -c '통화녹취 스윕 시작')"
rm -f "$CALLDIR/통화 01075907672_260820_161055.txt"
printf '전사 260820_171533' > "$SHARED/Drop/통화 260820_171533.txt"
out=$(env CALL_ENABLED=1 CALL_DIRS="$CALLDIR" TRANSCRIPT_DROP_DIRS="$SHARED/Drop" \
      "$SKILL/scripts/photo-autobackup.sh" transcripts --upload 2>&1)
check "--upload 는 calls 까지 간다"  1 "$(echo "$out" | grep -c '통화녹취 스윕 시작')"
check "--upload 가 전사를 올린다"    1 "$(find "$ROOT/remote" -name '음성 메시지 01075907672_260820_171533.txt' | wc -l | tr -d ' ')"

# 목록이 길면 잘라내되, 잘라냈다는 사실과 총 건수를 숨기지 않는다.
rm -rf "$SHARED/Recordings" "$SHARED/Drop"; mkdir -p "$CALLDIR" "$SHARED/Drop"
for i in 01 02 03 04 05 06 07 08 09 10 11 12; do
  printf 'x' > "$CALLDIR/통화 01011112222_260820_1010${i}.m4a"
done
out=$("${T[@]}" 2>&1)
check "열 건까지만 보여준다"         10 "$(echo "$out" | grep -cE '^  260820_1010[0-9]{2}  ')"
check "잘라낸 것을 밝힌다"           1 "$(echo "$out" | grep -c '그 밖에 2건 더 (모두 12건)')"

rm -rf "$SHARED/Recordings" "$SHARED/Drop"
"$SKILL/scripts/photo-autobackup.sh" reset-failures >/dev/null 2>&1

echo
echo "합계: PASS=$pass FAIL=$fail"
rm -rf "$ROOT"
[ "$fail" = "0" ]
