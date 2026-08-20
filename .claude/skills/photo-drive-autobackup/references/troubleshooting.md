# 증상별 해결

먼저 `photo-autobackup.sh doctor`와 로그(`~/.local/share/photo-autobackup/autobackup.log`)
부터 확인해라. 대부분 여기에 원인이 그대로 찍혀 있다.

## 업로드는 되는데 폰에서 안 지워진다

로그에 `휴지통 이동 실패(저장소 권한 확인 필요)`.

안드로이드 11+ 스코프드 스토리지 때문이다. 설정 → 앱 → Termux → 권한 → 파일 및 미디어
→ '모든 파일 관리 허용'을 켜라. 켠 뒤 `doctor`의 "감시 폴더 쓰기 가능"이 [OK]로 바뀌면 된다.

## 갤러리에 사진이 아직 보인다 (열면 없다고 뜬다)

MediaStore 색인이 안 지워진 것이다. `termux-api` 패키지와 Termux:API **앱**이 둘 다
있어야 `termux-media-scan`이 동작한다. 앱은 F-Droid에서, 패키지는 `pkg install termux-api`.

임시로는 갤러리 앱 캐시를 지우거나 재부팅해도 사라진다.

## 화면 끄면 멈춘다

1. 배터리 최적화에서 Termux 제외 (android-setup.md 3번)
2. `watch`는 자동으로 `termux-wake-lock`을 잡지만, Termux 알림에 'wake lock held'가
   떠 있는지 확인해라. 안 떠 있으면 `pkg install termux-api` 후 다시 띄워라.
3. 그래도 불안하면 `watch` 대신 크론으로 주기 실행하는 쪽이 견고하다:
   ```sh
   pkg install -y cronie termux-services
   sv-enable crond
   crontab -e     # 15분마다:  */15 * * * * $HOME/bin/photo-autobackup.sh once
   ```

## `photo-autobackup.sh: command not found`

설치는 됐는데 셸이 못 찾는 것이다. 먼저 전체 경로로 되는지 본다:

```sh
~/bin/photo-autobackup.sh status
```

이게 되면 PATH 문제다. `$PREFIX/bin` 에 링크를 걸면 셸 설정과 무관하게 항상 잡힌다:

```sh
ln -sf ~/bin/photo-autobackup.sh $PREFIX/bin/photo-autobackup.sh
```

`~/.bashrc` 에 `export PATH` 를 넣는 방식은 믿을 게 못 된다. Termux 가 로그인 셸로
뜨면 `~/.bash_profile` 이나 `~/.profile` 만 읽고 `.bashrc` 를 건너뛰어서, 처음엔
되다가 앱을 껐다 켜면 다시 안 되는 일이 생긴다. 실기기에서 그렇게 재발했다.

## 폰에서 긴 명령을 붙여넣기 어렵다

Termux 에는 붙여넣기 버튼이 없다. **검은 화면 가운데를 1초쯤 꾹 누르면** COPY /
PASTE / More 메뉴가 뜬다. 보조키 줄(ESC·CTRL)이 아니라 그 위 터미널 영역이어야 한다.

| 상황 | 조작 |
|---|---|
| 키보드가 사라짐 | 볼륨 위 + K |
| 보조키 줄이 사라짐 | 볼륨 위 + Q |
| 물리 키보드 | Ctrl + Alt + V |

PASTE 항목이 아예 없으면 클립보드가 빈 것이다.

애초에 긴 URL 을 붙여넣지 않도록, 갱신은 스크립트가 스스로 한다:

```sh
photo-autobackup.sh update
```

받은 파일이 `bash -n` 을 통과하고 버전을 읽을 수 있을 때만 덮어쓴다. 받다 만
파일로 자기 자신을 덮어쓰면 도구가 통째로 죽기 때문이다. 이전본은 `.bak` 로 남는다.

## update 직후 이상한 오류가 쏟아진다 (v2.2.1 이전)

```
line 883: 사진이: command not found
line 884: dirs: unbound variable
[3/5] 설정 파일을 쓴다: ...     ← setup 을 부른 적도 없는데
```

v2.2.1 이전 `update` 는 **실행 중인 자기 자신을 같은 자리에 덮어썼다.** bash 는
스크립트를 한 번에 읽지 않고 실행하면서 이어 읽으므로, 내용이 그 자리에서 바뀌면
원래 바이트 위치부터 *새* 파일을 계속 읽는다. 그 지점이 함수 본문 한가운데면
조각들이 문맥 없이 실행되어 위 같은 오류가 난다.

**스크립트는 정상적으로 교체됐다.** 오류는 그 실행이 남긴 부스러기일 뿐이다.
다만 부스러기가 `setup` 조각까지 실행했다면 `config.env` 가 잘렸을 수 있으니
확인해라. 바로 옆에 `config.env.bak.<날짜>` 백업이 있다.

