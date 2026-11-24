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
# [bracketed] IPv6 host keeps its colons. Lowercased; a trailing dot is kept
# (the host parser below decides what it means).
doctor_url_host() {
    local u=${1#*://} host
    u=${u%%[/?#]*}
    u=${u##*@}
    case "$u" in
        \[*\]*) host=${u#\[}; host=${host%%\]*} ;;
        *) host=${u%%:*} ;;
    esac
    printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

# The broker host of an AMQP URI, read as the client reads it: the authority
# ends at the first / ? or #, the user info at the last @ inside it, and what
# is left must be host[:port] with a port of 1-65535 ([IPv6] allowed). Prints
# the host (lowercased), or fails when the client would reject the URI, as it
# does for a password with an unencoded / (kodus:pa/ss@... reads as host
# "kodus", port "pa"). An @ after the authority is part of the vhost.
doctor_amqp_host() {
    local rest=${1#*://} hostport host port=""
    rest=${rest%%[/?#]*}
    hostport=${rest##*@}
    case "$hostport" in
        \[*\]) host=${hostport#\[}; host=${host%\]} ;;
        \[*\]:*) host=${hostport#\[}; host=${host%%\]*}; port=${hostport##*\]:}; [ -n "$port" ] || return 1 ;;
        \[*) return 1 ;;
        *:*) host=${hostport%%:*}; port=${hostport#*:}; [ -n "$port" ] || return 1 ;;
        *) host=$hostport ;;
    esac
    [ -n "$host" ] || return 1
    if [ -n "$port" ]; then
        case "$port" in *[!0-9]*) return 1 ;; esac
        [ ${#port} -le 5 ] && [ "$((10#$port))" -ge 1 ] && [ "$((10#$port))" -le 65535 ] || return 1
    fi
    printf '%s' "$host" | tr '[:upper:]' '[:lower:]'
}

# A host that only ever means "this machine": unreachable from a Git provider.
# Takes a host from doctor_url_host and reads it exactly as the WHATWG URL host
# parser does (what browsers, Node and Git providers use): a host that ends in
# a number is an IPv4 address in any spelling the parser accepts (127.1,
# 0177.0.0.1, 0x7f.1, 2130706433, 0x, 127.0.0.1.) or an invalid URL
# (127.0.0.256); anything else is a domain name. Loopback: 127.0.0.0/8,
# 0.0.0.0, ::1, ::, ::ffff:127.x.y.z, localhost and *.localhost.
doctor_is_loopback_host() {
    local h=$1 v
    case "$h" in
        *:*) _doctor_ipv6_is_loopback "$h"; return ;;
    esac
    if _doctor_ends_in_number "$h"; then
        v=$(_doctor_ipv4_parse "$h") || return 1    # invalid URL: not this machine either
        [ $((v >> 24)) -eq 127 ] || [ "$v" -eq 0 ]
        return
    fi
    # A domain: "localhost." is the same name as "localhost".
    case "${h%.}" in
        localhost|*.localhost) return 0 ;;
    esac
    return 1
}

# Splits $1 on "." into _DOCTOR_PARTS, keeping empty parts (no globbing, no IFS).
_doctor_split_dots() {
    local s=$1
    _DOCTOR_PARTS=()
    while :; do
        case "$s" in
            *.*) _DOCTOR_PARTS+=("${s%%.*}"); s=${s#*.} ;;
            *) _DOCTOR_PARTS+=("$s"); return ;;
        esac
    done
}

# WHATWG "IPv4 number parser": prints the value, or fails. 0x/0X is hex (no
# digits means 0), a leading 0 is octal. A value past 2^32 prints 4294967296,
# which every range check below rejects.
_doctor_ipv4_number() {
    local s=$1 radix=10
    [ -n "$s" ] || return 1
    if [ ${#s} -ge 2 ] && { [ "${s:0:2}" = 0x ] || [ "${s:0:2}" = 0X ]; }; then
        s=${s:2}; radix=16
    elif [ ${#s} -ge 2 ] && [ "${s:0:1}" = 0 ]; then
        s=${s:1}; radix=8
    fi
    [ -n "$s" ] || { echo 0; return 0; }
    case "$radix:$s" in
        16:*[!0-9a-fA-F]*|8:*[!0-7]*|10:*[!0-9]*) return 1 ;;
    esac
    s=${s#"${s%%[!0]*}"}
    [ -n "$s" ] || { echo 0; return 0; }
    case "$radix" in
        16) [ ${#s} -le 8 ] || { echo 4294967296; return 0; }; echo $((16#$s)) ;;
        8) [ ${#s} -le 11 ] || { echo 4294967296; return 0; }; echo $((8#$s)) ;;
        *) [ ${#s} -le 10 ] || { echo 4294967296; return 0; }; echo $((10#$s)) ;;
    esac
}

# WHATWG "ends in a number checker".
_doctor_ends_in_number() {
    local last
    _doctor_split_dots "$1"
    if [ -z "${_DOCTOR_PARTS[${#_DOCTOR_PARTS[@]}-1]}" ]; then
        [ "${#_DOCTOR_PARTS[@]}" -gt 1 ] || return 1
        unset "_DOCTOR_PARTS[${#_DOCTOR_PARTS[@]}-1]"
    fi
    last=${_DOCTOR_PARTS[${#_DOCTOR_PARTS[@]}-1]}
    case "$last" in
        ""|*[!0-9]*) _doctor_ipv4_number "$last" >/dev/null ;;
        *) return 0 ;;
    esac
}

# WHATWG "IPv4 parser": prints the address as one number, or fails.
_doctor_ipv4_parse() {
    local n i v last addr=0
    local -a nums=()
    _doctor_split_dots "$1"
    n=${#_DOCTOR_PARTS[@]}
    if [ -z "${_DOCTOR_PARTS[n-1]}" ] && [ "$n" -gt 1 ]; then
        unset "_DOCTOR_PARTS[n-1]"; n=$((n - 1))
    fi
    [ "$n" -le 4 ] || return 1
    for ((i = 0; i < n; i++)); do
        v=$(_doctor_ipv4_number "${_DOCTOR_PARTS[i]}") || return 1
        nums+=("$v")
    done
    for ((i = 0; i < n - 1; i++)); do
        [ "${nums[i]}" -le 255 ] || return 1
        addr=$((addr + nums[i] * (1 << (8 * (3 - i)))))
    done
    last=${nums[n-1]}
    [ "$last" -lt $((1 << (8 * (5 - n)))) ] || return 1
    echo $((addr + last))
}

# a.b.c.d inside an IPv6 address -> its two hex groups, or fails. The IPv6
# parser takes only plain decimal parts here, 0-255, without leading zeros.
_doctor_v4_hex_groups() {
    local g
    _doctor_split_dots "$1"
    [ "${#_DOCTOR_PARTS[@]}" -eq 4 ] || return 1
    for g in "${_DOCTOR_PARTS[@]}"; do
        case "$g" in ""|*[!0-9]*|0?*) return 1 ;; esac
        [ ${#g} -le 3 ] && [ "$g" -le 255 ] || return 1
    done
    printf '%x:%x' $((_DOCTOR_PARTS[0] * 256 + _DOCTOR_PARTS[1])) $((_DOCTOR_PARTS[2] * 256 + _DOCTOR_PARTS[3]))
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
    # IPv4-mapped: ::ffff:127.x.y.z, or ::ffff:0.0.0.0.
    [ "${groups[5]}" -eq 65535 ] || return 1
    [ $((groups[6] >> 8)) -eq 127 ] && return 0
    [ "${groups[6]}" -eq 0 ] && [ "${groups[7]}" -eq 0 ]
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
