# ReMe on Railway

[ReMe](https://github.com/agentscope-ai/ReMe) — a self-evolving memory workspace for AI agents, storing
durable memory as ordinary Markdown with frontmatter and wikilinks — on Railway, with the workspace on
a volume and the whole service behind a generated password.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/reme)

## Services

| Process | Base | Public | Role |
|---|---|---|---|
| `caddy` | `caddy:2.11.4` (binary) | **yes** | The only public listener. Holds the credential, proxies to ReMe. |
| `reme` | `reme-ai[core]` 0.4.1.12 | no | API, `/mcp`, Studio UI. Stays on `127.0.0.1` where upstream puts it. |

One container, one volume. Both processes are supervised by the entrypoint: if either exits, the
container exits and Railway restarts it.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `REME_PASSWORD` | generated, 24 chars | The credential for the UI, the HTTP API and the MCP endpoint. Read it from the service variables after deploying. |
| `REME_USERNAME` | `admin` | Username for the same. |
| `LLM_API_KEY` | *(empty)* | Optional. Enables `auto_memory`, `auto_resource`, `auto_dream` and proactive refresh. |
| `LLM_BASE_URL` | *(empty)* | Optional. Any OpenAI-compatible endpoint. |
| `PORT` | `8080` | The port Railway's healthcheck probes and the domain targets. Leave it alone. |
| `REME_WORKSPACE_DIR` | `/data/workspace` | Baked. The Markdown workspace on the volume. |

The deploy form asks for nothing you have to invent.

## First run

1. Copy `REME_PASSWORD` from the service's **Variables** tab.
2. Open the public domain and sign in as **`admin`**. That is ReMe Studio — browse, edit and search
   the workspace.
3. Point an agent at `https://your-app.up.railway.app/mcp` with the same credentials.

BM25 search, file operations and wikilink traversal all work with no keys at all. Add `LLM_API_KEY`
only if you want ReMe to generate and refine memory on its own.

One wrinkle worth knowing: ReMe builds its LLM client *while the service starts*, because AgentScope
initialises models eagerly, so an empty `LLM_API_KEY` aborts the boot entirely — upstream's README
says the keyless features work, and locally they do, but the process never reaches the point of
serving. The entrypoint therefore supplies a placeholder when no key is set, which is what makes the
keyless half actually work here. Anything that calls a model then fails at call time with a provider
auth error, which is the truthful result for a deployment with no key. Embeddings are off by default; enable
`components.as_embedding` and `components.embedding_store` in the config for semantic retrieval.

## Security

**ReMe has no authentication, and that is by design.** Upstream's security boundary section is worth
quoting in full, because it is the reason this template is shaped the way it is:

> ReMe is local-first: the default binds to `127.0.0.1`; HTTP CORS allows any origin; Jobs may write,
> move, or delete files; the service layer has no general-purpose user authentication.
>
> Remote access must be enabled explicitly with `reme start service.host=0.0.0.0`. Do not expose the
> service directly to the public internet. Place it on a controlled network or behind an
> authenticated TLS reverse proxy, apply access controls and request-size limits, and expose only
> necessary Jobs.

So this template does not expose it directly. Railway terminates TLS at the edge, Caddy holds a
generated credential, and **ReMe keeps its default `127.0.0.1` bind** — `service.host=0.0.0.0` is
never set, so there is no misconfiguration that can publish the unauthenticated API. The container
refuses to start without a password of at least 12 characters.

The credential is hashed with bcrypt through stdin rather than a command-line flag, so it never
appears in the container's argv.

On CORS: ReMe sends `Access-Control-Allow-Origin: *`, and its own code disables
`allow_credentials` whenever the origin list is `*`. Combined with the proxy — which rejects anything
without credentials before it reaches ReMe — a cross-origin page cannot read the API.

The honest caveat: this is a file-mutating API behind one password. Treat the URL accordingly, and if
you enable the LLM features, remember that jobs then spend your provider key.

## Why it is shaped this way

- **A proxy, not a patch.** ReMe has no auth to switch on, so unlike most templates here there was
  nothing to make mandatory — the credential has to come from somewhere, and upstream names a reverse
  proxy as the supported answer.
- **ReMe stays on loopback.** The safest configuration is the one where the risky setting is never
  set at all.
- **`/healthz` is answered by Caddy.** Railway's healthcheck carries no credentials, so it cannot be
  pointed at a ReMe route without punching a hole in the proxy. ReMe's own liveness is covered by the
  entrypoint instead.
- **The proxy starts only after ReMe answers**, so a healthy check never fronts a service that would
  still return 502.
- **`flush_interval -1`** disables response buffering, which the streamable HTTP MCP endpoint and
  ReMe's SSE job responses need.
- **`restartPolicyType: ALWAYS`**, with the entrypoint taking the container down if either process
  dies.
- **SIGTERM is forwarded to both children.** Without the trap the shell sat in `wait` and every stop
  ended in SIGKILL after the full timeout — measured `exit=137`. With it, shutdown is `exit=0` in
  under three seconds, which is also why the policy has to be `ALWAYS` rather than `ON_FAILURE`.

## Reproducible builds

ReMe publishes no container image — no Dockerfile, no compose file, nothing in its docs — so this
image is built here from PyPI. That makes `pip install` a resolution step rather than a fixed
artefact, which is why all 149 resolved packages are pinned with hashes in `requirements.lock` and
installed with `--require-hashes`. A rebuild installs exactly what was tested, and an upstream
re-upload fails the build instead of silently changing the image.

To update:

```bash
# bump the two versions, then regenerate the lock on the deploy architecture
docker run --rm --platform linux/amd64 -v "$PWD":/w -w /w python:3.12-slim \
  sh -c 'pip install -q uv==0.9.5 && uv pip compile requirements.in -o requirements.lock --generate-hashes --python-version 3.12'
```

Note `reme-ai` declares `reme_studio` with no version constraint, so the lock is what keeps Studio
from drifting.

## What persists

`/data/workspace` holds the entire memory: daily notes, digests, indexes and metadata, all as
Markdown you can read and edit. Indexes rebuild from the files.

## Licences

ReMe is [Apache-2.0](https://github.com/agentscope-ai/ReMe/blob/main/LICENSE). Caddy is Apache-2.0.
The glue in this repository is MIT.
