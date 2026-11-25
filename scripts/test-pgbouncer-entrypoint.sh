#!/usr/bin/env bash
# docker/pgbouncer/entrypoint.sh in the image Compose runs it in: the ini it
# leaves behind, when it writes it, and that pgbouncer starts with it.
set -euo pipefail

cd "$(dirname "$0")/.."
image=$(awk '/db_kodus_pgbouncer:/{s=1} s && /image:/{print $2; exit}' docker-compose.yml)
script=$PWD/docker/pgbouncer/entrypoint.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
need='track_extra_parameters = statement_timeout,idle_in_transaction_session_timeout'
failed=0

# case <name> <mount mode rw|ro> <expected exit> <input> <expected output>
case_() {
	local name=$1 mode=$2 want_code=$3 input=$4 want=$5 code=0
	printf '%s' "$input" >"$work/ini"
	printf '%s' "$want" >"$work/want"
	# The container runs as the image's postgres user, not the file's owner.
	chmod 666 "$work/ini"
	docker run --rm -v "$script:/e.sh:ro" -v "$work/ini:/w/pgbouncer.ini:$mode" \
		--entrypoint sh "$image" /e.sh merge /w/pgbouncer.ini >"$work/out" 2>&1 || code=$?
	# Byte for byte: a command substitution would drop trailing newlines.
	if [ "$code" != "$want_code" ] || ! cmp -s "$work/ini" "$work/want"; then
		failed=1
		echo "FAIL $name (exit $code, want $want_code)"
		echo "--- got";  cat "$work/ini"; echo
		echo "--- want"; cat "$work/want"; echo
		echo "--- output"; cat "$work/out"
	else
		echo "ok   $name"
	fi
}

generated=$'[databases]\n* = host=db port=5432\n\n[pgbouncer]\nlisten_addr = 0.0.0.0\n'

case_ 'no line: added under [pgbouncer]' rw 0 \
	"$generated" $'[databases]\n* = host=db port=5432\n\n[pgbouncer]\n'"$need"$'\nlisten_addr = 0.0.0.0\n'
case_ 'already there: read-only mount starts' ro 0 \
	$'[pgbouncer]\n'"$need"$'\n' $'[pgbouncer]\n'"$need"$'\n'
case_ 'complete value in another order, with spaces: left as written' ro 0 \
	$'[pgbouncer]\ntrack_extra_parameters = idle_in_transaction_session_timeout, statement_timeout\n' \
	$'[pgbouncer]\ntrack_extra_parameters = idle_in_transaction_session_timeout, statement_timeout\n'
case_ 'other parameters tracked: merged into the one line' rw 0 \
	$'[pgbouncer]\ntrack_extra_parameters = lock_timeout\n' \
	$'[pgbouncer]\ntrack_extra_parameters = lock_timeout,statement_timeout,idle_in_transaction_session_timeout\n'
case_ 'one of the two tracked: the other is added' rw 0 \
	$'[pgbouncer]\ntrack_extra_parameters = statement_timeout\n' \
	$'[pgbouncer]\n'"$need"$'\n'
case_ 'no [pgbouncer] section: one is added' rw 0 \
	$'[databases]\n* = host=db\n' $'[databases]\n* = host=db\n\n[pgbouncer]\n'"$need"$'\n'
case_ 'header with a comment and CRLF endings' rw 0 \
	$'[databases]\r\n* = host=db\r\n[pgbouncer] ; pooler\r\nlisten_port = 5432\r\n' \
	$'[databases]\r\n* = host=db\r\n[pgbouncer] ; pooler\r\n'"$need"$'\nlisten_port = 5432\r\n'
case_ 'CRLF line missing one: merged, CR kept' rw 0 \
	$'[pgbouncer]\r\ntrack_extra_parameters = lock_timeout\r\n' \
	$'[pgbouncer]\r\ntrack_extra_parameters = lock_timeout,statement_timeout,idle_in_transaction_session_timeout\r\n'
case_ 'already there, no final newline: read-only mount starts' ro 0 \
	$'[pgbouncer]\n'"$need" $'[pgbouncer]\n'"$need"
case_ 'missing, no final newline: line added' rw 0 \
	$'[pgbouncer]\nlisten_port = 5432' $'[pgbouncer]\n'"$need"$'\nlisten_port = 5432\n'
case_ 'line text kept as written, missing names appended' rw 0 \
	$'[pgbouncer]\ntrack_extra_parameters = lock_timeout ; set by ops  \n' \
	$'[pgbouncer]\ntrack_extra_parameters = lock_timeout ; set by ops,statement_timeout,idle_in_transaction_session_timeout\n'
case_ 'empty value: names added' rw 0 \
	$'[pgbouncer]\ntrack_extra_parameters =\n' $'[pgbouncer]\n'"$need"$'\n'
case_ 'missing and read-only: refuses to start' ro 1 \
	"$generated" "$generated"
case_ 'empty file: left as it is' rw 0 '' ''

# The whole entrypoint: the image writes the ini, the line is added once,
# pgbouncer runs, and a restart changes nothing.
name=kodus-pgbouncer-entrypoint-test-$$
docker run -d --name "$name" -v "$script:/kodus/pgbouncer-entrypoint.sh:ro" \
	-e DB_HOST=127.0.0.1 -e DB_USER=kodus -e DB_PASSWORD=kodus -e DB_NAME=kodus \
	-e POOL_MODE=transaction -e AUTH_TYPE=scram-sha-256 \
	--entrypoint /bin/sh "$image" /kodus/pgbouncer-entrypoint.sh >/dev/null
trap 'docker container rm -f "$name" >/dev/null 2>&1; rm -rf "$work"' EXIT
check_running() {
	local label=$1 lines
	for _ in $(seq 1 20); do
		docker exec "$name" pg_isready -q -h 127.0.0.1 -p 5432 2>/dev/null && break
		sleep 0.5
	done
	lines=$(docker exec "$name" grep -cxF "$need" /etc/pgbouncer/pgbouncer.ini || true)
	if [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] &&
		docker exec "$name" pg_isready -q -h 127.0.0.1 -p 5432 && [ "$lines" = 1 ]; then
		echo "ok   $label"
	else
		failed=1
		echo "FAIL $label (line count $lines)"
		docker logs "$name" 2>&1 | tail -20
	fi
}
check_running 'entrypoint: fresh container listens with the line once'
docker restart "$name" >/dev/null
check_running 'entrypoint: restarted container, still once'

exit "$failed"
