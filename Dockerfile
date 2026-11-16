# ReMe on Railway.
#
# Unlike the rest of this portfolio there is no upstream image to pin: ReMe
# ships as a pip package with no Dockerfile, no compose file and no container
# documentation at all. So this image is built here, and `requirements.lock`
# pins all 142 resolved packages with hashes so a rebuild six months from now
# produces what was tested rather than whatever PyPI resolves that day.
ARG CADDY_VERSION=2.11.9
ARG PYTHON_VERSION=3.12-slim

FROM caddy:${CADDY_VERSION} AS caddy-src

FROM python:${PYTHON_VERSION}

# Upstream's own security boundary is explicit: the service layer has no
# authentication of any kind, CORS allows any origin, jobs may write, move or
# delete files, and "Do not expose the service directly to the public
# internet. Place it ... behind an authenticated TLS reverse proxy."
#
# That is exactly this image's shape. Railway terminates TLS at the edge and
# Caddy supplies the authentication half, while ReMe keeps its DEFAULT
# 127.0.0.1 bind and never listens on a public interface at all. Caddy is a
# static Go binary, so it is copied rather than installed.
COPY --from=caddy-src /usr/bin/caddy /usr/local/bin/caddy

# Hash-pinned install. --require-hashes makes pip refuse any package whose
# artefact does not match the lock, so an upstream re-upload fails the build
# instead of silently changing the image.
COPY requirements.lock /tmp/requirements.lock
# The smoke test imports the package rather than running `reme version`: every
# `reme <action>` is a client that looks for a running service first, so it
# fails with a connection error at build time and proves nothing.
RUN pip install --no-cache-dir --require-hashes -r /tmp/requirements.lock \
 && rm -f /tmp/requirements.lock \
 && python -c "import reme; import reme_studio; print('reme + studio import ok')"

# The workspace is plain Markdown with frontmatter and wikilinks, so the whole
# durable state of the service is this one directory on the Railway volume.
ENV REME_WORKSPACE_DIR=/data/workspace \
    REME_INTERNAL_PORT=2333 \
    PORT=8080

COPY Caddyfile /etc/caddy/Caddyfile
# Semantic retrieval overlay; the entrypoint applies it only when
# EMBEDDING_API_KEY is set.
COPY embeddings.yaml /etc/reme/embeddings.yaml
COPY --chmod=755 entrypoint.sh /usr/local/bin/railway-entrypoint
ENTRYPOINT ["/usr/local/bin/railway-entrypoint"]
