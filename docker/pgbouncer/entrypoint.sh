#!/bin/sh
# Entrypoint of the optional db_kodus_pgbouncer service (Compose profile
# `pgbouncer`). Kodus sends statement_timeout and
# idle_in_transaction_session_timeout when it connects, so PgBouncer has to
# track them, and the image has no env for track_extra_parameters.
#
#   entrypoint.sh              write the ini if missing, add the parameters,
#                              start pgbouncer
#   entrypoint.sh merge <ini>  only add the parameters to <ini> (tests)
set -eu

need=statement_timeout,idle_in_transaction_session_timeout

# Adds the parameters Kodus needs to <ini>, read once:
# - appended to each track_extra_parameters line that lacks one, whose text is
#   otherwise kept as written (the last assignment wins, so a second line
#   would drop the parameters already there);
# - else as a line right under [pgbouncer];
# - else with a [pgbouncer] section at the end.
# awk exits 10 when nothing is missing, and only then is the file left alone:
# an ini that already has them can be mounted read-only, whatever its line
# endings. Otherwise it is written back in place, so a mounted file works.
# An empty file is left as it is.
merge() {
	ini=$1
	[ -s "$ini" ] || return 0
	merged=$(mktemp)
	awk -v need="$need" '
		{
			line[NR] = $0
			l = $0; sub(/\r$/, "", l)
			if (l ~ /^[ \t]*track_extra_parameters[ \t]*=/) { tracked[NR] = 1; ntracked++ }
			else if (!head && l ~ /^[ \t]*\[pgbouncer\][ \t]*([;#].*)?$/) head = NR
		}
		END {
			n = split(need, req, ",")
			for (i = 1; i <= NR; i++) {
				out = line[i]
				if (i in tracked) {
					cr = ""; if (out ~ /\r$/) { cr = "\r"; sub(/\r$/, "", out) }
					v = out; sub(/^[^=]*=/, "", v); gsub(/[ \t]/, "", v)
					missing = ""
					for (j = 1; j <= n; j++)
						if (index("," v ",", "," req[j] ",") == 0) missing = missing (missing == "" ? "" : ",") req[j]
					if (missing != "") {
						sub(/[ \t]+$/, "", out)
						out = out (v == "" ? " " : ",") missing
						changed = 1
					}
					out = out cr
				}
				print out
				if (i == head && !ntracked) { print "track_extra_parameters = " need; changed = 1 }
			}
			if (!head && !ntracked) { print ""; print "[pgbouncer]"; print "track_extra_parameters = " need; changed = 1 }
			exit changed ? 0 : 10
		}
	' "$ini" >"$merged" || status=$?
	case ${status:-0} in
	10) ;;
	0)
		if ! [ -s "$merged" ] || ! cat "$merged" >"$ini"; then
			rm -f "$merged"
			echo "kodus: $ini must set track_extra_parameters to include $need, and it cannot be written" >&2
			exit 1
		fi
		;;
	*)
		rm -f "$merged"
		echo "kodus: could not read $ini" >&2
		exit 1
		;;
	esac
	rm -f "$merged"
}

if [ "${1:-}" = merge ]; then
	merge "$2"
	exit 0
fi

ini=/etc/pgbouncer/pgbouncer.ini
# The image's entrypoint writes the ini when it is missing, whatever the
# command, then runs the command: `true` here, so the parameters can be added
# before pgbouncer starts.
/entrypoint.sh true
merge "$ini"
exec pgbouncer "$ini"
