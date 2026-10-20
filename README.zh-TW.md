# away-signal

[English](README.md) | [한국어](README.ko.md) | [日本語](README.ja.md) | 繁體中文

![away-signal：按 prefix+a 將機器設為暫離，完成工作的代理程式會立即透過 webhook 通知機器人](docs/away-signal.gif)

一個在你離開座位時使用的 [Herdr](https://herdr.dev) 外掛。按一個鍵就能開啟或關閉暫離模式。開啟期間，代理程式完成一輪工作或等待你回應時，外掛會向 webhook 送出 POST，讓監看你各台機器的協調器直接收到訊號，而不必輪詢 Herdr。

- **暫離模式**：每台機器一個旗標檔案。用按鍵開啟或關閉它、將新狀態 POST 到 webhook，並在 Herdr 中顯示。
- **代理程式訊號**：只在暫離模式開啟時送出，也就是代理程式在等你回應時（`blocked`），或完成一輪工作時（先 `working`，接著 `done` 或 `idle`）。該狀態必須維持 60 秒，送出前還會再向 Herdr 讀取一次，所以工作途中的短暫停頓絕不會被回報。同一個窗格的同一個狀態，10 分鐘內不會重複送出。
- **dry run**：沒有 webhook URL（或設定 `dry_run = true`）時不會送出任何東西，所有訊號改為寫入記錄檔。

需要 Herdr 0.9.5 以上版本、bash、curl 和 jq。

## 為機器人打造

任何能接收 JSON POST 的服務都能收到這些訊號，但這個外掛是為了一件事而做的：給機器人一個暫離訊號。像 Grok Bot 或 dots 這類替你照看 Herdr 機器的聊天機器人與代理程式協調器，需要知道兩件事：你是否在電腦前，以及代理程式何時完成或卡住。有了 away-signal，這兩件事會直接推送給它們，不必透過 SSH 輪詢 Herdr：

1. 離開時按下開啟鍵，機器人就會知道你暫離了（`{"type":"away","on":true}`），並可以接手：把問題轉到你的手機，或繼續進行工作。
2. 你暫離期間，每個完成或在等待的代理程式都會以一則訊號送達，附上窗格、代理程式、標題和資料夾，讓機器人知道該看哪裡。
3. 回來時按下關閉鍵，機器人就會退到一旁。

每台機器都有自己的暫離模式，每則訊號也都會標明來自哪台機器，所以機器人可以分別照看每一台：例如你離開的那台機器上的代理程式交給機器人，你在另一台機器上繼續工作。如果想讓多台機器保持一致，機器人可以透過 SSH 建立或刪除[旗標檔案](#旗標檔案)。

## Herdrbot

[Herdrbot](https://x.ai/bot/_919WifLAy2hWk7R7juy-) 是一個現成的 Grok Bot，透過 SSH 指揮你的 Herdr 代理程式；這個外掛最初也是為它打造的。

1. **加入**：在 Grok Bot 應用程式中透過[連結](https://x.ai/bot/_919WifLAy2hWk7R7juy-)加入。接著會有一段簡短的設定對話，一次問一個問題。
2. **允許連線**：在每個執行代理程式的帳號下安裝 Herdr。Herdrbot 會產生自己的 SSH 金鑰，只給你看公開金鑰；把它加到該帳號的 `~/.ssh/authorized_keys`。它絕不會要求密碼或私密金鑰。
3. **登錄帳號**：Herdrbot 會以簡短標籤把每個帳號登錄為 Herdr 機器（`herdr machine add`），並設定每 30 分鐘的巡查和早晨摘要。
4. **交付工作**：在聊天中說明要做或要修什麼，以及在哪台機器、哪個儲存庫。它會啟動名為 `hb-...` 的代理程式（或重用你指定的），持續關注並回報結果。它不會替你回答核准提示，merge、部署、強制 push 和刪除一定先問你。
5. **選用：這個外掛**：請 Herdrbot 設定暫離訊號，它會建立名為 "Herdr signal" 的 webhook 例行程序。把該例行程序的 webhook URL 和 key 填入每台機器的 `away-signal.conf`（`url`、`key`），將 `machine` 設成 Herdrbot 為該帳號使用的標籤，再加上[按鍵綁定](#按鍵綁定)。沒有這個外掛，Herdrbot 仍會靠每 30 分鐘的巡查運作。

## 安裝

```sh
herdr plugin install devicki/herdr-away-signal --ref v0.4.0 --yes
```

`--ref` 用來鎖定發行版本。設定範本會在代理程式狀態第一次改變或第一次按下按鍵時，或在 Herdr 伺服器下次啟動時寫入。

## 設定

設定檔是外掛設定目錄（`herdr plugin config-dir devicki.away-signal`，通常是 `~/.config/herdr/plugins/config/devicki.away-signal/`）中的 `away-signal.conf`。這個檔案含有機密，因此建立時只有你本人可以讀取。[`away-signal.conf.example`](away-signal.conf.example) 列出了所有設定。

| 鍵 | 預設值 | |
|---|---|---|
| `url` | 無 | webhook；沒有的話所有訊號都是 dry run |
| `key` | 無 | 以 `Authorization: Bearer <key>` 送出 |
| `dry_run` | `false` | `true` 時只記錄訊號，不送出 |
| `machine` | 簡短主機名稱 | 這台機器在每則訊號中使用的名稱 |
| `sleep_hours` | 無 | 例如 `23:00-07:00`：睡覺時自動開啟暫離模式（[見下方](#就寢時間)） |
| `delay` | `60` | 狀態必須維持多少秒才會送出 |
| `repeat` | `600` | 同一個窗格與狀態要隔多少秒才會再次送出 |

每個請求都是帶有 `Content-Type: application/json` 的 POST：

```json
{"type":"away","on":true,"machine":"laptop"}
{"type":"agent","machine":"laptop","pane_id":"w1:p2","agent":"claude","status":"blocked","title":"fix the login test","cwd":"/home/me/shop"}
```

`status` 是 `blocked`、`done`（在你沒看著時結束的一輪工作）或 `idle`（在你看著時結束的一輪工作）。`title` 是窗格的終端機標題。

## 按鍵綁定

外掛無法自行綁定按鍵，所以請把以下內容加到 `~/.config/herdr/config.toml`，再執行 `herdr server reload-config`：

```toml
[[keys.command]]
key = "prefix+a"
type = "plugin_action"
command = "devicki.away-signal.on"
description = "暫離模式開啟"

[[keys.command]]
key = "prefix+shift+a"
type = "plugin_action"
command = "devicki.away-signal.off"
description = "暫離模式關閉"
```

離開時按的鍵和回來時按的鍵是分開的。同一個鍵再按一次，狀態也不會改變，所以旗標不同步的機器不會被反向切換。如果你偏好只用一個鍵，也可以使用 `devicki.away-signal.toggle`。在 Herdr 0.9.5 的預設設定中，這兩個鍵都沒有被占用；如果你自己的設定已經用了它們，請另選其他按鍵。

## 就寢時間

```
sleep_hours = 23:00-07:00
```

就寢時間開始時，暫離模式會自動開啟，機器人也會照常收到暫離訊號。就寢時間結束時會再關閉，但只限於由就寢時間開啟的情況；睡前手動開啟的暫離模式會保持開啟。在這段期間按下按鍵，則在下一次開始或結束之前以按鍵為準，所以為了熬夜工作而關閉，當晚就會維持關閉。時間是這台機器的當地時間，可以跨過午夜；每台機器各自設定。外掛會在每次代理程式狀態改變時檢查，並保留一個小型等待程序，在下一次開始或結束時醒來；修改時間範圍後，會在 15 分鐘內生效。

## 側邊欄標示

暫離模式開啟時，每台機器最上方的工作區那一列會帶上 `away` 標記（🌙 away）。每台機器只有一列，所以一眼就能看出哪些機器處於暫離。標記要放進側邊欄的列中才會顯示；以下是在 Herdr 預設工作區列加上標記的設定，請加到 `~/.config/herdr/config.toml`：

```toml
[ui.sidebar.spaces]
rows = [
  ["state_icon", "workspace", "$away"],
  ["branch", "git_status"],
]
```

如果你已經自訂過 `rows`，只要把 `"$away"` 加到想要的那一列即可。若你是從筆電連到遠端機器，側邊欄是由筆電繪製的，所以這段要放在筆電的設定裡。透過 SSH 變更旗標時，會在下一次代理程式狀態改變時跟著更新。

## 旗標檔案

這個檔案存在時，暫離模式就是開啟的：

```
~/.local/state/herdr/plugins/devicki.away-signal/away
```

每台機器、每個帳號各有自己的一份。要讓多處保持一致，請直接建立或刪除這個檔案，例如透過 SSH：`touch <路徑>` 或 `rm -f <路徑>`。這在任何 shell（包括 fish）都能用，而且不會送出任何東西。外掛在每次狀態改變時都會讀取旗標，送出前也會再讀一次。

在 shell 中：

```sh
bash away-signal.sh on | off | toggle   # 與按鍵相同：旗標、webhook、Herdr 通知
bash away-signal.sh status              # on 或 off
```

## 記錄檔

`~/.local/state/herdr/plugins/devicki.away-signal/away-signal.log` 記錄了每則訊號，並標示 `sent`、`FAILED` 或 `dry-run`；送出失敗時會附上 curl 的錯誤訊息。金鑰絕不會寫入其中。記錄檔只保留最後 500 到 1,000 行。

## 測試

```sh
herdr plugin link .   # 在複製下來的儲存庫中執行，取代上面的安裝方式
./test.sh
```

它會啟動一個隔離的 Herdr（有自己的 HOME，只連結這個外掛）和一個在 localhost 上的替代 webhook，接著檢查切換動作、`pane.agent_status_changed` 鉤子、延遲與重複規則、請求標頭、dry run 以及設定範本。你自己的 Herdr 伺服器不會受到影響。

也已用實際運作的機器人完整驗證過（Herdr 0.9.5，Linux）：暫離訊號、完成一輪工作的代理程式（`idle`），以及停在 Claude Code 資料夾信任確認畫面的代理程式（`blocked`）都順利送達，後兩者是在 60 秒重新確認之後才送出。

還沒有 webhook 時手動測試：連結外掛、按下按鍵，然後在代理程式完成一輪工作時觀察記錄檔：

```sh
tail -f ~/.local/state/herdr/plugins/devicki.away-signal/away-signal.log
```

試用時可設定 `delay = 5`，就不用等上一分鐘。

發行時，請提高 `herdr-plugin.toml` 中的 `version`，更新每份 README 裡的 `--ref`，提交後執行 `git tag -a vX.Y.Z -m vX.Y.Z && git push origin vX.Y.Z`。

## 授權

MIT
