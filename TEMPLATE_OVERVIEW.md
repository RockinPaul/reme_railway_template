# Deploy and Host ReMe on Railway

[ReMe](https://github.com/agentscope-ai/ReMe) is a self-evolving memory workspace for AI agents. It
turns conversations and documents into ordinary Markdown notes with frontmatter and wikilinks, then
retrieves them precisely with BM25, wikilink expansion and optional embeddings — so an agent recalls
the relevant lines rather than loading a whole knowledge base into its context.

This template runs it on Railway with the workspace on a volume and the whole service behind a
generated password, because ReMe has no authentication of its own. One service, one volume, a public
domain.

## About Hosting ReMe

ReMe is a single Python service. The HTTP API, a streamable-HTTP MCP endpoint at `/mcp` and the ReMe
Studio web UI all share one port, so there is no database, no broker and no second container to wire
up. Agents reach the same workspace over MCP, HTTP or the CLI, which is the point: one memory, many
agents.

Everything durable is Markdown on the volume. You can read it, edit it in Studio, grep it, or pull it
down and keep it — indexes and generated metadata rebuild themselves from the files.

The part this template has to supply is authentication. Upstream is unusually direct about it: the
service binds loopback by default, CORS allows any origin, jobs may write, move or delete files, and
"the service layer has no general-purpose user authentication". Its own guidance for remote use is to
place it behind an authenticated reverse proxy — so that is what runs here, with ReMe left on
`127.0.0.1` where upstream puts it.

## Why Deploy ReMe on Railway?

- **One memory your agents can share**, reachable from anywhere over MCP or HTTP instead of living on
  a single laptop.
- **It stays awake.** Background indexing and scheduled consolidation keep running with no machine of
  your own left on.
- **No assembly.** No database, no vector store, no second service.
- **Nothing is locked in.** The workspace is Markdown on a volume; take it with you at any time.
- **Reproducible builds.** Every dependency is hash-pinned, so a rebuild months from now installs
  exactly what was tested.

## Common Use Cases

- A shared long-term memory for coding agents and assistants that speak MCP.
- A personal knowledge base that an agent maintains for you and you can still edit by hand.
- Capturing conversations into durable notes and refining them over time.
- A searchable workspace that several agent runtimes read and write at once.

## Dependencies for ReMe Hosting

- Nothing required. BM25 search, file operations and wikilink traversal all work with no credentials.
- Optional: an LLM key for the features that generate and refine memory automatically.

### Deployment Dependencies

- Upstream project: [agentscope-ai/ReMe](https://github.com/agentscope-ai/ReMe) (Apache-2.0),
  package `reme-ai[core]` 0.4.2.2 with `reme-studio` 0.1.1.
- Upstream documentation: [ReMe docs](https://reme.agentscope.io/).
- Template source: [RockinPaul/reme_railway_template](https://github.com/RockinPaul/reme_railway_template) (MIT).

### Implementation Details

**After deploying:** copy `REME_PASSWORD` from the service's Variables tab, open the public domain
and sign in as **`admin`**. That same credential authenticates the HTTP API and the MCP endpoint.

**Why there is a proxy in front.** ReMe is local-first by design and says so: no authentication in
the service layer, CORS open to any origin, and jobs that can write, move or delete files. Upstream's
instruction for remote access is to put it behind an authenticated reverse proxy rather than exposing
it directly, and this template does exactly that — Railway terminates TLS at the edge, Caddy holds
the credential, and ReMe keeps its default `127.0.0.1` bind so there is no configuration mistake that
can publish the unauthenticated API. `service.host=0.0.0.0` is deliberately never set.

**Optional LLM key.** `LLM_API_KEY` and `LLM_BASE_URL` enable `auto_memory`, `auto_resource`,
`auto_dream` and proactive refresh — the features that turn raw conversation into refined notes.
Leave them empty and ReMe still works as a searchable, agent-writable Markdown workspace. That took
one fix to be true in a container: ReMe constructs its LLM client while the service starts, so an
empty key aborts the boot before anything is served. The entrypoint supplies a placeholder when no
key is configured, and model-backed jobs then fail at call time rather than at startup.

**Optional semantic search.** Out of the box ReMe searches with BM25 and wikilinks. Add
`EMBEDDING_API_KEY` to the service and it also searches by meaning, fused with BM25, so a note is
found even when it shares no words with the query. The defaults are ReMe's own — `text-embedding-v4`
at 1024 dimensions on DashScope. A cheap alternative is Perplexity's embedding model through
[OpenRouter](https://openrouter.ai/perplexity/pplx-embed-v1-0.6b): set `EMBEDDING_BASE_URL` to
`https://openrouter.ai/api/v1` and `EMBEDDING_MODEL_NAME` to `perplexity/pplx-embed-v1-0.6b`.
Notes you already have are embedded on the next boot, vectors are cached on the volume, and without a
key the deployment runs exactly as before. Proactive refresh's `known_threshold` of 0.85 is tuned for
the default model; other models score lower (about 0.4 for a related pair with the Perplexity model),
which affects only that feature, not search.

**Builds are reproducible.** ReMe publishes no container image, so this one is built here and all 142
resolved packages are pinned with hashes in `requirements.lock`. `pip --require-hashes` refuses
anything that does not match, so an upstream re-upload fails the build rather than quietly changing
the image.

**Notes.** `PORT` is 8080 and the proxy follows it; the healthcheck is `/healthz`, answered by the
proxy itself so it needs no credentials and exposes no ReMe route. If ReMe exits, the container exits
and Railway restarts it, so a healthy check always means a serving service.

## Licences

ReMe is Apache-2.0. Caddy is Apache-2.0. The template's glue is MIT.
