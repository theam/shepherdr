#!/bin/sh
# Tests the agent tools' command line against a fake herdr. The command runs with sh, or with
# TEST_SHELL: try dash, bash, busybox sh and zsh's sh, the shells agents meet, and a locale such
# as en_US.UTF-8.
#   sh Tests/AgentTools/test.sh
#   LC_ALL=en_US.UTF-8 TEST_SHELL=bash sh Tests/AgentTools/test.sh
# Needs nothing but POSIX tools. python3, when present, also checks that letters are valid JSON.

set -u
here=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd -P)
repo=$(CDPATH='' cd -- "$here/../.." && pwd -P)
cli="$repo/Sources/ShepherdrCore/Resources/AgentTools/bin/shepherdr"
shell=${TEST_SHELL:-sh}
failures=0
passed=0
scratch=$(mktemp -d "${TMPDIR:-/tmp}/shepherdr-tests.XXXXXX") && scratch=$(cd "$scratch" && pwd -P)
trap 'rm -rf "$scratch"' EXIT
cp "$here/fake-herdr" "$scratch/herdr"
chmod +x "$scratch/herdr"

# MARK: Harness

# A fresh home inside a Herdr pane, with a machine list as Shepherdr writes it on the Mac.
setup() {
    test_name=$1
    home="$scratch/$1"
    mkdir -p "$home/.shepherdr" "$home/work dir"
    log="$home/herdr.log"
    : >"$log"
    {
        printf '# shepherdr machines 1 rev 3f2a9c1b7e04 2026-10-15T10:15:02Z\n'
        printf 'Studio\there\t-\n'
        printf 'Homelab\tdirect\t7b2d55f04e1a9c36\n'
        printf 'buildbox\tshepherdr\t-\n'
    } >"$home/.shepherdr/machines"
}

# Runs the CLI as an agent in pane w1:p1 would. Leaves $output and $status.
run() {
    output=$(cd "$home/work dir" && env HOME="$home" HERDR_BIN_PATH="$scratch/herdr" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 \
        FAKE_HERDR_LOG="$log" TMPDIR="$scratch" "$shell" "$cli" "$@" 2>&1)
    status=$?
}

# Runs it outside Herdr.
run_outside() {
    output=$(cd "$home/work dir" && env -u HERDR_ENV -u HERDR_PANE_ID HOME="$home" HERDR_BIN_PATH="$scratch/herdr" \
        FAKE_HERDR_LOG="$log" TMPDIR="$scratch" "$shell" "$cli" "$@" 2>&1)
    status=$?
}

problem() {
    printf 'FAIL %s: %s\n' "$test_name" "$1"
    failures=$((failures + 1))
}

expect_status() { [ "$status" -eq "$1" ] || problem "exit status $status, expected $1. Output: $output"; }
expect_output() { case $output in *"$1"*) ;; *) problem "output lacks \"$1\": $output" ;; esac; }
expect_logged() { grep -Fqx -- "$1" "$log" || problem "herdr was never passed \"$1\""; }
expect_not_logged() { ! grep -Fqx -- "$1" "$log" || problem "herdr was passed \"$1\""; }

