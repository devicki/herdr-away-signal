# away-signal

[English](README.md) | 한국어

자리를 비울 때 쓰는 [Herdr](https://herdr.dev) 플러그인이에요. 키 하나로 자리 비움(away) 모드를 켜고 꺼요. 켜져 있는 동안 에이전트가 작업을 마치거나 답을 기다리면 웹훅으로 POST를 보내요. 그래서 여러 머신을 지켜보는 오케스트레이터가 Herdr를 폴링하지 않고 신호를 받을 수 있어요.

- **자리 비움 모드**: 머신마다 플래그 파일 하나예요. 키를 누르면 이 파일을 켜고 끄고, 새 상태를 웹훅으로 보내고, Herdr 알림으로도 보여 줘요.
- **에이전트 신호**: 자리 비움 모드가 켜져 있을 때만 보내요. 에이전트가 답을 기다릴 때(`blocked`), 또는 작업을 마쳤을 때(`working` 다음 `done`이나 `idle`)예요. 그 상태가 60초 동안 그대로여야 하고, 보내기 직전에 Herdr에서 상태를 다시 읽어요. 그래서 작업 중에 잠깐 멈춘 건 보내지 않아요. 같은 페인의 같은 상태는 10분 안에 다시 보내지 않아요.
- **dry run**: 웹훅 URL이 없거나 `dry_run = true`면 아무것도 보내지 않고 로그에만 적어요.

Herdr 0.9.5 이상, bash, curl, jq가 필요해요.

## 설치

```sh
herdr plugin install devicki/herdr-away-signal --ref v0.1.0 --yes
```

`--ref`는 릴리스를 고정해요. 설정 파일 틀은 에이전트 상태가 처음 바뀌거나 키를 처음 누를 때, 또는 다음에 Herdr 서버가 시작될 때 만들어져요.

## 설정

플러그인 설정 폴더(`herdr plugin config-dir devicki.away-signal`, 보통 `~/.config/herdr/plugins/config/devicki.away-signal/`)의 `away-signal.conf`예요. 비밀값이 들어가는 파일이라 본인만 읽을 수 있게 만들어져요. 모든 설정은 [`away-signal.conf.example`](away-signal.conf.example)에 있어요.

| 키 | 기본값 | |
|---|---|---|
| `url` | 없음 | 웹훅 주소. 없으면 모든 신호가 dry run |
| `key` | 없음 | `Authorization: Bearer <key>`로 보냄 |
| `dry_run` | `false` | `true`면 보내지 않고 로그에만 적음 |
| `machine` | 짧은 호스트 이름 | 신호에 넣을 이 머신의 이름 |
| `delay` | `60` | 보내기 전에 상태가 유지돼야 하는 초 |
| `repeat` | `600` | 같은 페인·상태를 다시 보내기까지의 초 |

요청은 모두 `Content-Type: application/json` POST예요.

```json
{"type":"away","on":true,"machine":"laptop"}
{"type":"agent","machine":"laptop","pane_id":"w1:p2","agent":"claude","status":"blocked","title":"fix the login test","cwd":"/home/me/shop"}
```

`status`는 `blocked`, `done`(안 보는 사이 끝난 작업), `idle`(보는 중에 끝난 작업) 중 하나예요. `title`은 페인의 터미널 제목이에요.

## 키 바인딩

플러그인은 키를 직접 정할 수 없어요. `~/.config/herdr/config.toml`에 아래를 넣고 `herdr server reload-config`를 실행하세요.

```toml
[[keys.command]]
key = "prefix+a"
type = "plugin_action"
command = "devicki.away-signal.toggle"
description = "자리 비움 켜기/끄기"
```

`prefix+a`는 Herdr 0.9.5 기본 키와 겹치지 않아요. 내 설정에서 이미 쓰고 있다면 다른 키를 고르세요.

## 플래그 파일

이 파일이 있으면 자리 비움 모드가 켜진 거예요.

```
~/.local/state/herdr/plugins/devicki.away-signal/away
```

머신과 계정마다 따로 있어요. 여러 곳을 맞추려면 SSH 등으로 파일을 직접 만들거나 지우세요(`touch <경로>`, `rm -f <경로>`). 어느 셸(fish 포함)에서나 되고, 이때는 아무것도 보내지 않아요. 플러그인은 상태가 바뀔 때마다, 그리고 보내기 직전에 다시 플래그를 읽어요.

셸에서는:

```sh
bash away-signal.sh on | off | toggle   # 키와 같음: 플래그, 웹훅, Herdr 알림
bash away-signal.sh status              # on 또는 off
```

## 로그

`~/.local/state/herdr/plugins/devicki.away-signal/away-signal.log`에 모든 신호가 `sent`, `FAILED`, `dry-run` 표시와 함께 남아요. 실패하면 curl 오류도 같이 남아요. 키는 절대 적히지 않아요. 마지막 500~1,000줄만 보관해요.

## 테스트

```sh
herdr plugin link .   # 위 설치 대신, 저장소를 받은 폴더에서
./test.sh
```

격리된 Herdr(자체 HOME, 이 플러그인만 링크)와 localhost의 가짜 웹훅을 띄워서, 토글 액션, `pane.agent_status_changed` 훅, 지연·반복 규칙, 요청 헤더, dry run, 설정 파일 틀을 확인해요. 쓰고 있는 Herdr 서버는 건드리지 않아요.

웹훅이 아직 없을 때 손으로 확인하려면: 플러그인을 링크하고 키를 누른 다음, 에이전트가 작업을 마치는 동안 로그를 지켜보세요.

```sh
tail -f ~/.local/state/herdr/plugins/devicki.away-signal/away-signal.log
```

해 볼 때는 `delay = 5`로 두면 1분을 기다리지 않아도 돼요.

릴리스할 때는 `herdr-plugin.toml`의 `version`을 올리고, 모든 README의 `--ref`를 바꿔 커밋한 뒤 `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`를 실행하세요.

## 라이선스

MIT
