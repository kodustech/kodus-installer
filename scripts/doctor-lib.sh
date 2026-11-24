# shellcheck shell=bash
# scripts/doctor-lib.sh — shared report for doctor.sh and doctor-k8s.sh.
#
# The checks used to print as they ran, so the answer to "are my reviews
# working?" sat at the bottom of a long log. Now every check records a result,
# the legacy per-check output goes to a detail log, and the report prints:
#
#   1. the verdict          Reviews: NOT RUNNING / COULD NOT VERIFY /
#                           RUNNING, DEGRADED / OK
#   2. the problems, worst first, each with what is lost and the fix
#   3. one line for everything that passed (--verbose lists them + the log)
#
# COULD NOT VERIFY: no ✘, but the review checks inside the api did not answer,
# or the api itself said it could not verify (#verdict UNVERIFIED). A run that
# never reached those checks must not read as OK. Exit codes: 1 NOT RUNNING,
# 2 COULD NOT VERIFY, 0 otherwise.
#
#   fail    (✘) reviews do not run
#   warn    (!) reviews run degraded
#   unknown (?) could not verify / needs a look
#   info    (i) optional feature off
#   skip    (-) skipped on purpose by a setting
#
# The review checks themselves live in the API (kodus-ai #1987) and are
# fetched with scripts/doctor/doctor-client.mjs inside the api container.

DOCTOR_RESULTS=$(mktemp "${TMPDIR:-/tmp}/kodus-doctor-results.XXXXXX")
DOCTOR_DETAIL=$(mktemp "${TMPDIR:-/tmp}/kodus-doctor-detail.XXXXXX")
DOCTOR_VERBOSE=false
DOCTOR_RENDERED=false
DOCTOR_APP_VERSION=""
# The api's own verdict (#verdict line). Only UNVERIFIED changes anything here;
# the installer computes the verdict from the statuses itself.
DOCTOR_APP_VERDICT=""
# none: the review checks were not asked; answered; failed: asked, no answer.
DOCTOR_APP_STATE=none
# Checks whose ✘ does not fail the exit code (doctor-k8s.sh --profile dev).
DOCTOR_SOFT_APP_FAILS=false

# Drops C0 controls (tab/newline kept) and UTF-8-encoded C1 controls
# (U+0080-U+009F: CSI, OSC...), which xterm-family terminals still act on.
# awk, not sed: \xNN is GNU-only, and a byte-range tr would cut valid
# UTF-8 (the report's own ✘ holds 0x9C). Works in BSD awk, mawk, busybox.
_doctor_strip_controls() {
    tr -d '\000-\010\013-\037\177' | LC_ALL=C awk '{ gsub(/\302[\200-\237]/, ""); print }'
}

# One line, no control bytes: every record goes through here before the
# renderer prints it to a terminal.
_doctor_oneline() { printf '%s' "$1" | tr '\t\r\n' '   ' | _doctor_strip_controls; }

# doctor_add <status> <check> <scope> <title> [impact] [fix]
doctor_add() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$1" "$2" "$(_doctor_oneline "$3")" "$(_doctor_oneline "$4")" \
        "$(_doctor_oneline "${5:-}")" "$(_doctor_oneline "${6:-}")" >> "$DOCTOR_RESULTS"
}

# Everything printed from here on goes to the detail log, not the terminal.
doctor_capture_start() {
    exec 3>&1
    exec 1>"$DOCTOR_DETAIL"
    trap _doctor_on_exit EXIT
}

# An early `exit` (missing docker/kubectl) must still show what happened.
_doctor_on_exit() {
    local rc=$?
    if [ "$DOCTOR_RENDERED" != "true" ]; then
        exec 1>&3
        cat "$DOCTOR_DETAIL"
    fi
    rm -f "$DOCTOR_RESULTS" "$DOCTOR_DETAIL"
    exit "$rc"
}

