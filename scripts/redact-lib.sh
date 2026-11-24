# shellcheck shell=bash
# scripts/redact-lib.sh — the one redactor every support bundle runs its files
# through (collect-diagnostics.sh, collect-diagnostics-compose.sh).
#
#   kodus_redact                 stdin -> stdout
#   KODUS_REDACT_VALUES_FILE     optional: a file with one known secret value
#                                per line (e.g. read from .env); every literal
#                                occurrence of one of 8+ characters is replaced
#                                before the patterns run
#
# Patterns ported from the app's doctor (kodus-ai
# apps/api/src/doctor/doctor-report.ts: INLINE_SECRET_PATTERNS, and SECRET_KEY_RE
# for key names), plus JWTs and the NAME=value / "name": "value" / name: value
# forms found in logs, YAML and JSON. Differences from the app, on purpose:
#   - kodus_ team keys need 20+ characters (a key has 43), so `kodus_workflow`
#     and other schema or container names survive;
#   - a name ending in "key" counts only after _ or - or api/secret/private/
#     access/license/signing/encryption/crypto (API_KEY, x-api-key, apiKey),
#     so routingKey and cacheKey survive; PRIVATE alone is not a secret name
#     (`"private": true` on a repository).
#
# Plain `sed -E` that GNU and BSD sed both run: no \b, \s or I flag, so word
# boundaries are spelled out and case-insensitive names are bracket classes.

_KR_KEY='([_-]|[Aa][Pp][Ii]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Pp][Rr][Ii][Vv][Aa][Tt][Ee]|[Aa][Cc][Cc][Ee][Ss][Ss]|[Ll][Ii][Cc][Ee][Nn][Ss][Ee]|[Ss][Ii][Gg][Nn][Ii][Nn][Gg]|[Ee][Nn][Cc][Rr][Yy][Pp][Tt][Ii][Oo][Nn]|[Cc][Rr][Yy][Pp][Tt][Oo])[Kk][Ee][Yy]'
_KR_WORD='([Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]|[Pp][Aa][Ss][Ss][Ww][Dd]|[Pp][Aa][Ss][Ss]|[Pp][Ww][Dd]|[Ss][Ee][Cc][Rr][Ee][Tt]|[Tt][Oo][Kk][Ee][Nn]|[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll][Ss]?|[Dd][Ss][Nn]|[Uu][Rr][Ii]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]|[Cc][Oo][Oo][Kk][Ii][Ee])'
# A secret-looking name, and what may stand before it.
_KR_NAME="[A-Za-z0-9_.-]*(${_KR_KEY}|${_KR_WORD})"
_KR_PRE='(^|[^A-Za-z0-9_.-])'

_kodus_redact_patterns() {
    LC_ALL=C sed -E \
        -e 's#([A-Za-z][A-Za-z0-9+.-]*://)[^[:space:]/@:"'\''<>]*:[^[:space:]/"'\''<>]*@#\1<redacted>@#g' \
        -e 's#([Bb][Ee][Aa][Rr][Ee][Rr]|[Bb][Aa][Ss][Ii][Cc])[[:space:]]+[A-Za-z0-9._~+/=-]{8,}#\1 <redacted>#g' \
        -e 's#eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*#<redacted-jwt>#g' \
        -e 's#(^|[^A-Za-z0-9_-])(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|glpat-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AIza[A-Za-z0-9_-]{20,}|kodus_[A-Za-z0-9_-]{20,})#\1<redacted>#g' \
        -e 's#[A-Za-z0-9_-]*[*]{4,}[A-Za-z0-9_-]*#<redacted>#g' \
        -e "s#${_KR_PRE}(\"${_KR_NAME}\"[[:space:]]*:[[:space:]]*)\"([^\"\\\\]|\\\\.)*\"#\\1\\2\"<redacted>\"#g" \
        -e "s#${_KR_PRE}(${_KR_NAME}=)\"[^\"]*\"#\\1\\2\"<redacted>\"#g" \
        -e "s#${_KR_PRE}(${_KR_NAME}=)'[^']*'#\\1\\2'<redacted>'#g" \
        -e "s#${_KR_PRE}(${_KR_NAME}=)[^[:space:]\"'&,;<]+#\\1\\2<redacted>#g" \
        -e "s#${_KR_PRE}(${_KR_NAME}:[[:space:]]+)[^[:space:]<].*\$#\\1\\2<redacted>#"
}

# Replaces every literal occurrence of the values in <file> (longest first).
_kodus_redact_values() {
    LC_ALL=C awk -v f="$1" '
        BEGIN {
            while ((getline v < f) > 0) if (length(v) >= 8) s[++n] = v
            for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++)
                if (length(s[j]) > length(s[i])) { t = s[i]; s[i] = s[j]; s[j] = t }
        }
        {
            line = $0
            for (i = 1; i <= n; i++) {
                out = ""
                while ((p = index(line, s[i])) > 0) {
                    out = out substr(line, 1, p - 1) "<redacted>"
                    line = substr(line, p + length(s[i]))
                }
                line = out line
            }
            print line
        }'
}

kodus_redact() {
    if [ -n "${KODUS_REDACT_VALUES_FILE:-}" ] && [ -s "$KODUS_REDACT_VALUES_FILE" ]; then
        _kodus_redact_values "$KODUS_REDACT_VALUES_FILE" | _kodus_redact_patterns
    else
        _kodus_redact_patterns
    fi
}

# Drops terminal colour codes, so a captured report reads as plain text.
kodus_strip_ansi() { sed "s/$(printf '\033')\[[0-9;]*m//g"; }

# Runs every regular file under <dir> through kodus_redact, in place.
kodus_redact_tree() {
    local f
    find "$1" -type f | while IFS= read -r f; do
        kodus_redact < "$f" > "$f.redacting" && mv "$f.redacting" "$f"
    done
}