```sh
photo-autobackup.sh doctor      # 설정이 온전한지
photo-autobackup.sh setup "사진폴더" "동영상폴더"   # 깨졌으면 다시 생성
```

v2.2.1 부터는 임시 파일에 받아 `mv` 로 교체한다. rename 은 새 inode 를 붙이므로
실행 중인 프로세스는 열어 둔 옛 내용을 끝까지 안전하게 읽는다. 그래서 갱신한
실행은 **여전히 옛 버전으로 끝나고**, 새 버전은 다음 명령부터 적용된다.

## 무엇을 쳐도 반응이 없다 — 화면에 글자만 쌓인다 (v2.3.1 이전)

```
photo-autobackup.sh probe
========== 통화녹취 환경 조사 ==========
[1] ... [2] ...          ← 여기까지 찍고 멈춤
photo-autobackup.sh status    ← 실행이 안 되고 글자만 남음
echo hi                       ← 이것도
```

프롬프트(`~ $`)가 다시 안 나왔다면 **앞의 명령이 아직 살아 있다.** 그 명령이
터미널 입력을 전부 가져가므로, 그 뒤에 치는 것은 실행되지 않고 화면에 쌓이기만
한다. 파일이 깨진 것도, 셸이 죽은 것도 아니다.

원인은 `termux-call-log` 같은 **termux-api 명령**이다. Termux:API 동반 앱이
없거나 권한 대화상자에 답한 적이 없으면 응답 없이 영영 매달린다.

**빠져나오는 법: `Ctrl+C`** (Termux 키보드 줄의 `CTRL` 누르고 `C`). 프롬프트가
돌아오면 정상이다.

v2.3.1 부터는 모든 termux-api 호출에 10초 제한(`TAPI_TIMEOUT`)을 걸고 stdin 을
끊는다. 매달리는 대신 `[실패] 권한이 없다` 로 진단하고 넘어간다. 근본 해결은
Termux:API 앱 설치와 권한 허용이다 — `probe` 의 `[5]` 항목이 알려 준다.

## 명령이 아무 응답도 없다 (오류조차 안 나온다)

`status` 처럼 인터넷을 안 쓰고 바로 출력해야 할 명령까지 조용하면, 느린 게 아니라
**스크립트 파일에 실행할 내용이 없는 것**이다. 빈 파일을 실행하면 bash 는 오류도
없이 그냥 끝난다.

v2.2.1 이전 `update` 는 `cat "$tmp" > "$self"` 로 덮어썼는데, `>` 는 쓰기 **전에**
파일을 0바이트로 자른다. 그 사이에 프로세스가 끊기면(멈춘 줄 알고 Ctrl+C, 회선
끊김) 스크립트가 빈 채로 남는다. **빈 파일은 스스로를 고칠 수 없다** — `update`
를 부르려면 스크립트가 있어야 하기 때문이다.

### 1) 무엇이 문제인지 가른다

```sh
echo hi; ls -l ~/bin/photo-autobackup.sh
```

| 화면 | 판정 | 다음 |
|---|---|---|
| `hi` 조차 안 나옴 | Termux/터미널 문제 (스크립트 무관) | Termux 를 완전히 껐다 켠다 |
| `hi` + 크기 0 또는 수백 바이트 | 잘린 파일 | 2) 로 |
| `hi` + 5만 바이트 이상 | 파일은 온전 | 3) 으로 |

실체는 `~/bin/photo-autobackup.sh` 다. `$PREFIX/bin/` 쪽은 심볼릭 링크이므로
크기를 봐도 소용없다.

### 2) 되살린다

백업은 덮어쓰기 **전에** 만들어지므로 온전한 이전본이 남아 있다.

```sh
cp ~/bin/photo-autobackup.sh.bak ~/bin/photo-autobackup.sh && photo-autobackup.sh status
```

백업도 없으면 한 줄 설치(`bootstrap.sh`)로 다시 깐다. 재설치는 `config.env` 가
이미 있으면 덮어쓰지 않는다.

되살린 뒤 `update` 를 한 번 돌려 v2.2.2 이상으로 올려 두면 같은 사고는 재발하지
않는다. `mv` 로 교체하므로 중간에 끊겨도 옛 파일이 그대로 남는다.

### 3) 파일은 온전한데도 조용하다면

```sh
bash -x ~/bin/photo-autobackup.sh status 2>&1 | head -40
```

어디까지 갔는지 보인다. 대개 shebang 이 없는 bash 를 가리키거나, `config.env` 가
깨져 읽다가 죽거나, 상태 파일 잠금을 기다리는 경우다.

