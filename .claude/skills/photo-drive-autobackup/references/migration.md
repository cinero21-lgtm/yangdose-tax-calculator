# 폰 사진 전량 이관 런북 (1회성)

"지금 폰에 있는 사진을 전부 드라이브로 옮기고 폰은 비운다"를 수행하는 절차다.
평상시 감시(`watch`)와 달리 한 번만 도는 작업이고, 다루는 양이 크기 때문에 순서를
지키는 게 중요하다.

## 이 작업이 실제로 무엇을 하는가

1. 폰 내부저장소(`$HOME/storage/shared`, 설정 시 SD카드까지) 전체에서 사진 파일을 찾는다
2. **무엇을 옮길지 계획을 먼저 보여 준다** — 건수, 총 용량, 폴더별 내역, 드라이브 여유 공간
3. 사용자가 `yes`를 입력해야 진행한다
4. 파일마다: 업로드 → 원격 MD5와 로컬 MD5 대조 → 일치할 때만 휴지통으로 이동
5. 끝나면 폰에 사진이 남았는지 자동으로 재확인한다

드라이브에는 **폰의 폴더 구조가 그대로 재현된다**:

```
Z폴드 8 사진/
├── DCIM/Camera/IMG_20260801_120000.jpg
├── Pictures/Screenshots/Screenshot_20260803.png
└── Pictures/카카오톡 받은 사진/photo_1.jpg
```

날짜별로 정리하고 싶으면 `MIGRATE_LAYOUT="date"`로 바꾼다.

## 무엇을 건드리지 않는가

전부 쓸어담으면 안 되는 것들이 있어서 아래는 의도적으로 제외한다. 이걸 올리면
드라이브가 쓰레기로 차고, 지우면 앱이 깨진다.

- `Android/data`, `Android/obb` — 앱 내부 저장 영역
- `.thumbnails`, `cache`, `Cache`, `.cache` — 썸네일·캐시
- `.`으로 시작하는 숨김 파일, `*.pending`, `*.trashed*` (안드로이드 삭제 대기 파일)

카카오톡·인스타그램이 **공유 저장소**(`Pictures/`, `DCIM/`)에 저장한 사진은 진짜
사진으로 보고 옮긴다. 앱 내부에만 있는 캐시 이미지는 건드리지 않는다.

## 순서

### 0. 준비 확인

```sh
photo-autobackup.sh doctor
```

전부 `[OK]`가 아니면 여기서 멈춰라. 특히 감시 폴더 쓰기 권한이 없으면 업로드만 되고
삭제가 전부 실패해서 시간과 데이터만 날린다.

### 1. 설정

`~/.config/photo-autobackup/config.env`:

```sh
DRIVE_FOLDER="Z폴드 8 사진"
MIGRATE_ROOTS="$HOME/storage/shared"
MIGRATE_LAYOUT="mirror"
REQUIRE_WIFI=1          # 수천 장이면 반드시 켜라
RCLONE_EXTRA_ARGS="--transfers 4 --tpslimit 8"
```

SD카드도 비우려면 경로를 확인해서 덧붙인다:

```sh
ls /storage        # 1A2B-3C4D 같은 이름이 SD카드다
MIGRATE_ROOTS="$HOME/storage/shared /storage/1A2B-3C4D"
```

### 2. 예행연습 — 이 단계를 건너뛰지 마라

```sh
# config.env 에 DRY_RUN=1
photo-autobackup.sh migrate
```

계획만 출력하고 끝난다. 여기서 확인할 것:

- **총 용량이 드라이브 여유 공간보다 작은가** — 넘으면 중간에 실패가 쏟아진다
- **의도하지 않은 폴더가 섞이지 않았나** — 예: 다운로드한 짤, 앱이 뿌린 배너 이미지.
  빼고 싶으면 `MIGRATE_ROOTS`를 좁히거나(`$HOME/storage/dcim` 만) 해당 파일을 먼저 지운다
- **건수가 상식적인가** — 갤러리 앱이 보여주는 장수와 크게 다르면 범위가 잘못된 것이다

