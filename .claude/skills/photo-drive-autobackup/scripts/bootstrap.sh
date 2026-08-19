#!/data/data/com.termux/files/usr/bin/bash
# Termux에서 한 줄로 설치한다. git도, 저장소 클론도 필요 없다.
#
#   curl -fsSL https://raw.githubusercontent.com/cinero21-lgtm/yangdose-tax-calculator/claude/auto-photo-upload-delete-4prnja/.claude/skills/photo-drive-autobackup/scripts/bootstrap.sh | bash
#
# 여러 번 실행해도 안전하다.

set -uo pipefail

RAW="https://raw.githubusercontent.com/cinero21-lgtm/yangdose-tax-calculator/claude/auto-photo-upload-delete-4prnja/.claude/skills/photo-drive-autobackup/scripts"
BIN_DIR="$HOME/bin"

say() { printf '\n=== %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

say "1/4 필요한 패키지 설치"
if ! command -v pkg >/dev/null 2>&1; then
  die "Termux가 아니다. Termux 앱 안에서 실행해라."
fi
# 플레이스토어판 Termux는 저장소가 끊겨 여기서 막힌다. 그 경우 바로 알려 준다.
if ! pkg install -y curl rclone termux-api inotify-tools coreutils findutils 2>&1 | tail -3; then
  die "패키지 설치 실패. 플레이스토어판 Termux라면 지워야 한다 — F-Droid 버전을 설치해라:
     https://f-droid.org/packages/com.termux/"
fi

say "2/4 스크립트 내려받기"
mkdir -p "$BIN_DIR"
if ! curl -fsSL "$RAW/photo-autobackup.sh" -o "$BIN_DIR/photo-autobackup.sh"; then
  die "내려받기 실패. 인터넷 연결을 확인해라."
fi
chmod 755 "$BIN_DIR/photo-autobackup.sh"
# 안드로이드에는 /usr/bin 이 없다. 실제 bash 경로를 shebang 에 박는다.
REAL_BASH="$(command -v bash)"
[ -n "$REAL_BASH" ] && sed -i "1s|^#!.*|#!$REAL_BASH|" "$BIN_DIR/photo-autobackup.sh"
echo "  설치됨: $BIN_DIR/photo-autobackup.sh"

# 명령 이름만으로 부를 수 있게 PATH 등록 (한 번만)
if ! printf '%s' "$PATH" | tr ':' '\n' | grep -qx "$BIN_DIR"; then
  grep -qs 'photo-autobackup PATH' "$HOME/.bashrc" 2>/dev/null || \
    printf '\n# photo-autobackup PATH\nexport PATH="$HOME/bin:$PATH"\n' >> "$HOME/.bashrc"
  export PATH="$BIN_DIR:$PATH"
fi

say "3/4 부팅 시 자동 실행 등록"
mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/photo-autobackup.sh" <<BOOT
#!${PREFIX:-/data/data/com.termux/files/usr}/bin/sh
termux-wake-lock
exec "\$HOME/bin/photo-autobackup.sh" watch
BOOT
chmod +x "$HOME/.termux/boot/photo-autobackup.sh"
echo "  등록됨 (Termux:Boot 앱을 한 번 열어야 실제로 동작한다)"

say "4/4 자동 설정 — 폰 상태를 읽어 스스로 맞춘다"
exec "$BIN_DIR/photo-autobackup.sh" setup