# The only letter in the outbox: its folder in $letter and its JSON in $json.
the_letter() {
    letter=
    count=0
    for entry in "$home/.shepherdr/outbox"/*; do
        [ -d "$entry" ] || continue
        letter=$entry
        count=$((count + 1))
    done
    [ "$count" -eq 1 ] || { problem "expected one letter, found $count"; json=; return; }
    for entry in "$home/.shepherdr/outbox"/.tmp-*; do
        [ -e "$entry" ] && problem "a letter was left half written: $entry"
    done
    json=$(cat "$letter/letter.json")
    if command -v python3 >/dev/null 2>&1; then
        printf '%s' "$json" | python3 -c 'import json, sys; json.load(sys.stdin)' 2>/dev/null || problem "invalid JSON: $json"
    fi
    id=$(basename "$letter")
    expect_json "\"id\":\"$id\""
    case $id in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) problem "unexpected letter id $id" ;;
    esac
}

expect_json() { case $json in *"$1"*) ;; *) problem "letter lacks $1: $json" ;; esac; }
expect_no_letter() {
    for entry in "$home/.shepherdr/outbox"/* "$home/.shepherdr/outbox"/.tmp-*; do
        [ -e "$entry" ] && problem "unexpected letter $entry"
    done
}
expect_doorbell() { expect_logged "shepherdr-mail=$id"; }

done_test() { passed=$((passed + 1)); }

# MARK: Tests

setup version
run version
expect_status 0
expect_output "shepherdr 4 (protocol 1)"
run help
expect_output "shepherdr spawn [options]"
run skill
expect_output "name: shepherdr"
run frobnicate
expect_status 2
done_test

setup machines
run machines
expect_status 0
expect_output "You are on Studio"
expect_output "Homelab                  direct     starts it there right away"
expect_output "buildbox                 shepherdr  asks the user to approve it in Shepherdr"
rm "$home/.shepherdr/machines"
run machines
expect_status 0
expect_output "hasn't written its machine list"
run spawn --machine Homelab
expect_status 1
expect_output "only this machine is known"
done_test

setup spawn_here
run spawn --name api-fix --prompt "Fix the test, then hand back."
expect_status 0
expect_output "Started api-fix (claude) on Studio, in $home/work dir, and sent it your prompt."
expect_output "keeps this session on hold"
expect_logged "workspace"
expect_logged "$home/work dir"
expect_logged "api-fix"
expect_logged "Fix the test, then hand back."
expect_not_logged "--machine"
the_letter
expect_json '"kind":"spawned"'
expect_json '"from":{"pane":"w1:p1","terminal":"term_caller1"}'
expect_json '"child":{"machine":"here","pane":"w9:p1","terminal":"term_child","workspace":"w9"}'
expect_json '"name":"api-fix","agent":"claude","placement":"workspace","wait":true,"prompt":"sent"'
[ -e "$letter/message.md" ] && problem "a sent prompt was kept"
expect_doorbell
done_test

setup spawn_direct
# A ~ the caller quoted, so that the other machine expands it.
# shellcheck disable=SC2088
run spawn --machine homelab --cwd "~/src/api" --kind codex --no-wait
expect_status 0
expect_output "Started "
expect_output "(codex) on Homelab, in ~/src/api."
expect_output "without putting this session on hold"
expect_output 'herdr --machine 7b2d55f04e1a9c36'
expect_logged "7b2d55f04e1a9c36"
# shellcheck disable=SC2088
expect_logged "~/src/api"
the_letter
expect_json '"child":{"machine":"profile:7b2d55f04e1a9c36","pane":"w9:p1","terminal":"term_childremote","workspace":"w9"}'
expect_json '"agent":"codex"'
expect_json '"wait":false,"prompt":"none"'
case $json in *'"name":"api-'????'"'*) ;; *) problem "the name wasn't made from the folder: $json" ;; esac
done_test

setup spawn_request
FAKE_CALLER_AGENT=codex
export FAKE_CALLER_AGENT
run spawn --machine BUILDBOX --cwd /srv/api --prompt "Look at the logs"
expect_status 0
expect_output "Asked Shepherdr to start a session on buildbox"
expect_not_logged "create"
the_letter
expect_json '"kind":"spawn-request","from":{"pane":"w1:p1","terminal":"term_caller1"},"machine":"buildbox","cwd":"/srv/api","agent":"codex","name":null,"wait":true,"prompt":"message.md"'
[ "$(cat "$letter/message.md")" = "Look at the logs" ] || problem "the prompt wasn't kept for the request"
unset FAKE_CALLER_AGENT
rm -rf "$home/.shepherdr/outbox"
run spawn --machine buildbox --cwd src/web --shell
the_letter
expect_json '"cwd":"~/src/web","agent":null'
done_test

setup spawn_unknown
run spawn --machine nowhere
expect_status 1
expect_output 'No machine named "nowhere". Machines Shepherdr knows: Studio, Homelab, buildbox.'
expect_no_letter
done_test

setup spawn_waiting
output=$(cd "$home/work dir" && env HOME="$home" HERDR_BIN_PATH="$scratch/herdr" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 \
    FAKE_HERDR_LOG="$log" FAKE_AGENT_START=not_ready TMPDIR="$scratch" "$shell" "$cli" spawn --name slow --prompt "Later, please" 2>&1)
status=$?
expect_status 0
expect_output "stopped at a startup question"
expect_output "Shepherdr sends it your prompt once it is ready."
expect_not_logged "prompt"
the_letter
expect_json '"prompt":"pending"'
[ "$(cat "$letter/message.md")" = "Later, please" ] || problem "the pending prompt wasn't kept"
done_test

setup spawn_split
run spawn --split right --shell
expect_status 0
expect_output "Started a shell"
expect_logged "split"
expect_logged "right"
expect_not_logged "start"
the_letter
expect_json '"child":{"machine":"here","pane":"w1:p2","terminal":"term_split1","workspace":"w1"}'
expect_json '"agent":null,"placement":"split"'
run spawn --split down --machine homelab
expect_status 2
done_test

setup spawn_failures
run spawn --cwd "$home/missing"
expect_status 1
expect_output "No folder at"
run spawn --name Bad
expect_status 2
run spawn --name "café"
expect_status 2
run spawn --name zed --kind Claude
expect_status 2
run spawn --shell --prompt hi
expect_status 2
# A prompt longer than a letter takes would never arrive: nothing starts.
dd if=/dev/zero bs=1024 count=300 2>/dev/null | tr '\0' a >"$home/long.md"
: >"$log"
run spawn --prompt-file "$home/long.md"
expect_status 1
expect_output "The prompt is over 256 KB"
expect_not_logged "workspace"
expect_no_letter
output=$(cd "$home/work dir" && env HOME="$home" HERDR_BIN_PATH="$scratch/herdr" HERDR_ENV=1 HERDR_PANE_ID=w1:p1 \
    FAKE_HERDR_LOG="$log" FAKE_FAIL="workspace create" TMPDIR="$scratch" "$shell" "$cli" spawn 2>&1)
status=$?
expect_status 1
expect_output "Herdr could not create a workspace on Studio: fake failure of workspace create"
expect_no_letter
done_test

setup spawn_outside
run_outside spawn --name lone
expect_status 0
expect_output "You're not in a Herdr pane"
the_letter
expect_json '"from":{}'
done_test

setup handoff
printf '# Report\nAll green.\n' >"$home/work dir/REPORT final.md"
run handoff --file "REPORT final.md" "PR opened:" "theam/api#41" --file "$home/work dir/REPORT final.md"
expect_status 0
expect_output "Handed off to the session waiting for you"
the_letter
expect_json '"kind":"handoff","from":{"pane":"w1:p1","terminal":"term_caller1"},"to":null,"body":"message.md","files":["files/REPORT_final.md","files/2-REPORT_final.md"]'
[ "$(cat "$letter/message.md")" = "PR opened: theam/api#41" ] || problem "wrong message: $(cat "$letter/message.md")"
cmp -s "$letter/files/REPORT_final.md" "$home/work dir/REPORT final.md" || problem "the attachment wasn't copied"
expect_doorbell
done_test

setup handoff_to
run handoff --to 'The "planner"@Mac' "Done"
expect_status 0
the_letter
expect_json '"to":"The \"planner\"@Mac","body":"message.md","files":[]'
done_test

setup handoff_stdin
output=$(printf 'From standard input\n' | (cd "$home/work dir" && env HOME="$home" HERDR_BIN_PATH="$scratch/herdr" HERDR_ENV=1 \
    HERDR_PANE_ID=w1:p1 FAKE_HERDR_LOG="$log" TMPDIR="$scratch" "$shell" "$cli" handoff -) 2>&1)
status=$?
expect_status 0
the_letter
[ "$(cat "$letter/message.md")" = "From standard input" ] || problem "standard input wasn't the message"
done_test

setup handoff_failures
run_outside handoff "Who am I?"
expect_status 1
expect_output "name the recipient with --to"
run handoff
expect_status 2
run handoff --file "$home/nothing.md"
expect_status 1
expect_no_letter
dd if=/dev/zero of="$home/big.bin" bs=1024 count=5200 2>/dev/null
run handoff --file "$home/big.bin" "Too big"
expect_status 1
expect_output "over 5 MB"
expect_no_letter
run_outside handoff --to planner "Outside works with a recipient"
expect_status 0
done_test

setup wait_resume
run wait-for reviewer "test runner"
expect_status 0
the_letter
expect_json '"kind":"wait","from":{"pane":"w1:p1","terminal":"term_caller1"},"sessions":["reviewer","test runner"]'
rm -rf "$home/.shepherdr/outbox"
run resume
expect_status 0
the_letter
expect_json '"kind":"resume","from":{"pane":"w1:p1","terminal":"term_caller1"},"sessions":[]'
run_outside wait-for reviewer
expect_status 1
done_test

setup close
run close
expect_status 0
expect_output "once you finish this turn"
the_letter
expect_json '"kind":"close","from":{"pane":"w1:p1","terminal":"term_caller1"},"sessions":[],"force":false'
expect_doorbell
rm -rf "$home/.shepherdr/outbox"
run close --force reviewer -- "test runner@buildbox"
expect_status 0
expect_output "Asked Shepherdr to close reviewer test runner@buildbox"
the_letter
expect_json '"sessions":["reviewer","test runner@buildbox"],"force":true'
rm -rf "$home/.shepherdr/outbox"
run close --everything
expect_status 2
run_outside close reviewer
expect_status 1
expect_no_letter
done_test

setup links
run pin "https://github.com/theam/api/pull/41" --title 'Cache "race" fix'
expect_status 0
the_letter
expect_json '"kind":"pin","from":{"pane":"w1:p1","terminal":"term_caller1"},"url":"https://github.com/theam/api/pull/41","title":"Cache \"race\" fix"'
rm -rf "$home/.shepherdr/outbox"
run open "http://localhost:3000/a?b=c"
expect_status 0
the_letter
expect_json '"kind":"open","from":{"pane":"w1:p1","terminal":"term_caller1"},"url":"http://localhost:3000/a?b=c"'
rm -rf "$home/.shepherdr/outbox"
run pin "file:///etc/passwd"
expect_status 2
run open "javascript:alert(1)"
expect_status 2
run open "https://example.com/a b"
expect_status 2
expect_no_letter
done_test

setup notify
run notify "Migration" "finished"
expect_status 0
the_letter
expect_json '"kind":"notify","from":{"pane":"w1:p1","terminal":"term_caller1"},"body":"message.md"'
[ "$(cat "$letter/message.md")" = "Migration finished" ] || problem "wrong notification text"
done_test

setup folders
run folders --machine homelab
expect_status 0
expect_output "Folders with sessions on Homelab, the busiest first:
/srv/api
/srv/web"
run folders --machine buildbox
expect_status 1
expect_output "can't reach buildbox"
done_test

setup status
run notify "one"
run status
expect_status 0
expect_output "Machine: Studio"
expect_output "Herdr pane: w1:p1 (terminal term_caller1)"
expect_output "Letters waiting for Shepherdr: 1"
done_test

printf '%s passed, %s failed (%s)\n' "$passed" "$failures" "$shell"
[ "$failures" -eq 0 ]
