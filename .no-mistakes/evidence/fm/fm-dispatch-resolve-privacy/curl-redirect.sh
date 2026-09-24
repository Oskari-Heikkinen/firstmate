#!/usr/bin/env bash
# PATH shim named `curl`: rewrites only the fixed typesafe.ai origin to the local
# capture server and execs the REAL /usr/bin/curl with every other argument,
# stdin, and fd 3 untouched, so the bytes on the wire are what the tool sends.
args=()
for a in "$@"; do args+=("${a/https:\/\/api.typesafe.ai/http://127.0.0.1:${CAPTURE_PORT:?}}"); done
printf '%s\n' "$@" >> "${CURL_ARGV_LOG:?}"
exec /usr/bin/curl "${args[@]}"