# Host of a URL the way URL parsers (and the app's drivers) read it: the
# authority ends at the first / ? or #, user:password@ ends at its last @, a
# [bracketed] IPv6 host keeps its colons. Lowercased, no trailing dot.
doctor_url_host() {
    local u=${1#*://} host
    u=${u%%[/?#]*}
    u=${u##*@}
    case "$u" in
        \[*\]*) host=${u#\[}; host=${host%%\]*} ;;
        *) host=${u%%:*} ;;
    esac
    host=$(printf '%s' "$host" | tr '[:upper:]' '[:lower:]')
    printf '%s' "${host%.}"
}

# A host that only ever means "this machine": unreachable from a Git provider.
# Takes a host from doctor_url_host. Every spelling URL parsers accept counts:
# 127.0.0.1, 127.1, 0177.0.0.1, 0x7f.1, 2130706433, 0, ::1, 0:0:0:0:0:0:0:1,
# ::ffff:127.0.0.1, ::ffff:7f00:1, and the unspecified 0.0.0.0 / ::.
doctor_is_loopback_host() {
    local h=${1%%\%*}  # an IPv6 zone (%eth0) does not change the address
    case "$h" in
        localhost|*.localhost) return 0 ;;
        *:*) _doctor_ipv6_is_loopback "$h"; return ;;
    esac
    _doctor_ipv4_is_loopback "$h"
}

# Value of one IPv4 part as URL parsers read it (0x.. hex, 0.. octal), or
# nothing when it is not a number (then the host is a name).
_doctor_ipv4_part() {
    case "$1" in
        0[xX]) echo 0 ;;
        0[xX]*) case "${1#0[xX]}" in *[!0-9a-fA-F]*) ;; *) [ ${#1} -le 10 ] && echo $((16#${1#0[xX]})) ;; esac ;;
        0*) case "$1" in *[!0-7]*) ;; *) [ ${#1} -le 12 ] && echo $((8#$1)) ;; esac ;;
        [1-9]*) case "$1" in *[!0-9]*) ;; *) [ ${#1} -le 10 ] && echo $((10#$1)) ;; esac ;;
    esac
}

_doctor_ipv4_is_loopback() {
    local part first="" all_zero=1 count=0 v
    local IFS=.
    for part in $1; do
        v=$(_doctor_ipv4_part "$part")
        [ -n "$v" ] || return 1
        count=$((count + 1))
        [ -n "$first" ] || first=$v
        [ "$v" -eq 0 ] || all_zero=0
    done
    [ "$count" -ge 1 ] && [ "$count" -le 4 ] || return 1
    [ "$all_zero" = 1 ] && return 0          # 0.0.0.0, 0
    # One part is the whole address; with more, the first part is the first octet.
    [ "$count" -eq 1 ] && first=$((first >> 24))
    [ "$first" -eq 127 ]
}

# a.b.c.d -> the two hex groups it occupies in an IPv6 address, or fails.
_doctor_v4_hex_groups() {
    local IFS=. g
    # shellcheck disable=SC2086 # split on the dots on purpose
    set -- $1
    [ $# -eq 4 ] || return 1
    for g in "$@"; do
        case "$g" in ""|*[!0-9]*) return 1 ;; esac
        [ ${#g} -le 3 ] && [ "$((10#$g))" -le 255 ] || return 1
    done
    printf '%x:%x' $((10#$1 * 256 + 10#$2)) $((10#$3 * 256 + 10#$4))
}

_doctor_ipv6_is_loopback() {
    local a=$1 tail v4 left right n i g zeros
    local -a parts groups
    # An IPv4 tail (::ffff:127.0.0.1) becomes its two hex groups.
    tail=${a##*:}
    case "$tail" in
        *.*)
            v4=$(_doctor_v4_hex_groups "$tail") || return 1
            a="${a%:*}:$v4" ;;
    esac
    case "$a" in
        *::*::*) return 1 ;;
        *::*)
            left=${a%%::*}; right=${a#*::}
            n=0
            [ -n "$left" ] && n=$((n + $(printf '%s' "$left" | tr -cd ':' | wc -c) + 1))
            [ -n "$right" ] && n=$((n + $(printf '%s' "$right" | tr -cd ':' | wc -c) + 1))
            [ "$n" -le 7 ] || return 1
            zeros=""
            for ((i = n; i < 8; i++)); do zeros="${zeros:+$zeros:}0"; done
            a="${left:+$left:}${zeros}${right:+:$right}" ;;
    esac
    IFS=: read -r -a parts <<< "$a"
    [ "${#parts[@]}" -eq 8 ] || return 1
    for g in "${parts[@]}"; do
        case "$g" in ""|*[!0-9a-f]*) return 1 ;; esac
        [ ${#g} -le 4 ] || return 1
        groups+=($((16#$g)))
    done
    for ((i = 0; i < 5; i++)); do [ "${groups[$i]}" -eq 0 ] || return 1; done
    if [ "${groups[5]}" -eq 0 ] && [ "${groups[6]}" -eq 0 ]; then
        [ "${groups[7]}" -le 1 ] && return 0       # ::1 and ::
    fi
    # IPv4-mapped (::ffff:127.x.y.z) or IPv4-compatible (::127.x.y.z).
    if [ "${groups[5]}" -eq 65535 ] || [ "${groups[5]}" -eq 0 ]; then
        [ $((groups[6] >> 8)) -eq 127 ] && return 0
        [ "${groups[6]}" -eq 0 ] && [ "${groups[7]}" -eq 0 ] && [ "${groups[5]}" -eq 65535 ] && return 0  # ::ffff:0.0.0.0
    fi
    return 1
}

# Appends the API's results (doctor-client.mjs --format tsv) read from stdin.
# App results are tagged so --profile dev can keep them out of the exit code.
doctor_add_app_tsv() {
    local line
    while IFS= read -r line; do
        line=${line%$'\r'}
        case "$line" in
            # Metadata only: a version with no verdict and no check is not an answer.
            '#version'*) DOCTOR_APP_VERSION="${line#*	}" ;;
            '#verdict'*)
                DOCTOR_APP_STATE=answered
                DOCTOR_APP_VERDICT=$(printf '%s' "${line#\#verdict}" | tr -d '[:space:]')
                ;;
            '#'*|'') ;;
            *)
                # Only a line that carries a status is a check result; stray
                # output (a runtime warning on stderr) is not an answer.
                case "${line%%$'\t'*}" in
                    fail|warn|unknown|info|skip|ok) DOCTOR_APP_STATE=answered ;;
                esac
                # The api is trusted to send 6 tab-separated fields, but its
                # text can carry provider messages: drop control bytes (ANSI
                # included) and anything that is not exactly 6 fields, so the
                # renderer's columns cannot shift.
                line=$(printf '%s' "$line" | _doctor_strip_controls)
                if [ "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" = 6 ]; then
                    printf 'app:%s\n' "$line" >> "$DOCTOR_RESULTS"
                else
                    # The status is the first field and never holds a tab, so
                    # a malformed ✘ or ! still counts: it must not turn a real
                    # failure into "Reviews: OK".
                    local status=${line%%$'\t'*}
                    case "$status" in fail|warn) ;; *) status=unknown ;; esac
                    printf 'app:%s\treviews.doctor\t\t%s\t\t%s\n' "$status" \
                        "One review check line could not be read." \
                        "Run this script again with --verbose: the api's output is under 'Review checks (api output)'; share it with support." >> "$DOCTOR_RESULTS"
                fi
                ;;
        esac
    done
}

# Runs the API's review checks through <exec prefix> (e.g. "docker compose
# exec -T api") and records them, or records why they could not run.
doctor_run_app_checks() {
    local exec_prefix=$1 out rc
    out=$($exec_prefix sh -c \
        'test -f scripts/doctor/doctor-client.mjs || exit 42; node scripts/doctor/doctor-client.mjs --format tsv' 2>&1)
    rc=$?
    # Filtered once, here, so every consumer is covered (the --verbose log,
    # the TSV parser, the error title below): provider text cannot carry
    # terminal escapes into the operator's screen or a support thread.
    # Tab and newline are kept, so the TSV shape is untouched.
    out=$(printf '%s' "$out" | _doctor_strip_controls)
    printf '\n== Review checks (api output) ==\n%s\n' "$out" >> "$DOCTOR_DETAIL"
    local unverified="Whether reviews run could not be checked."
    if [ $rc -eq 0 ]; then
        # Here-string, not a pipe: a pipe would run it in a subshell and
        # lose DOCTOR_APP_VERSION / DOCTOR_APP_STATE.
        doctor_add_app_tsv <<< "$out"
        if [ "$DOCTOR_APP_STATE" != answered ]; then
            DOCTOR_APP_STATE=failed
            doctor_add unknown reviews.doctor "" \
                "The review checks returned nothing." "$unverified" \
                "Run this script again with --verbose: the api's output is under 'Review checks (api output)'; share it with support."
        fi
    elif [ $rc -eq 42 ]; then
        DOCTOR_APP_STATE=failed
        doctor_add unknown reviews.doctor "" \
            "The review checks are not available in this Kodus version." "$unverified" \
            "Upgrade Kodus to a release that ships scripts/doctor/doctor-client.mjs, then run this again."
    else
        DOCTOR_APP_STATE=failed
        doctor_add unknown reviews.doctor "" \
            "The review checks did not run: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)" \
            "$unverified" "Check that the api is up and healthy, then run this again."
    fi
}

# consumer_timeout shorter than the longest review (1h45) cuts reviews off.
# <value> is the output of `rabbitmqctl eval 'application:get_env(rabbit, consumer_timeout).'`
doctor_check_consumer_timeout() {
    local raw ms minutes
    raw=$(printf '%s' "$1" | tr -d '[:space:]')
    case "$raw" in
        '{ok,'*'}') ms=${raw#\{ok,}; ms=${ms%\}} ;;
        undefined) ms=1800000 ;; # RabbitMQ default: 30 min
        *) ms="" ;;
    esac
    if ! [ "$ms" -eq "$ms" ] 2>/dev/null; then
        doctor_add unknown broker.consumer_timeout "" \
            "Could not read the message queue's job time limit (consumer_timeout)." \
            "" "Make sure consumer_timeout is at least 7200000 (2 hours) in rabbitmq.conf."
        return
    fi
    minutes=$((ms / 60000))
    if [ "$ms" -lt 7200000 ]; then
        doctor_add warn broker.consumer_timeout "" \
            "The message queue stops any job that runs longer than ${minutes} minutes." \
            "Reviews of large pull requests that take longer than ${minutes} minutes are cut off and never finish." \
            "Set consumer_timeout = 7200000 in rabbitmq.conf and restart RabbitMQ."
    else
        doctor_add ok broker.consumer_timeout "" \
            "The message queue lets jobs run up to ${minutes} minutes."
    fi
}