### 3. 실행

`DRY_RUN=0`으로 되돌리고:

```sh
photo-autobackup.sh migrate
```

계획이 다시 뜨고 `yes`를 입력하면 시작한다. 25건마다 진행 상황이 로그에 찍힌다.

수천 장이면 몇 시간이 걸린다. 중간에 끊겨도 **그냥 다시 실행하면 된다** — 이미 옮긴
파일은 폰에서 사라졌으니 남은 것만 다시 훑는다. 화면을 끄고 오래 돌리려면
Termux 세션이 죽지 않게 배터리 최적화 제외를 먼저 확인해라.

무인으로 돌리려면(확인 프롬프트 생략):

```sh
nohup photo-autobackup.sh migrate --yes > ~/migrate.out 2>&1 &
tail -f ~/migrate.out
```

### 3-1. 끝난 걸 어떻게 아나

세 가지 중 아무거나 보면 된다.

| 방법 | 완료 신호 |
|---|---|
| 화면 | `일괄 이관 종료 — 성공 N건, 실패 M건` 뒤 프롬프트(`~ $`) 복귀 |
| `photo-autobackup.sh verify-empty` | `폰에 남은 사진이 없다` |
| `pgrep -af photo-autobackup` | 아무것도 안 나옴 |

termux-api 가 있으면 **끝날 때 폰 알림**이 뜬다. 몇 시간짜리 작업을 터미널만
쳐다보며 기다릴 이유가 없다. 실패나 잔여가 있으면 알림 제목이 '확인 필요'로 바뀐다.

### 4. 결과 확인

```sh
photo-autobackup.sh verify-empty
```

`남은 사진이 없다`가 나오면 끝이다. 남아 있다면 어디에 몇 건인지 같이 알려 준다.
남는 이유는 대개 셋 중 하나다:

| 이유 | 확인 방법 | 대처 |
|---|---|---|
| 업로드/검증 실패 | 로그에 `업로드 실패` 또는 `해시 불일치` | 원인 해결 후 `reset-failures` → `migrate` 재실행 |
| 삭제 권한 없음 | 로그에 `휴지통 이동 실패` | '모든 파일 접근 허용' 켜고 재실행 |
| 5회 실패로 중단 | `status`의 실패 추적 건수 | `reset-failures` 후 재실행 |

**남아 있는 게 정상인 경우도 있다.** 검증 못 한 파일을 일부러 남기는 게 이 도구의
설계다. 억지로 지우지 마라.

### 5. 이후 자동 유지

한 번 비운 뒤에는 새로 찍는 사진이 다시 쌓인다. 감시를 띄워 두면 자동으로 비워진다.

```sh
photo-autobackup.sh watch          # 또는 Termux:Boot로 부팅 시 자동 실행
```

이때는 `LAYOUT="date"`(월별 정리)가 보기 좋고, `MIGRATE_LAYOUT`은 이관용이라
감시 모드에 영향을 주지 않는다.

## 되돌리기

옮긴 사진은 30일간 폰 휴지통에 남는다.

```sh
photo-autobackup.sh status            # 휴지통 건수·용량
photo-autobackup.sh restore all       # 전부 원래 자리로
photo-autobackup.sh restore IMG_0042  # 이름 일부로 골라서
```

휴지통 용량이 부담되면(전량 이관이면 원본 전체 크기다) 확인이 끝난 뒤
`RETENTION_DAYS`를 줄이고 `purge`를 돌리면 즉시 공간이 확보된다. 드라이브에는
그대로 있으니 사진이 사라지는 게 아니다.

## 용량 계산이 안 맞을 때

폰 저장공간이 기대만큼 안 비었다면 휴지통이 아직 차 있는 것이다. 이관 직후에는
"드라이브에 사본 + 폰 휴지통에 원본"이라 총량이 그대로다. 확인이 끝나면:

```sh
photo-autobackup.sh status                     # 휴지통 용량 확인
# config.env 에서 RETENTION_DAYS=0 으로 바꾸고
photo-autobackup.sh purge
```
