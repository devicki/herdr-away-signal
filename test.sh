#!/usr/bin/env bash
# End-to-end check against a stand-in webhook that records what it receives: an isolated Herdr
# (own HOME, only this plugin linked) drives agent states through the real plugin hook, and the
# toggle runs as the plugin action. Needs jq, curl and python3.
# TEST_WORK picks the scratch dir (default: a new mktemp dir).
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
work=${TEST_WORK:-$(mktemp -d)}
herdr=$(command -v herdr)
# Unix socket paths must stay under 108 bytes, so HOME is a short symlink to the scratch dir.
home="${XDG_RUNTIME_DIR:-/tmp}/away-test"
env_=(env -i HOME="$home" PATH="${herdr%/*}:/usr/local/bin:/usr/bin:/bin" LANG=en_US.UTF-8 USER=tester)
h() { "${env_[@]}" "$herdr" "$@"; }
cfg="$work/home/.config/herdr/plugins/config/devicki.away-signal"
state="$home/.local/state/herdr/plugins/devicki.away-signal"
fail=0
check() { # description, expected count, jq filter over received requests
  local n
  n=$(jq -s "[.[] | select($3)] | length" "$work/received.jsonl" 2>/dev/null || echo 0)
  if [ "$n" = "$2" ]; then echo "ok   $1"; else echo "FAIL $1: $n request(s), want $2" >&2; fail=1; fi
}
cleanup() {
  h server stop >/dev/null 2>&1 || :
  kill "${hook:-}" 2>/dev/null || :
  rm -f "$home"
}
trap cleanup EXIT

mkdir -p "$cfg"
ln -sfn "$work/home" "$home"
printf 'onboarding = false\n[update]\nversion_check = false\nmanifest_check = false\n' >"$work/home/.config/herdr/config.toml"
: >"$work/received.jsonl"

# The stand-in webhook: each POST as one JSON line with the headers that matter.
cat >"$work/hook.py" <<'EOF'
import http.server, json, sys
out = open(sys.argv[2], "a")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        out.write(json.dumps({"auth": self.headers.get("Authorization"),
            "ctype": self.headers.get("Content-Type"), "body": body}) + "\n"); out.flush()
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
EOF
port=$((20000 + RANDOM % 20000))
python3 "$work/hook.py" "$port" "$work/received.jsonl" &
hook=$!
printf 'url = http://127.0.0.1:%s/hook\nkey = test-key   # a note\nmachine = box\ndelay = 2\n' "$port" >"$cfg/away-signal.conf"

h plugin link "$here" >/dev/null
"${env_[@]}" "$herdr" server >/dev/null 2>&1 &
for _ in $(seq 50); do h pane list >/dev/null 2>&1 && break; sleep 0.2; done
p=$(h workspace create --cwd /tmp --label shop-api | jq -r .result.root_pane.pane_id)
say() { h pane report-agent "$p" --source test --agent claude --state "$1" >/dev/null; sleep "${2:-0.5}"; }

# Away mode off: a finished turn signals nothing.
say working; say idle 3.5
check "away off: nothing is sent" 0 'true'

# The toggle, run as the plugin action: flag file, webhook, auth and content type.
h plugin action invoke toggle --plugin devicki.away-signal >/dev/null; sleep 1
[ -e "$state/away" ] || { echo "FAIL the toggle did not write $state/away" >&2; fail=1; }
check "toggle on: away signal with the key and JSON" 1 \
  '.body == {type: "away", on: true, machine: "box"} and .auth == "Bearer test-key" and .ctype == "application/json"'

# The pane.agent_status_changed hook: a finished turn, after the delay, with where it is.
say working; say idle 3.5
check "hook fires: a finished turn is signalled" 1 \
  '.body.type == "agent" and .body.pane_id == "'"$p"'" and .body.agent == "claude" and .body.status == "idle" and .body.cwd == "/tmp" and .body.machine == "box"'
# A pause mid-turn (idle, then working again within the delay) is not.
say working; say idle 0.8; say working 3
check "a blip mid-turn is not signalled" 1 '.body.status == "idle"'
# Waiting for an answer: signalled, but the same pane and status not again within repeat.
say blocked 3; say working; say blocked 3
check "blocked is signalled once within repeat" 1 '.body.status == "blocked"'
# Idle without a working stretch before it is not a finished turn.
say idle 3
check "idle after a wait is not a finished turn" 1 '.body.status == "idle"'

# Toggle off: flag gone, signal sent, and turns are quiet again.
h plugin action invoke toggle --plugin devicki.away-signal >/dev/null; sleep 1
[ ! -e "$state/away" ] || { echo "FAIL the toggle left $state/away" >&2; fail=1; }
say working; say idle 3.5
check "toggle off: away off is signalled, then nothing" 1 '.body == {type: "away", on: false, machine: "box"}'
check "  and no turn after it" 2 '.body.type == "agent"'

# Dry run: no url, so the CLI only logs; the key never reaches the log.
mkdir -p "$work/dry"
printf 'key = test-key\nmachine = box\n' >"$work/dry/away-signal.conf"
"${env_[@]}" HERDR_PLUGIN_CONFIG_DIR="$work/dry" HERDR_PLUGIN_STATE_DIR="$work/drystate" bash "$here/away-signal.sh" on >/dev/null
sleep 0.5
check "dry run: nothing is sent" 4 'true'
grep -q 'dry-run {"type":"away","on":true,"machine":"box"}' "$work/drystate/away-signal.log" ||
  { echo "FAIL dry run did not log the signal" >&2; fail=1; }