# Resource alarm on the broker (kodus-ai #1694). While a memory or disk alarm
# is in effect RabbitMQ blocks every publisher: the node, its connections and
# the consumers stay up, only publishing hangs, so Git events and review jobs
# are never queued while every service reads "running". check_running passes.
# doctor_check_rabbit_alarms <rc> <output of `rabbitmq-diagnostics -q check_alarms`> <disk fix> <memory fix>
doctor_check_rabbit_alarms() {
    local rc=$1 out=$2 disk_fix=$3 memory_fix=$4 kind="" fix=""
    if [ "$rc" -eq 0 ]; then
        doctor_add ok broker.alarms "" "The message queue has no resource alarm (publishers are not blocked)."
        return
    fi
    # Exit 69 with "<Free disk space|Memory> alarm on node ..." per alarm;
    # anything else (node down, CLI error) is not an answer.
    if ! printf '%s' "$out" | grep -qi 'alarm on node'; then
        doctor_add unknown broker.alarms "" "Could not check the message queue for resource alarms." "" \
            "Run 'rabbitmq-diagnostics check_alarms' on the broker; an alarm there blocks every new review job."
        return
    fi
    if printf '%s' "$out" | grep -qi 'disk.*alarm on node'; then
        kind="disk"; fix=$disk_fix
    fi
    if printf '%s' "$out" | grep -qi 'memory.*alarm on node'; then
        kind="${kind:+$kind and }memory"; fix="${fix:+$fix }$memory_fix"
    fi
    doctor_add fail broker.alarms "" \
        "The message queue is blocking new jobs (RabbitMQ ${kind:-resource} alarm)." \
        "No Git event or review job can be queued, so no review runs, while every service still reads as running." \
        "${fix:-$disk_fix $memory_fix}"
}

