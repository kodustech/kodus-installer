# shellcheck shell=bash
# scripts/doctor-lib.sh — shared report for doctor.sh and doctor-k8s.sh.
#
# The checks used to print as they ran, so the answer to "are my reviews
# working?" sat at the bottom of a long log. Now every check records a result,
# the legacy per-check output goes to a detail log, and the report prints:
#
#   1. the verdict          Reviews: NOT RUNNING / RUNNING, DEGRADED / OK
#   2. the problems, worst first, each with what is lost and the fix
#   3. one line for everything that passed (--verbose lists them + the log)
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
# Checks whose ✘ does not fail the exit code (doctor-k8s.sh --profile dev).
DOCTOR_SOFT_APP_FAILS=false

_doctor_oneline() { printf '%s' "$1" | tr '\t\r\n' '   '; }

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

# Appends the API's results (doctor-client.mjs --format tsv) read from stdin.
# App results are tagged so --profile dev can keep them out of the exit code.
doctor_add_app_tsv() {
    local line
    while IFS= read -r line; do
        case "$line" in
            '#version'*) DOCTOR_APP_VERSION="${line#*	}" ;;
            '#'*|'') ;;
            *)
                # The api is trusted to send 6 tab-separated fields, but its
                # text can carry provider messages: drop control bytes (ANSI
                # included) and anything that is not exactly 6 fields, so the
                # renderer's columns cannot shift.
                line=$(printf '%s' "$line" | tr -d '\000-\010\013-\037\177')
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
                        "Run ./scripts/doctor.sh --verbose and share the api output with support." >> "$DOCTOR_RESULTS"
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
    if [ $rc -eq 0 ]; then
        # Here-string, not a pipe: a pipe would run it in a subshell and
        # lose DOCTOR_APP_VERSION.
        doctor_add_app_tsv <<< "$out"
    elif [ $rc -eq 42 ]; then
        doctor_add unknown reviews.doctor "" \
            "The review checks are not available in this Kodus version." \
            "" "Upgrade Kodus to a release that ships scripts/doctor/doctor-client.mjs, then run this again."
    else
        doctor_add unknown reviews.doctor "" \
            "The review checks did not run: $(printf '%s' "$out" | tail -2 | tr '\n' ' ' | cut -c1-200)" \
            "" "Check that the api is up and healthy, then run this again."
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
    if [ "$ms" -lt 6300000 ]; then
        doctor_add warn broker.consumer_timeout "" \
            "The message queue stops any job that runs longer than ${minutes} minutes." \
            "Reviews of large pull requests that take longer than ${minutes} minutes are cut off and never finish." \
            "Set consumer_timeout = 7200000 in rabbitmq.conf and restart RabbitMQ."
    else
        doctor_add ok broker.consumer_timeout "" \
            "The message queue lets jobs run up to ${minutes} minutes."
    fi
}

doctor_has_fail() {
    if [ "$DOCTOR_SOFT_APP_FAILS" = "true" ]; then
        grep -q '^fail	' "$DOCTOR_RESULTS"
    else
        grep -qE '^(app:)?fail	' "$DOCTOR_RESULTS"
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

    if [ "$nfail" -gt 0 ]; then
        echo -e "${b}${r}Reviews: NOT RUNNING${n}"
    elif [ "$nwarn" -gt 0 ]; then
        echo -e "${b}${y}Reviews: RUNNING, DEGRADED${n}"
    else
        echo -e "${b}${g}Reviews: OK${n}"
    fi
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
