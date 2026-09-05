#!/usr/bin/env bash
# Termux에 photo-autobackup을 설치한다. 여러 번 실행해도 안전하다(멱등).
set -uo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$HOME/bin"
CONFIG_DIR="$HOME/.config/photo-autobackup"
BOOT_DIR="$HOME/.termux/boot"

say() { printf '\n=== %s\n' "$*"; }

say "1/5 필요한 패키지 설치"
if command -v pkg >/dev/null 2>&1; then
  pkg install -y rclone termux-api inotify-tools coreutils findutils || \
    echo "  ! 일부 패키지 설치에 실패했다. 'pkg update' 후 다시 실행해 볼 것."
else
  echo "  ! Termux가 아닌 환경이다. rclone, inotify-tools를 직접 설치해야 한다."
fi

say "2/5 공유 저장소 접근 권한"
if [ -d "$HOME/storage/dcim" ]; then
  echo "  이미 연결되어 있다: $HOME/storage/dcim"
else
  echo "  termux-setup-storage 를 실행한다. 뜨는 팝업에서 '허용'을 눌러라."
  command -v termux-setup-storage >/dev/null 2>&1 && termux-setup-storage
  sleep 2
  [ -d "$HOME/storage/dcim" ] || echo "  ! 아직 연결되지 않았다. 권한을 허용한 뒤 이 스크립트를 다시 실행해라."
fi

say "3/5 스크립트 배치"
mkdir -p "$BIN_DIR"
install -m 755 "$SRC_DIR/photo-autobackup.sh" "$BIN_DIR/photo-autobackup.sh"

# 안드로이드에는 /usr/bin 이 없다. termux-exec 가 shebang 을 대신 고쳐 주긴 하지만
# 항상 켜져 있다고 믿을 수 없어서, 설치 시점에 실제 bash 경로로 박아 둔다.
REAL_BASH="$(command -v bash)"
if [ -n "$REAL_BASH" ] && [ "$REAL_BASH" != "/usr/bin/bash" ]; then
  sed -i "1s|^#!.*|#!$REAL_BASH|" "$BIN_DIR/photo-autobackup.sh"
  echo "  shebang 고정: $REAL_BASH"
fi
echo "  설치됨: $BIN_DIR/photo-autobackup.sh"

# $PREFIX/bin 은 Termux 가 항상 PATH 에 두므로, 링크가 가장 확실하다.
# .bashrc 에만 의존하면 로그인 셸에서 건너뛰어 재시작 후 command not found 가 난다.
if [ -n "${PREFIX:-}" ] && [ -w "$PREFIX/bin" ] && \
   ln -sf "$BIN_DIR/photo-autobackup.sh" "$PREFIX/bin/photo-autobackup.sh" 2>/dev/null; then
  echo "  링크됨: \$PREFIX/bin/photo-autobackup.sh (셸 재시작해도 항상 잡힌다)"
else
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    grep -qs 'photo-autobackup PATH' "$rc" 2>/dev/null || \
      printf '\n# photo-autobackup PATH\nexport PATH="$HOME/bin:$PATH"\n' >> "$rc"
  done
  export PATH="$BIN_DIR:$PATH"
  echo "  PATH 등록: ~/.bashrc, ~/.profile (새 터미널부터 적용)"
fi

say "4/5 설정 파일"
mkdir -p "$CONFIG_DIR"
if [ -f "$CONFIG_DIR/config.env" ]; then
  echo "  이미 있어서 건드리지 않았다: $CONFIG_DIR/config.env"
else
  cp "$SRC_DIR/config.example.env" "$CONFIG_DIR/config.env"
  echo "  생성됨: $CONFIG_DIR/config.env  (RCLONE_REMOTE / DRIVE_FOLDER 를 확인해라)"
fi

say "5/5 부팅 시 자동 실행"
mkdir -p "$BOOT_DIR"
cat > "$BOOT_DIR/photo-autobackup.sh" <<BOOT
#!${PREFIX:-/data/data/com.termux/files/usr}/bin/sh
termux-wake-lock
exec "\$HOME/bin/photo-autobackup.sh" watch
BOOT
chmod +x "$BOOT_DIR/photo-autobackup.sh"
echo "  등록됨: $BOOT_DIR/photo-autobackup.sh"
echo "  (Play스토어/F-Droid에서 'Termux:Boot' 앱을 설치하고 한 번 실행해야 부팅 시 동작한다)"

say "이어서 자동 설정을 실행한다"
"$BIN_DIR/photo-autobackup.sh" setup

cat <<'NEXT'

--- 이후 순서 ---
  안 되면 먼저:      ~/bin/photo-autobackup.sh setup        (다시 실행해도 안전)
  폰 사진 전량 이관: ~/bin/photo-autobackup.sh migrate      (계획 확인 후 yes)
  이후 자동 감시:    ~/bin/photo-autobackup.sh watch
NEXT
