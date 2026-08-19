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
| `Continue using the shared client_id anyway?` | `y` (rclone 1.75+ 에서만 나온다. 아래 참고) |
| `Use auto config?` | **`y`** ← 폰에서 인증할 때는 y (아래 설명) |
| `Configure this as a Shared Drive?` | `n` |
| `y/e/d>` | `y` (저장) |

**scope 고르기**: `3` (drive.file)이 안전하다. rclone이 자기가 올린 파일만 볼 수 있어서
사고로 다른 드라이브 파일을 건드릴 수 없다. 다만 나중에 웹에서 폴더를 옮기면
rclone이 그 파일을 못 찾게 된다. 드라이브 전체를 rclone으로 관리할 생각이면 `1`.

### auto config 는 y 다 — 여기서 많이 틀린다

일반적인 안내문에는 "헤드리스 서버에서는 n"이라고 적혀 있어서 폰에서도 n을 고르기 쉽다.
하지만 폰은 **브라우저가 같은 기기 안에 있다.** 그래서 y가 맞다.

`y`를 고르면 rclone이 로컬에 임시 서버를 띄우고 이런 주소를 찍어 준다:

```
If your browser doesn't open automatically go to the following link:
    http://127.0.0.1:53682/auth?state=...
```

그 주소를 **길게 눌러 복사** → 폰 브라우저에 붙여넣기 → 구글 로그인 → 권한 허용.
같은 기기이므로 127.0.0.1로 접속되고, 로그인이 끝나면 Termux 쪽이 토큰을 자동으로 받는다.

`n`을 고르면 대신 이런 안내가 나온다:

```
Execute the following on the machine with the web browser:
    rclone authorize "drive"
Then paste the result below:
```

이 경로는 **rclone이 깔린 PC가 따로 있을 때**만 쓴다. PC에서 `rclone authorize "drive"`를
실행해 나온 긴 토큰 문자열을 폰 Termux에 붙여넣는 방식이다. 폰만 쓸 거라면 y로 가라.

확인:

```sh
rclone listremotes          # gdrive: 가 나와야 한다
rclone lsd gdrive:          # 드라이브 최상위 폴더 목록이 나와야 한다
```

### 공용 client_id 종료 예고

rclone 1.75 부터 이런 경고가 나온다:

```
rclone's shared Google Drive client_id is being retired and will stop working during 2026.
Continue using the shared client_id anyway? y/n>
```

지금은 `y` 로 넘어가면 그대로 동작한다. 다만 이름 그대로 언젠가 끊기므로, 그때는
아래 '자체 client_id' 절차를 밟아야 한다. 끊겼을 때의 증상은 인증 실패이지
사진 유실이 아니다 — 검증을 통과하지 못하면 원본을 지우지 않기 때문이다.

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
