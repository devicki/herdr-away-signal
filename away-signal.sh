#!/usr/bin/env bash
# away-signal: while you are away, tell an orchestrator through a webhook when an agent finishes
# or needs you, so it never has to poll Herdr.
#
#   away-signal.sh toggle | on | off   set away mode, POST it, show it in Herdr
#   away-signal.sh status              print on or off
#
# Internal: init (startup), event (plugin hook), confirm (delayed agent check).
# Away mode is one flag file, $statedir/away: present means away. An orchestrator that keeps
# several machines in step creates or removes it directly, which sends nothing.
set -uo pipefail

# herdr runs plugin commands with a minimal PATH; ensure jq and curl resolve on common installs.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:${PATH:-}"

here="$(cd "$(dirname "$0")" && pwd)"
self="$here/$(basename "$0")"
H="${HERDR_BIN_PATH:-herdr}"
confdir="${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/config/devicki.away-signal}"
statedir="${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr/plugins/devicki.away-signal}"
conf="$confdir/away-signal.conf"
flag="$statedir/away"
log="$statedir/away-signal.log"

# The commented template, private, whenever there is no config yet: startup writes it, and so
# does the first hook or key press after an install, before any server restart.
[ -e "$conf" ] || { mkdir -p "$confdir" && (umask 077 && cp "$here/away-signal.conf.example" "$conf"); } 2>/dev/null

conf_get() { # key; ` #` starts a note
  [ -f "$conf" ] && sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$conf" |
    sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//' | tail -n1
}
num() { # key default
  local v
  v=$(conf_get "$1")
  case "$v" in ('' | *[!0-9]*) echo "$2" ;; (*) echo "$v" ;; esac
}

# The log keeps what was sent (or would have been, in a dry run), never the key; last 500 lines.
say() {
  mkdir -p "$statedir"
  printf '%s %s\n' "$(date '+%F %T')" "$*" >>"$log"
  [ "$(wc -l <"$log")" -le 1000 ] || { tail -n 500 "$log" >"$log.tmp" && mv -f "$log.tmp" "$log"; }
}

# post JSON. The key goes to curl on stdin, never into `ps`.
post() {
  local url key
  url=$(conf_get url)
  key=$(conf_get key)
  if [ -z "$url" ] || [ "$(conf_get dry_run)" = true ]; then say "dry-run $1"; return 0; fi
  key=${key//\\/\\\\}
  if { [ -z "$key" ] || printf 'header = "Authorization: Bearer %s"\n' "${key//\"/\\\"}"; } |
    curl -fsS --max-time 10 --retry 1 --retry-delay 2 -K - -H 'Content-Type: application/json' \
      --data-binary "$1" "$url" >/dev/null 2>>"$log"; then
    say "sent $1"
  else
    say "FAILED $1"
    return 1
  fi
}

machine() { local m; m=$(conf_get machine); echo "${m:-$(hostname -s 2>/dev/null || uname -n)}"; }

set_away() { # on|off
  local on=false body=""
  mkdir -p "$statedir"
  if [ "$1" = on ]; then on=true; : >"$flag"; else rm -f "$flag"; fi
  post "$(jq -cn --argjson on "$on" --arg m "$(machine)" '{type: "away", on: $on, machine: $m}')" ||
    body="The webhook did not take it; see $log"
  [ -n "$(conf_get url)" ] && [ "$(conf_get dry_run)" != true ] || body="Dry run: logged to $log"
  "$H" notification show "away-signal: away $1" ${body:+--body "$body"} >/dev/null 2>&1 || :
  echo "away $1"
}

lock() { # name; a mkdir lock works the same on Linux and macOS
  local i=0
  mkdir -p "$statedir/panes"
  while ! mkdir "$statedir/panes/$1.lock" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -ne 50 ] || rm -rf "$statedir/panes/$1.lock" # held ~5s: left by a crash
    [ "$i" -lt 100 ] || return 0                        # cannot lock at all: go on without it
    sleep 0.1
  done
}
unlock() { rmdir "$statedir/panes/$1.lock" 2>/dev/null || :; }

# Per pane: "status generation". Every change of status starts a new generation, so a delayed
# check only signals if the status it was started for has held since.
read_state() { # key -> st gen
  st=unknown gen=0
  [ ! -f "$statedir/panes/$1" ] || read -r st gen <"$statedir/panes/$1" || :
}
# Named sessions share the state dir, so a pane is keyed by its server's socket too.
pane_key() { printf %s "${HERDR_SOCKET_PATH:-}#$1" | cksum | cut -d' ' -f1; }

# States are tracked while away mode is off too, so a turn that started before you left counts.
event() {
  local ev pane status key
  ev="${HERDR_PLUGIN_EVENT_JSON:-}"
  pane=$(jq -r '.data.pane_id // empty' <<<"$ev" 2>/dev/null)
  status=$(jq -r '.data.agent_status // empty' <<<"$ev" 2>/dev/null)
  [ -n "$pane" ] && [ -n "$status" ] || return 0
  key=$(pane_key "$pane")
  lock "$key"
  read_state "$key"
  if [ "$status" != "$st" ]; then
    gen=$((gen + 1))
    # Herdr says `done` for a turn that ended out of sight, `idle` when it ended in view.
    case "$status:$st" in
    (blocked:* | idle:working | done:working)
      [ ! -e "$flag" ] || nohup bash "$self" confirm "$pane" "$status" "$gen" </dev/null >/dev/null 2>&1 & ;;
    esac
  fi
  printf '%s %s\n' "$status" "$gen" >"$statedir/panes/$key"
  unlock "$key"
}

confirm() { # pane status gen
  local pane=$1 status=$2 want=$3 key agent now last=0
  key=$(pane_key "$pane")
  sleep "$(num delay 60)"
  [ -e "$flag" ] || return 0
  # Claim under the lock, so concurrent checks never send twice.
  lock "$key"
  read_state "$key"
  agent=$("$H" agent get "$pane" 2>/dev/null | jq -c '.result.agent // empty')
  if [ "$gen" != "$want" ] || [ "$(jq -r '.agent_status // empty' <<<"$agent")" != "$status" ]; then
    unlock "$key"
    return 0
  fi
  now=$(date +%s)
  [ ! -f "$statedir/panes/$key.$status" ] || read -r last <"$statedir/panes/$key.$status" || :
  if [ $((now - last)) -lt "$(num repeat 600)" ]; then unlock "$key"; return 0; fi
  echo "$now" >"$statedir/panes/$key.$status"
  unlock "$key"
  post "$(jq -c --arg m "$(machine)" --arg p "$pane" --arg s "$status" \
    '{type: "agent", machine: $m, pane_id: $p, agent: (.agent // ""), status: $s,
      title: (.terminal_title_stripped // .label // ""), cwd: (.cwd // "")}' <<<"$agent")"
}

case "${1:-}" in
(init) ;;
(toggle) if [ -e "$flag" ]; then set_away off; else set_away on; fi ;;
(on | off) set_away "$1" ;;
(status) if [ -e "$flag" ]; then echo on; else echo off; fi ;;
(event) event ;;
(confirm) shift; confirm "$@" ;;
(*) echo "usage: away-signal.sh toggle|on|off|status" >&2; exit 2 ;;
esac
