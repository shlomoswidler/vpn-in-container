#!/bin/bash

# Start the VPN container stack, wait until every service is healthy, then
# open the web interfaces.
#
# PUID and PGID: a value from the environment or from .env is used as it is
# (Compose reads .env itself; the environment wins over .env). Only when
# neither sets one does this script use your own IDs (id -u, id -g).
# START_WAIT_TIMEOUT: seconds to wait for the services (default 300).

set -euo pipefail

cd "$(dirname "$0")"

WAIT_TIMEOUT="${START_WAIT_TIMEOUT:-300}"
URLS=("http://localhost:5800" "http://localhost:9080")

# Cross-platform URL opener
open_url() {
    local url="$1"
    if command -v xdg-open &>/dev/null; then
        xdg-open "$url" 2>/dev/null &
    elif command -v open &>/dev/null; then
        open "$url"
    else
        echo "  Open manually: $url"
    fi
}

# Prints the value .env gives NAME (its last assignment), or nothing. .env is
# read as text, never run: the value is what Compose reads for the simple
# forms (unquoted, with an optional " # comment" after it, or in single or
# double quotes). Interpolation such as ${VAR} is not applied.
env_file_value() {
    [[ -f .env ]] || return 0
    NAME="$1" awk '
        BEGIN { name = ENVIRON["NAME"] }
        {
            line = $0
            sub(/^[ \t]*/, "", line)
            sub(/^export[ \t]+/, "", line)
            if (index(line, name) != 1) next
            rest = substr(line, length(name) + 1)
            if (rest !~ /^[ \t]*=/) next
            sub(/^[ \t]*=[ \t]*/, "", rest)
            quote = substr(rest, 1, 1)
            if (quote == "\"" || quote == "'\''") {
                rest = substr(rest, 2)
                end = index(rest, quote)
                value = end ? substr(rest, 1, end - 1) : rest
            } else {
                end = index(rest, " #")
                value = end ? substr(rest, 1, end - 1) : rest
                sub(/[ \t]+$/, "", value)
            }
            found = 1
        }
        END { if (found) print value }
    ' .env
}

# Checks the user or group ID NAME (from id -FLAG), and uses DETECTED when
# neither the environment nor .env sets one.
check_id() {
    local name="$1" flag="$2" detected="$3" value source
    value="${!name:-}"
    source="the environment"
    if [[ -z "$value" ]]; then
        value=$(env_file_value "$name")
        source=".env"
    fi
    if [[ -z "$value" ]]; then
        export "$name=$detected"
        echo "$name not set; using $detected"
    elif [[ ! "$value" =~ ^[0-9]+$ ]]; then
        echo "$name from $source is '$value', not a number." >&2
        echo "Set it to the output of 'id -$flag' (comments in .env go on their own line)." >&2
        exit 1
    fi
}

if [[ ! "$WAIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "START_WAIT_TIMEOUT must be a whole number of seconds, not '$WAIT_TIMEOUT'" >&2
    exit 1
fi
check_id PUID u "$(id -u)"
check_id PGID g "$(id -g)"

# Every service in docker-compose.yml must be running and healthy (each has a
# healthcheck). Compose v5.5.0's --wait-timeout can exit 0 when the time runs
# out (fixed in v5.5.1), so this checks for itself as well.
all_healthy() {
    local expected actual
    expected=$(docker compose config --services | sort)
    actual=$(docker compose ps -a --format '{{.Service}}	{{.State}}	{{.Health}}' |
        awk -F '\t' '$2 == "running" && $3 == "healthy" { print $1 }' | sort)
    [[ -n "$expected" && "$actual" == "$expected" ]]
}

echo "Starting containers and waiting until all are healthy (up to ${WAIT_TIMEOUT}s)..."
if ! docker compose up -d --wait --wait-timeout "$WAIT_TIMEOUT" || ! all_healthy; then
    {
        echo "Some services did not become healthy within ${WAIT_TIMEOUT}s:"
        docker compose ps -a --format '{{.Service}}	{{.State}}	{{.Health}}' || true
        echo "See: docker compose logs <service>"
    } >&2
    exit 1
fi

echo "Opening web interfaces..."
for url in "${URLS[@]}"; do
    open_url "$url"
done

echo "Done! Services are running."
echo "  Firefox:     ${URLS[0]}"
echo "  qBittorrent: ${URLS[1]}"
