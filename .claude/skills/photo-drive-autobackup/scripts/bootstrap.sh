#!/data/data/com.termux/files/usr/bin/bash
# Termux에서 한 줄로 설치한다. git도, 저장소 클론도 필요 없다.
#
#   curl -fsSL https://raw.githubusercontent.com/cinero21-lgtm/yangdose-tax-calculator/claude/auto-photo-upload-delete-4prnja/.claude/skills/photo-drive-autobackup/scripts/bootstrap.sh -o ~/pab.sh && bash ~/pab.sh
#
# 파이프(| bash)로 실행해도 되지만, 그 경우 아래 가드가 파일로 다시 받아 실행한다.
# 여러 번 실행해도 안전하다.

set -uo pipefail

# curl | bash 로 실행되면 stdin 이 곧 스크립트 본문이다. 중간에 stdin 을 읽는
# 명령(apt/pkg 등)이 하나라도 있으면 남은 본문을 삼켜서, 에러 없이 조용히
# 중간에 끝난다. 실기기에서 실제로 1/4 뒤 종료됐다.
# 파이프로 들어온 경우 자기 자신을 파일로 내려받아 다시 실행해 그 경로를 없앤다.
if [ ! -t 0 ] && [ -z "${PAB_RELAUNCHED:-}" ]; then
  _self="$HOME/.photo-autobackup-bootstrap.sh"
  if command -v curl >/dev/null 2>&1 && curl -fsSL \
      "https://raw.githubusercontent.com/cinero21-lgtm/yangdose-tax-calculator/claude/auto-photo-upload-delete-4prnja/.claude/skills/photo-drive-autobackup/scripts/bootstrap.sh" \
      -o "$_self" 2>/dev/null; then
    PAB_RELAUNCHED=1 exec bash "$_self"
  fi
fi

RAW="https://raw.githubusercontent.com/cinero21-lgtm/yangdose-tax-calculator/claude/auto-photo-upload-delete-4prnja/.claude/skills/photo-drive-autobackup/scripts"
BIN_DIR="$HOME/bin"

say() { printf '\n=== %s\n' "$*"; }
die() { printf '\n!! %s\n' "$*" >&2; exit 1; }

say "1/4 필요한 패키지 설치"
if ! command -v pkg >/dev/null 2>&1; then
  die "Termux가 아니다. Termux 앱 안에서 실행해라."
fi
# 진행 상황을 그대로 보여 준다. 감추면 몇 분간 빈 화면이라 멈춘 걸로 오해한다.
# 파이프를 쓰면 종료코드가 뒤쪽 명령 것이 되어 pkg 실패를 놓치므로 직접 실행한다.
echo "  rclone 등 약 50MB를 내려받는다. 2~5분 걸릴 수 있다."
if ! pkg install -y curl rclone termux-api inotify-tools coreutils findutils < /dev/null; then
  die "패키지 설치 실패. 플레이스토어판 Termux라면 지워야 한다 — F-Droid 버전을 설치해라:
     https://f-droid.org/packages/com.termux/
     저장소 문제라면 'termux-change-repo' 로 미러를 바꾼 뒤 다시 실행해라."
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

# 명령 이름만으로 부를 수 있게 만든다.
#
# ~/bin 은 Termux 기본 PATH 에 없다. .bashrc 에 export 를 넣는 방식은, Termux 가
# 로그인 셸로 뜨면 ~/.bash_profile/~/.profile 만 읽고 .bashrc 를 건너뛸 수 있어
# 재시작 후 'command not found' 로 되돌아간다(실기기에서 실제로 그랬다).
#
# $PREFIX/bin 은 Termux 가 언제나 PATH 에 두는 디렉터리다. 거기에 심볼릭 링크를
# 걸면 셸 설정과 무관하게 항상 잡힌다. 이게 1차 수단이고, PATH 등록은 보조다.
LINKED=0
if [ -n "${PREFIX:-}" ] && [ -d "$PREFIX/bin" ] && [ -w "$PREFIX/bin" ]; then
  if ln -sf "$BIN_DIR/photo-autobackup.sh" "$PREFIX/bin/photo-autobackup.sh" 2>/dev/null; then
    echo "  링크됨: \$PREFIX/bin/photo-autobackup.sh  (셸 재시작해도 항상 잡힌다)"
    LINKED=1
  fi
fi

# 링크가 안 된 환경을 위한 보조 경로. 로그인 셸도 읽도록 .profile 에도 넣는다.
if [ "$LINKED" = "0" ]; then
  for rc in "$HOME/.bashrc" "$HOME/.profile"; do
    grep -qs 'photo-autobackup PATH' "$rc" 2>/dev/null || \
      printf '\n# photo-autobackup PATH\nexport PATH="$HOME/bin:$PATH"\n' >> "$rc"
  done
  echo "  PATH 등록: ~/.bashrc, ~/.profile  (새 세션부터 적용)"
fi
export PATH="$BIN_DIR:$PATH"

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
