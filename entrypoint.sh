#!/bin/bash
set -euo pipefail

LISTEN_PORT="${PORT:-8080}"
INTERNAL_PORT="${REME_INTERNAL_PORT:-2333}"
WORKSPACE="${REME_WORKSPACE_DIR:-/data/workspace}"
REME_USERNAME="${REME_USERNAME:-admin}"

# ---------------------------------------------------------------------------
# Fail closed on the proxy credential
# ---------------------------------------------------------------------------
# ReMe has no authentication of its own — upstream states plainly that "the
# service layer has no general-purpose user authentication" and that jobs may
# write, move or delete files. The Caddy credential in front of it is therefore
# not a hardening measure, it is the only thing between the public domain and
# a file-mutating API, so the container refuses to start without one.
if [ -z "${REME_PASSWORD:-}" ] || [ "${#REME_PASSWORD}" -lt 12 ]; then
    echo "FATAL: REME_PASSWORD is empty or shorter than 12 characters." >&2
    echo "  It is the only credential protecting this deployment: ReMe itself has" >&2
    echo "  no authentication, and its API can create, move and delete files in the" >&2
    echo "  workspace. The template generates a password; read it from the service's" >&2
    echo "  Variables tab." >&2
    exit 1
fi

# Hashed through stdin rather than `--plaintext`, so the password never appears
# in this container's argv and cannot be read out of `ps`.
REME_PASSWORD_HASH="$(printf '%s\n' "${REME_PASSWORD}" | caddy hash-password)"
unset REME_PASSWORD
export REME_PASSWORD_HASH REME_USERNAME
export PORT="${LISTEN_PORT}" REME_INTERNAL_PORT="${INTERNAL_PORT}"

# ---------------------------------------------------------------------------
# Workspace on the volume
# ---------------------------------------------------------------------------
# ReMe's durable state is ordinary Markdown with frontmatter and wikilinks, so
# the whole memory lives in this one directory and can be read, edited and
# backed up with any tool.
mkdir -p "${WORKSPACE}"

# ---------------------------------------------------------------------------
# LLM credential
# ---------------------------------------------------------------------------
# ReMe builds its LLM client while the service starts — AgentScope initialises
# models eagerly — so an empty LLM_API_KEY aborts the boot outright, even
# though BM25 search, file operations and wikilink traversal need no model at
# all. Upstream's README says those work without credentials; in a container
# they do not, because the process never reaches the point of serving.
#
# A placeholder lets the service start, so the keyless half genuinely works.
# Anything that actually calls a model then fails at call time with the
# provider's own auth error, which is the honest outcome for a deployment that
# has not configured a key.
if [ -z "${LLM_API_KEY:-}" ]; then
    export LLM_API_KEY="not-configured"
    echo "reme: no LLM_API_KEY set - search, read and write work; auto_memory," \
         "auto_resource, auto_dream and proactive refresh will not until you add one"
fi

echo "reme: workspace at ${WORKSPACE}"
echo "reme: serving on 0.0.0.0:${LISTEN_PORT} behind basic auth as '${REME_USERNAME}'"

# ---------------------------------------------------------------------------
# ReMe on loopback, Caddy in front
# ---------------------------------------------------------------------------
# ReMe keeps its own default 127.0.0.1 bind and is never given a public
# interface. `service.host=0.0.0.0` is deliberately NOT set: the only route in
# is through Caddy, which means there is no configuration mistake that can
# expose the unauthenticated API directly.
reme start workspace_dir="${WORKSPACE}" service.port="${INTERNAL_PORT}" &
REME_PID=$!

# Caddy starts only once ReMe answers, so Railway's healthcheck cannot report
# the deployment live while requests would still 502.
ready=""
for _ in $(seq 1 180); do
    if python3 - "$INTERNAL_PORT" <<'PY' 2>/dev/null
import sys, urllib.request
try:
    urllib.request.urlopen(f"http://127.0.0.1:{sys.argv[1]}/", timeout=2)
except urllib.error.HTTPError:
    pass  # any HTTP status means the server is answering
sys.exit(0)
PY
    then ready=1; break; fi
    if ! kill -0 "${REME_PID}" 2>/dev/null; then
        echo "FATAL: reme exited during startup." >&2
        exit 1
    fi
    sleep 1
done
if [ -z "${ready}" ]; then
    echo "FATAL: reme did not answer on 127.0.0.1:${INTERNAL_PORT} within 180s." >&2
    exit 1
fi
echo "reme: ready, starting proxy"

caddy run --config /etc/caddy/Caddyfile --adapter caddyfile &
CADDY_PID=$!

# Forward SIGTERM to both children. Without this the shell sits in `wait` and
# ignores the signal, so every redeploy ends in SIGKILL (exit 137) with the
# index mid-write. Measured before the trap existed; measured again after.
shutdown() {
    echo "reme: signal received, stopping both processes" >&2
    kill -TERM "${REME_PID}" "${CADDY_PID}" 2>/dev/null || true
    wait "${REME_PID}" 2>/dev/null || true
    wait "${CADDY_PID}" 2>/dev/null || true
    exit 0
}
trap shutdown TERM INT

# Either process dying takes the container down, so Railway's ALWAYS policy
# restarts it. Without this the proxy would happily keep serving 502s from a
# healthy-looking container.
wait -n "${REME_PID}" "${CADDY_PID}"
status=$?
echo "reme: a supervised process exited (status ${status}); shutting down" >&2
kill "${REME_PID}" "${CADDY_PID}" 2>/dev/null || true
exit "${status:-1}"
