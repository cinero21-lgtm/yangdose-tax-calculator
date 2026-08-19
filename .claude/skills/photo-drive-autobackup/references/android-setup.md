# 안드로이드 설치 상세

전체 15~20분 정도 걸린다. 4단계(구글 계정 인증)만 사람이 직접 해야 하고 나머지는
스크립트가 처리한다.

## 1. Termux 설치 — F-Droid에서 받아야 한다

플레이스토어의 Termux는 2020년에 업데이트가 끊긴 버전이라 `pkg install`이 깨진다.
반드시 아래에서 받아라.

- Termux 본체: https://f-droid.org/packages/com.termux/
- Termux:Boot: https://f-droid.org/packages/com.termux.boot/ (재부팅 후 자동 실행용)
- Termux:API: https://f-droid.org/packages/com.termux.api/ (갤러리 색인 갱신용)

세 앱은 **같은 서명**이어야 한다. 즉 셋 다 F-Droid에서 받아라. 하나라도 플레이스토어
버전이 섞이면 설치가 거부되거나 연동이 안 된다.

설치 후 Termux를 열고:

```sh
pkg update && pkg upgrade -y
```

## 2. 저장소 권한

```sh
termux-setup-storage
```

팝업에서 '허용'. 그러면 `~/storage/dcim`, `~/storage/pictures` 같은 링크가 생긴다.

**안드로이드 11 이상은 이것만으로 삭제가 안 될 수 있다.** 읽기·쓰기는 되는데 `rm`이
`Permission denied`로 떨어지면:

설정 → 앱 → Termux → 권한 → 파일 및 미디어 → **'모든 파일 관리 허용'**

기기에 따라 '모든 파일 접근 허용', 'Allow management of all files'로 표기된다.
이 스킬은 삭제가 목적이므로 이 권한이 없으면 반쪽짜리로 돈다.

## 3. 배터리 최적화 제외

이걸 안 하면 화면을 끄고 몇 분 뒤 감시가 멈춘다.

설정 → 앱 → Termux → 배터리 → **'제한 없음'** (삼성은 '앱 절전 안 함',
설정 → 배터리 → 백그라운드 사용 제한 → 절대 잠자기 앱에 Termux 추가)

## 4. rclone으로 구글드라이브 연결

```sh
pkg install -y rclone
rclone config
```

대화형으로 물어보는 것에 이렇게 답한다:

| 질문 | 답 |
|---|---|
| `n/s/q>` | `n` (새 리모트) |
| `name>` | `gdrive` |
| `Storage>` | 목록에서 `drive` 번호 (또는 `drive` 입력) |
| `client_id>` | 그냥 엔터 — 다만 아래 '속도 주의' 참고 |
| `client_secret>` | 엔터 |
| `scope>` | `1` (Full access) 또는 `3` (drive.file — 이 앱이 만든 파일만) |
| `service_account_file>` | 엔터 |
| `Edit advanced config?` | `n` |
| `Use auto config?` | **`n`** ← 폰에는 브라우저 자동 연동이 안 되므로 반드시 n |
| `Configure this as a Shared Drive?` | `n` |
| `y/e/d>` | `y` (저장) |

**scope 고르기**: `3` (drive.file)이 안전하다. rclone이 자기가 올린 파일만 볼 수 있어서
사고로 다른 드라이브 파일을 건드릴 수 없다. 다만 나중에 웹에서 폴더를 옮기면
rclone이 그 파일을 못 찾게 된다. 드라이브 전체를 rclone으로 관리할 생각이면 `1`.

`Use auto config? n`을 고르면 이런 안내가 뜬다:

```
Execute the following on the machine with the web browser:
    rclone authorize "drive"
Then paste the result below:
```

**PC(윈도우/맥)에서** rclone을 받아 `rclone authorize "drive"`를 실행하면 브라우저가
열리고, 구글 로그인 후 터미널에 긴 토큰 문자열이 찍힌다. 그걸 통째로 복사해서 폰
Termux에 붙여넣으면 끝이다.

PC가 없다면 폰에서 그대로 진행해도 된다. `rclone authorize "drive"`를 Termux에서 실행하면
`http://127.0.0.1:53682/auth?...` 주소가 뜨는데, 그 주소를 폰 브라우저에 붙여넣어 로그인하면
Termux 쪽에서 토큰을 받아 간다.

확인:

```sh
rclone listremotes          # gdrive: 가 나와야 한다
rclone lsd gdrive:          # 드라이브 최상위 폴더 목록이 나와야 한다
```

### 속도 주의 — 자체 client_id

client_id를 비워 두면 rclone 공용 키를 쓰는데, 이건 전 세계 사용자가 나눠 쓰는 할당량이라
사진이 많으면 눈에 띄게 느리고 가끔 `rateLimitExceeded`가 난다. 수천 장을 올릴 계획이면
구글 클라우드 콘솔에서 개인 OAuth client ID를 만들어 넣는 게 훨씬 빠르다
(공식 안내: https://rclone.org/drive/#making-your-own-client-id).

## 5. 설치 스크립트 실행

이 스킬의 `scripts/` 폴더를 폰으로 옮겨야 한다. 셋 중 편한 방법으로:

```sh
# (a) 깃 저장소에 있다면
pkg install -y git
git clone <저장소 주소> ~/skill && bash ~/skill/.claude/skills/photo-drive-autobackup/scripts/install.sh

# (b) 파일 두 개만 옮기는 경우 — 다운로드 폴더에 넣어 두고
bash ~/storage/downloads/install.sh

# (c) 직접 붙여넣기 — Termux에서 `cat > photo-autobackup.sh` 후 붙여넣고 Ctrl+D
```

install.sh는 여러 번 실행해도 안전하다. 이미 있는 설정 파일은 덮어쓰지 않는다.

## 6. 마무리 점검

```sh
~/bin/photo-autobackup.sh doctor      # 전부 [OK] 인지
~/bin/photo-autobackup.sh once        # DRY_RUN=1 상태로 먼저
~/bin/photo-autobackup.sh status      # 무엇이 대기 중인지
```

예행연습 결과가 납득되면 `~/.config/photo-autobackup/config.env`에서 `DRY_RUN=0`으로
바꾸고 `watch`로 띄운다. Termux:Boot 앱을 한 번 열어 두면 재부팅 후에도 자동으로 뜬다.