## 재부팅하면 자동으로 안 뜬다

Termux:Boot 앱은 설치만으로는 등록되지 않는다. **한 번 열어야** 부팅 수신이 활성화된다.
그리고 `~/.termux/boot/photo-autobackup.sh`에 실행 권한이 있어야 한다(`chmod +x`).

## `Failed to get md5` / 해시가 비어서 삭제가 보류된다

- 구글드라이브는 자기가 변환한 문서(구글 문서/시트)에는 MD5를 안 준다. 사진은 정상적으로
  준다. 사진에서 이게 나면 업로드가 실제로 안 끝난 것이다.
- 토큰 만료: `rclone config reconnect gdrive:`
- 이 상황에서 원본이 안 지워지는 건 **의도된 동작**이다. 검증 못 한 파일은 남긴다.

## 같은 사진이 드라이브에 두 번 올라간다

파일 이름이 같고 내용이 다르면 뒤 파일에 해시 앞 8자리를 붙여 따로 올린다
(`IMG_0001-3f2a9c11.jpg`). 여러 앱이 같은 이름을 쓰는 경우다. 내용까지 같으면
업로드를 건너뛰고 휴지통으로만 보내므로 중복이 생기지 않는다.

## 데이터 요금이 걱정된다

`config.env`에 대역폭 제한을 걸거나, Wi-Fi일 때만 돌게 한다.

```sh
RCLONE_EXTRA_ARGS="--bwlimit 1M --transfers 2"
```

Wi-Fi 전용으로 하려면 `watch` 대신 `once`를 쓰고, 크론 항목 앞에 조건을 붙인다:

```sh
*/15 * * * * [ "$(getprop wifi.interface >/dev/null; dumpsys wifi 2>/dev/null | grep -c 'Wi-Fi is enabled')" = 1 ] && $HOME/bin/photo-autobackup.sh once
```

(기기마다 판정 방법이 다르니, 간단하게는 `termux-wifi-connectioninfo` 출력에
`supplicant_state: COMPLETED`가 있는지 보는 쪽이 안정적이다.)

## 통화녹취가 안 올라간다

`CALL_ENABLED=1` 인지부터 본다(기본은 꺼짐). 그다음 `photo-autobackup.sh probe`.
증상별 대처는 `references/call-recordings.md` 의 문제 해결 표에 있다.

통화녹취는 **올려도 폰에서 지우지 않는다.** 폰 용량이 안 줄어드는 게 정상이다.

## 휴지통이 30일보다 빨리 비워졌다 (v2.0.0 이전)

v2.0.0 이전에는 보관 기간을 **사진을 찍은 날** 기준으로 셌다. `mv` 가 mtime 을
보존하기 때문인데, 그래서 한 달 넘은 사진은 휴지통에 넣자마자 완전삭제 대상이
됐다. 30일 복구 창구와 `restore` 가 사실상 없는 것과 같았다.

지금은 휴지통 파일 이름의 접두사(`YYYYmmdd-HHMMSS-`)를 **버린 시각**으로 읽는다.
접두사를 읽지 못하는 파일은 지우지 않는다 — 모를 때는 보존이 안전하다.

`photo-autobackup.sh update` 로 갱신해라. 이미 지워진 파일은 드라이브에 있다.

## 실수로 지운 걸 되돌리고 싶다

```sh
photo-autobackup.sh status                  # 휴지통에 몇 건 있는지
photo-autobackup.sh restore IMG_0042        # 이름 일부로 지정
photo-autobackup.sh restore all             # 전부 되돌리기
```

보관 기간(기본 30일)이 지나 `purge`된 것은 폰에서 복구할 수 없다. 다만 **드라이브에는
남아 있으므로** 거기서 내려받으면 된다 — 애초에 그게 이 자동화의 목적이다.
`manifest.tsv`에 드라이브 경로가 적혀 있다.

## 특정 파일만 계속 실패한다

5회 실패하면 재시도를 멈춘다(모바일 데이터 낭비 방지). 로그에서 원인을 찾아 고친 뒤:

```sh
photo-autobackup.sh reset-failures
```

파일 자체가 깨진 경우(0바이트, 촬영 중 앱 강제종료)는 지우고 넘어가는 게 맞다.

## 처음부터 다시 하고 싶다

```sh
pkill -f photo-autobackup            # 감시 중지
photo-autobackup.sh restore all      # 휴지통 되돌리기 (원하면)
rm -rf ~/.local/share/photo-autobackup ~/.config/photo-autobackup
rm -f ~/bin/photo-autobackup.sh ~/.termux/boot/photo-autobackup.sh
```

드라이브에 올라간 파일은 그대로 남는다.
