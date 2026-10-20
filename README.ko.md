# away-signal

[English](README.md) | 한국어 | [日本語](README.ja.md) | [繁體中文](README.zh-TW.md)

![away-signal: prefix+a로 머신을 자리 비움으로 표시하면, 일을 마친 에이전트가 웹훅으로 바로 봇에게 전달돼요](docs/away-signal.gif)

자리를 비울 때 쓰는 [Herdr](https://herdr.dev) 플러그인이에요. 키 하나로 자리 비움(away) 모드를 켜고 꺼요. 켜져 있는 동안 에이전트가 작업을 마치거나 답을 기다리면 웹훅으로 POST를 보내요. 그래서 여러 머신을 지켜보는 오케스트레이터가 Herdr를 폴링하지 않고 신호를 받을 수 있어요.

- **자리 비움 모드**: 머신마다 플래그 파일 하나예요. 키로 이 파일을 켜고 끄고, 새 상태를 웹훅으로 보내고, Herdr 알림으로도 보여 줘요.
- **에이전트 신호**: 자리 비움 모드가 켜져 있을 때만 보내요. 에이전트가 답을 기다릴 때(`blocked`), 또는 작업을 마쳤을 때(`working` 다음 `done`이나 `idle`)예요. 그 상태가 60초 동안 그대로여야 하고, 보내기 직전에 Herdr에서 상태를 다시 읽어요. 그래서 작업 중에 잠깐 멈춘 건 보내지 않아요. 같은 페인의 같은 상태는 10분 안에 다시 보내지 않아요.
- **dry run**: 웹훅 URL이 없거나 `dry_run = true`면 아무것도 보내지 않고 로그에만 적어요.

Herdr 0.9.5 이상, bash, curl, jq가 필요해요.

## 봇을 위한 플러그인

JSON POST를 받는 서비스라면 어디든 이 신호를 받을 수 있어요. 하지만 이 플러그인은 처음부터 **봇에게 자리 비움 신호를 주려고** 만들었어요. Grok Bot이나 dots처럼 내 Herdr 머신을 대신 돌봐 주는 채팅 봇·에이전트 오케스트레이터는 두 가지를 알아야 해요. 내가 지금 자리에 있는지, 그리고 에이전트가 언제 일을 끝냈거나 막혔는지예요. away-signal을 쓰면 봇이 SSH로 Herdr를 폴링하지 않아도 이 두 가지를 바로 받아요.

1. 자리를 뜨며 켜기 키를 누르면, 봇은 내가 자리를 비웠다는 걸 알게 돼요(`{"type":"away","on":true}`). 그때부터 질문을 휴대폰으로 넘겨주거나 일을 이어서 할 수 있어요.
2. 자리를 비운 동안 일을 마쳤거나 기다리는 에이전트가 하나씩 신호로 와요. 페인, 에이전트, 제목, 폴더가 함께 와서 봇이 어디를 봐야 할지 알 수 있어요.
3. 돌아와서 끄기 키를 누르면 봇은 손을 떼요.

자리 비움 모드는 머신마다 따로 있고, 모든 신호에 어느 머신인지가 적혀 있어요. 그래서 봇은 머신을 하나씩 따로 돌볼 수 있어요. 예를 들어 떠나 온 머신의 에이전트는 봇이 맡고, 다른 머신에서는 내가 계속 일할 수 있어요. 여러 머신을 한꺼번에 맞추고 싶다면 봇이 SSH로 [플래그 파일](#플래그-파일)을 만들거나 지우면 돼요.

## Herdrbot

[Herdrbot](https://x.ai/bot/_919WifLAy2hWk7R7juy-)은 Herdr 에이전트를 SSH로 지휘하는 완성된 Grok Bot이에요. 이 플러그인도 원래 Herdrbot을 위해 만들었어요.

1. **추가하기**: Grok Bot 앱에서 [링크](https://x.ai/bot/_919WifLAy2hWk7R7juy-)로 추가해요. 짧은 설정 대화가 한 번에 하나씩 질문하며 이어져요.
2. **접속 허용**: 에이전트가 도는 계정마다 Herdr를 설치해요. Herdrbot이 자기 SSH 키를 만들고 공개 키만 보여 주면, 그 계정의 `~/.ssh/authorized_keys`에 넣어요. 비밀번호나 개인 키는 절대 묻지 않아요.
3. **계정 등록**: Herdrbot이 각 계정을 짧은 라벨의 Herdr 머신으로 등록하고(`herdr machine add`), 30분 점검과 아침 요약을 설정해요.
4. **일 맡기기**: 채팅으로 무엇을 만들거나 고칠지, 어느 머신·저장소인지 말해요. `hb-...` 이름의 에이전트를 띄우거나(또는 지정한 에이전트를 재사용해) 지켜보고 결과를 알려 줘요. 승인 창에 대신 답하지 않고, merge·배포·강제 push·삭제는 항상 먼저 물어봐요.
5. **선택: 이 플러그인**: Herdrbot에게 자리 비움 신호 설정을 부탁하면 "Herdr signal"이라는 웹훅 루틴을 만들어요. 그 루틴의 웹훅 URL과 key를 각 머신의 `away-signal.conf`(`url`, `key`)에 넣고, `machine`은 Herdrbot이 그 계정에 쓰는 라벨로 맞춘 다음, [키 바인딩](#키-바인딩)을 추가하세요. 플러그인이 없어도 Herdrbot은 30분 점검으로 동작해요.

## 설치

```sh
herdr plugin install devicki/herdr-away-signal --ref v0.4.0 --yes
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
| `sleep_hours` | 없음 | 예: `23:00-07:00`. 자는 동안 자리 비움을 자동으로 켬([아래](#취침-시간)) |
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
command = "devicki.away-signal.on"
description = "자리 비움 켜기"

[[keys.command]]
key = "prefix+shift+a"
type = "plugin_action"
command = "devicki.away-signal.off"
description = "자리 비움 끄기"
```

떠날 때 누르는 키와 돌아와서 누르는 키가 따로예요. 같은 키를 또 눌러도 상태가 그대로라서, 플래그가 어긋난 머신이 반대로 뒤집히는 일이 없어요. 키 하나로 쓰고 싶다면 `devicki.away-signal.toggle`도 있어요. 두 키 모두 Herdr 0.9.5 기본 키와 겹치지 않아요. 내 설정에서 이미 쓰고 있다면 다른 키를 고르세요.

## 취침 시간

```
sleep_hours = 23:00-07:00
```

취침 시간이 시작되면 자리 비움이 저절로 켜지고, 봇에게도 평소처럼 자리 비움 신호가 가요. 취침 시간이 끝나면 다시 꺼지는데, 취침 시간이 켠 경우에만 꺼요. 자기 전에 직접 켠 자리 비움은 그대로 켜져 있어요. 그 사이에 키를 누르면 다음 시작이나 끝까지 키가 우선이라, 늦게까지 일하려고 끄면 그날 밤은 꺼진 채로 있어요. 시간은 이 머신의 현지 시간이고 자정을 넘겨도 돼요. 머신마다 따로 정해요. 플러그인은 에이전트 상태가 바뀔 때마다 확인하고, 다음 시작·끝 시각에 맞춰 깨어나는 작은 대기 프로세스를 하나 띄워 둬요. 범위를 고치면 15분 안에 반영돼요.

## 사이드바 표시

자리 비움이 켜져 있으면 머신마다 맨 위 작업 공간 한 줄에 `away` 토큰(🌙 away)이 붙어요. 머신당 한 줄이라 어느 머신이 자리 비움인지 한눈에 보여요. 토큰은 사이드바 줄에 넣어야 보여요. 아래는 Herdr 기본 작업 공간 줄에 토큰을 더한 것이에요. `~/.config/herdr/config.toml`에 넣으세요.

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace", "$away"],
  ["branch", "git_status"],
]
```

이미 `rows`를 바꿔 쓰고 있다면 원하는 줄에 `"$away"`만 더하세요. 노트북에서 원격 머신에 붙어 쓴다면 사이드바는 노트북이 그리므로 노트북 설정에 넣어야 해요. SSH로 플래그를 바꾼 경우에는 다음에 에이전트 상태가 바뀔 때 표시가 따라와요.

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

실제 봇으로도 처음부터 끝까지 확인했어요(Herdr 0.9.5, Linux). 자리 비움 신호, 작업을 마친 에이전트(`idle`), Claude Code 폴더 신뢰 확인 창에서 멈춘 에이전트(`blocked`)가 모두 들어왔고, 뒤의 둘은 60초 재확인을 거친 뒤 왔어요.

웹훅이 아직 없을 때 손으로 확인하려면: 플러그인을 링크하고 키를 누른 다음, 에이전트가 작업을 마치는 동안 로그를 지켜보세요.

```sh
tail -f ~/.local/state/herdr/plugins/devicki.away-signal/away-signal.log
```

해 볼 때는 `delay = 5`로 두면 1분을 기다리지 않아도 돼요.

릴리스할 때는 `herdr-plugin.toml`의 `version`을 올리고, 모든 README의 `--ref`를 바꿔 커밋한 뒤 `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`를 실행하세요.

## 라이선스

MIT