doctor_has_fail() {
    if [ "$DOCTOR_SOFT_APP_FAILS" = "true" ]; then
        grep -q '^fail	' "$DOCTOR_RESULTS"
    else
        grep -qE '^(app:)?fail	' "$DOCTOR_RESULTS"
    fi
}

# The review checks never answered, or the api said it could not verify.
doctor_unverified() {
    [ "$DOCTOR_APP_STATE" != answered ] || [ "$DOCTOR_APP_VERDICT" = UNVERIFIED ]
}

# NOT_RUNNING > UNVERIFIED > DEGRADED > OK. A ✘ is a definite answer, so it
# wins; without one, reviews cannot be called fine when their checks did not run.
doctor_verdict() {
    if grep -qE '^(app:)?fail	' "$DOCTOR_RESULTS"; then
        echo NOT_RUNNING
    elif doctor_unverified; then
        echo UNVERIFIED
    elif grep -qE '^(app:)?warn	' "$DOCTOR_RESULTS"; then
        echo DEGRADED
    else
        echo OK
    fi
}

# 1 = reviews do not run, 2 = could not verify, 0 otherwise. --profile dev
# keeps the api's own answers out of it (its ✘ and its UNVERIFIED verdict:
# a fresh install has nothing to review yet); the api not answering at all
# still counts.
doctor_exit_code() {
    if doctor_has_fail; then
        echo 1
    elif [ "$DOCTOR_APP_STATE" != answered ]; then
        echo 2
    elif [ "$DOCTOR_APP_VERDICT" = UNVERIFIED ] && [ "$DOCTOR_SOFT_APP_FAILS" != "true" ]; then
        echo 2
    else
        echo 0
    fi
}