! grep -rq test-key "$state" "$work/drystate" || { echo "FAIL the key reached a log" >&2; fail=1; }
[ "$("${env_[@]}" HERDR_PLUGIN_STATE_DIR="$work/drystate" bash "$here/away-signal.sh" status)" = on ] ||
  { echo "FAIL status does not read the flag" >&2; fail=1; }

# A config file is written on first use, readable by its owner only.
rm -rf "$work/fresh"
"${env_[@]}" HERDR_PLUGIN_CONFIG_DIR="$work/fresh" HERDR_PLUGIN_STATE_DIR="$work/fresh-state" bash "$here/away-signal.sh" status >/dev/null
case "$(stat -c %a "$work/fresh/away-signal.conf" 2>/dev/null || stat -f %Lp "$work/fresh/away-signal.conf")" in
(600) echo "ok   first use writes the config template, mode 600" ;;
(*) echo "FAIL init did not write a private config template" >&2; fail=1 ;;
esac

# On and off set the state whatever it was: pressing either twice leaves it the same.
h plugin action invoke on --plugin devicki.away-signal >/dev/null
h plugin action invoke on --plugin devicki.away-signal >/dev/null; sleep 1
[ -e "$state/away" ] || { echo "FAIL the on action did not write $state/away" >&2; fail=1; }
h plugin action invoke off --plugin devicki.away-signal >/dev/null
h plugin action invoke off --plugin devicki.away-signal >/dev/null; sleep 1
[ ! -e "$state/away" ] || { echo "FAIL the off action left $state/away" >&2; fail=1; }
check "on and off actions, twice each: never flipped (on)" 3 '.body == {type: "away", on: true, machine: "box"}'
check "  (off)" 3 '.body == {type: "away", on: false, machine: "box"}'

# The sidebar mark: while away, one `away` token, on the first workspace; it follows when that
# workspace closes, and goes when away mode is off.
marks() { h workspace list | jq -r '[.result.workspaces[] | select(.tokens.away) | .workspace_id] | join(" ")'; }
first() { h workspace list | jq -r '.result.workspaces[0].workspace_id'; }
h workspace create --cwd /tmp --label second --no-focus >/dev/null
h plugin action invoke on --plugin devicki.away-signal >/dev/null; sleep 1
w1=$(first)
[ "$(marks)" = "$w1" ] || { echo "FAIL away on: marked '$(marks)', want the first workspace $w1" >&2; fail=1; }
h workspace close "$w1" >/dev/null 2>&1; sleep 1.5
[ "$(marks)" = "$(first)" ] && [ "$(first)" != "$w1" ] ||
  { echo "FAIL the mark did not move to the new first workspace: '$(marks)'" >&2; fail=1; }
h plugin action invoke off --plugin devicki.away-signal >/dev/null; sleep 1
[ -z "$(marks)" ] || { echo "FAIL away off left a mark on '$(marks)'" >&2; fail=1; }
[ "$fail" -ne 0 ] || echo "ok   sidebar mark: first workspace only, follows it, cleared when off"

# Sleep hours: on at their start, off at their end if they turned it on; a key press wins.
mkdir -p "$work/sleep"
win() { python3 -c 'import datetime as d, sys; n = d.datetime.now(); f = lambda m: (n + d.timedelta(minutes=int(m))).strftime("%H:%M"); print(f(sys.argv[1]) + "-" + f(sys.argv[2]))' "$@"; }
sconf() { printf 'url = http://127.0.0.1:%s/hook\nmachine = sleepy\nsleep_hours = %s\n' "$port" "$1" >"$work/sleep/away-signal.conf"; }
sl() { "${env_[@]}" HERDR_PLUGIN_CONFIG_DIR="$work/sleep" HERDR_PLUGIN_STATE_DIR="$work/sleepstate" bash "$here/away-signal.sh" "$@"; }
sconf "$(win -1 2)"; sl tick; sl tick; sleep 0.5
check "sleep hours start: away on, once" 1 '.body == {type: "away", on: true, machine: "sleepy"}'
[ -e "$work/sleepstate/away" ] || { echo "FAIL sleep hours did not write the flag" >&2; fail=1; }
sconf "$(win -3 -1)"; sl tick; sleep 0.5
check "sleep hours end: away off, as they turned it on" 1 '.body == {type: "away", on: false, machine: "sleepy"}'
sconf "$(win -2 3)"; sl tick; sl off >/dev/null; sl tick; sleep 0.5
[ ! -e "$work/sleepstate/away" ] || { echo "FAIL a key press during sleep hours was undone" >&2; fail=1; }
sl on >/dev/null; sconf "$(win -4 -1)"; sl tick; sleep 0.5
[ -e "$work/sleepstate/away" ] || { echo "FAIL the end of sleep hours turned off an away set by hand" >&2; fail=1; }
check "  a key press wins until the next start or end" 3 '.body == {type: "away", on: true, machine: "sleepy"}'
[ ! -s "$work/sleepstate/sleeper.pid" ] || kill "$(cat "$work/sleepstate/sleeper.pid")" 2>/dev/null

[ "$fail" -eq 0 ] && echo PASS
exit "$fail"
