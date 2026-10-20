#!/usr/bin/env bash
# away-signal: while you are away, tell an orchestrator through a webhook when an agent finishes
# or needs you, so it never has to poll Herdr.
#
#   away-signal.sh toggle | on | off   set away mode, POST it, show it in Herdr
#   away-signal.sh status              print on or off
#
# Internal: init (startup), event (plugin hook), confirm (delayed agent check), mark (sidebar),
# tick and sleeper (sleep hours).
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

set_away() { # on|off [auto]; auto: set by sleep hours, which may then turn it off again
  local on=false body=""
  mkdir -p "$statedir"
  if [ "$1" = on ]; then on=true; : >"$flag"; else rm -f "$flag"; fi
  if [ "${2:-}" = auto ] && [ "$1" = on ]; then : >"$statedir/away.auto"; else rm -f "$statedir/away.auto"; fi
  [ "${2:-}" != auto ] || body="Sleep hours $(conf_get sleep_hours)"
  post "$(jq -cn --argjson on "$on" --arg m "$(machine)" '{type: "away", on: $on, machine: $m}')" ||
    body="The webhook did not take it; see $log"
  [ -n "$(conf_get url)" ] && [ "$(conf_get dry_run)" != true ] || body="Dry run: logged to $log"
  "$H" notification show "away-signal: away $1" ${body:+--body "$body"} >/dev/null 2>&1 || :
  mark
  echo "away $1"
}

# The sidebar mark: an `away` token on this server's first workspace while away mode is on, so
# one row per machine shows it. It is redrawn only when the flag or the first workspace changed
# (a flag set over SSH shows at the next hook); Herdr forgets tokens on restart, so startup
# forces it.
mark() { # [force]
  local list want f
  f="$statedir/mark-$(printf %s "${HERDR_SOCKET_PATH:-}" | cksum | cut -d' ' -f1)"
  list=$("$H" workspace list 2>/dev/null | jq -r '.result.workspaces[].workspace_id') || return 0
  [ -n "$list" ] || return 0
  want=off
  [ ! -e "$flag" ] || want="on ${list%%$'\n'*}"
  [ "${1:-}" = force ] || [ "$want" != "$(cat "$f" 2>/dev/null)" ] || return 0
  while IFS= read -r w; do
    if [ "$want" = "on $w" ]; then
      "$H" workspace report-metadata "$w" --source devicki.away-signal --token "away=🌙 away"
    else
      "$H" workspace report-metadata "$w" --source devicki.away-signal --clear-token away
    fi >/dev/null 2>&1
  done <<<"$list"
  mkdir -p "$statedir" && echo "$want" >"$f"
}

# Sleep hours (sleep_hours = HH:MM-HH:MM, local time, may span midnight): away mode turns on
# when they start and, if they turned it on, off when they end. A key press in between wins
# until the next start or end. Every hook checks, and one detached sleeper wakes for the next
# start or end (at least every 15 minutes, so an edited range takes effect soon).
tick() {
  local r st since next id
  r=$(conf_get sleep_hours | tr -d '[:space:]')
  read -r st since next <<<"$(awk -v r="$r" -v t="$(date +%H:%M:%S)" '
    function sec(x, a) { split(x, a, ":"); return a[1] * 3600 + a[2] * 60 + a[3] }
    BEGIN {
      if (r !~ /^[0-9]?[0-9]:[0-9][0-9]-[0-9]?[0-9]:[0-9][0-9]$/) exit
      split(r, p, "-"); s = sec(p[1]); e = sec(p[2]); n = sec(t)
      if (s == e) exit
      if ((s < e && n >= s && n < e) || (s > e && (n >= s || n < e)))
        print "on", (n - s + 86400) % 86400, (e - n + 86400) % 86400
      else print "off", (n - e + 86400) % 86400, (s - n + 86400) % 86400
    }')"
  [ -n "$st" ] || return 0
  # The start or end we are past, by its minute: each one is acted on once.
  id="$st $((($(date +%s) - since) / 60))"
  lock schedule
  if [ "$id" != "$(cat "$statedir/schedule" 2>/dev/null)" ]; then
    echo "$id" >"$statedir/schedule"
    if [ "$st" = on ] && [ ! -e "$flag" ]; then set_away on auto >/dev/null
    elif [ "$st" = off ] && [ -e "$statedir/away.auto" ]; then set_away off auto >/dev/null
    fi
  fi
  unlock schedule
  local pid
  pid=$(cat "$statedir/sleeper.pid" 2>/dev/null)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null ||
    nohup bash "$self" sleeper "$((next + 5 < 900 ? next + 5 : 900))" </dev/null >/dev/null 2>&1 &
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
  tick
  mark
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
(init) tick; mark force ;;
(tick) tick ;;
(sleeper) echo $$ >"$statedir/sleeper.pid"; sleep "$2"; rm -f "$statedir/sleeper.pid"; tick ;;
(mark) mark ;;
(toggle) if [ -e "$flag" ]; then set_away off; else set_away on; fi ;;
(on | off) set_away "$1" ;;
(status) if [ -e "$flag" ]; then echo on; else echo off; fi ;;
(event) event ;;
(confirm) shift; confirm "$@" ;;
(*) echo "usage: away-signal.sh toggle|on|off|status" >&2; exit 2 ;;
esac