doctor_render() {
    local g='\033[0;32m' y='\033[1;33m' r='\033[0;31m' m='\033[0;35m' c='\033[0;36m' d='\033[0;90m' b='\033[1m' n='\033[0m'
    exec 1>&3
    DOCTOR_RENDERED=true

    # Results without the app: tag, in the order they were recorded.
    local all
    all=$(sed 's/^app://' "$DOCTOR_RESULTS")
    count() { printf '%s\n' "$all" | grep -c "^$1	"; }
    local nfail nwarn nunk ninfo nskip nok
    nfail=$(count fail); nwarn=$(count warn); nunk=$(count unknown)
    ninfo=$(count info); nskip=$(count skip); nok=$(count ok)

    case "$(doctor_verdict)" in
        NOT_RUNNING) echo -e "${b}${r}Reviews: NOT RUNNING${n}" ;;
        UNVERIFIED) echo -e "${b}${m}Reviews: COULD NOT VERIFY${n}" ;;
        DEGRADED) echo -e "${b}${y}Reviews: RUNNING, DEGRADED${n}" ;;
        *) echo -e "${b}${g}Reviews: OK${n}" ;;
    esac
    local summary=""
    [ "$nfail" -gt 0 ] && summary+="✘ $nfail   "
    [ "$nwarn" -gt 0 ] && summary+="! $nwarn   "
    [ "$nunk" -gt 0 ] && summary+="? $nunk   "
    [ "$ninfo" -gt 0 ] && summary+="i $ninfo   "
    [ "$nskip" -gt 0 ] && summary+="- $nskip   "
    [ "$nok" -gt 0 ] && summary+="✔ $nok   "
    echo "${summary}(Kodus ${DOCTOR_APP_VERSION:-version unknown})"
    echo

    local status mark color
    for status in fail warn unknown info skip ok; do
        case "$status" in
            fail) mark='✘'; color=$r ;;
            warn) mark='!'; color=$y ;;
            unknown) mark='?'; color=$m ;;
            info) mark='i'; color=$c ;;
            skip) mark='-'; color=$d ;;
            ok) mark='✔'; color=$g
                [ "$DOCTOR_VERBOSE" = "true" ] || continue ;;
        esac
        # \037 instead of tab: IFS treats tabs as whitespace and would
        # collapse an empty scope/impact column into the next one.
        printf '%s\n' "$all" | grep "^${status}	" | tr '\t' '\037' \
            | while IFS=$'\037' read -r _ _ scope title impact fix; do
                printf '%b%s%b %s' "$color" "$mark" "$n" "$title"
                [ -n "$scope" ] && printf ' %b[%s]%b' "$d" "$scope" "$n"
                printf '\n'
                [ -n "$impact" ] && printf '    Impact: %s\n' "$impact"
                [ -n "$fix" ] && printf '    Fix: %s\n' "$fix"
            done
    done
    if [ "$DOCTOR_VERBOSE" != "true" ] && [ "$nok" -gt 0 ]; then
        echo -e "${g}✔${n} ${nok} check(s) passed (--verbose to list them and the full log)."
    fi
    echo
    echo "✘ reviews do not run   ! reviews run degraded   ? could not verify   i optional feature off   - skipped by your settings"

    if [ "$DOCTOR_VERBOSE" = "true" ]; then
        echo
        echo "== Full log =="
        cat "$DOCTOR_DETAIL"
    fi
}
