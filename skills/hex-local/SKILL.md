---
name: hex-local
description: For Elixir and Erlang developers using AI coding agents. Use when a task needs version-matched API documentation, configuration examples, Hex library discovery, or investigation of unexpected dependency behavior. Guides the agent to retrieve HexDocs and core Elixir docs, check upstream issues, and cite the versions it used. Includes workflows for local debugging knowledge. Requires a separately installed and connected Hex Local MCP server; this skill does not install the server or configure provider credentials.
---

# Hex Local

Use published documentation for the package and version the project actually runs.
Turn retrieved evidence into an answer or implementation, with exact citations.

Requires a separately installed Hex Local MCP server connected to the coding
agent. Documentation ingestion and semantic search need a configured embedding
provider: hosted credentials or a local provider such as Ollama. Provider setup
is separate from installing this skill. This package contains agent instructions
and supporting references, not the MCP server or an installer.

## Choose the evidence

| Need | First choice |
| --- | --- |
| Public API, configuration, types, examples, macro-generated functions | `search_docs` |
| A technology or capability without a known package, such as a NATS client | `search_hex_packages`, then `search_docs` for the selected package |
| Implementation details or local call sites | Read repository or dependency source |
| Unexpected dependency behavior or a suspected upstream fix | `search_github_issues`; authenticated `gh` is also suitable |
| A repeated failure or a lesson worth retaining | Read [debugging and memory](references/debugging-and-memory.md) |

Discover these tools under the connected MCP server, usually named `hex_local`.
Use the exposed schemas; client prefixes vary. This skill does not establish a
connection or install the server. If unavailable, state that briefly and continue
with available source or official documentation. Do not invent tool results.

## Search the right package and version

- Always pass the Hex **package name** in `package`, even when it is not indexed.
  Unknown packages trigger ingestion. A module name is not necessarily a package.
- Discover a package with `search_hex_packages(query: "nats")` when only a
  technology is known. Do not guess `nats` is the package; results may identify
  a differently named client such as `gnat`. Downloads indicate adoption, not
  maintenance or compatibility.
- If `PROJECT_ROOT` is known to point at the project being edited, omit `version`
  for its dependencies: the server reads that project's `mix.lock` on each lookup.
- Otherwise inspect the project's lockfile and pass its exact dependency version.
  Do not infer it from `app_version`: that is the server's own dependency version.
- Omit `version` when evaluating a package the project does not depend on. An
  already-indexed version may be retained with a drift notice; check the response
  before claiming to describe the latest stable release.
- An explicit `version` overrides the project lock and may replace the indexed
  version. Use it for deliberate comparisons or to match the lockfile when needed.
- Core doc sets are `elixir`, `eex`, `ex_unit`, `iex`, `logger`, and `mix`.
  For example, search `elixir` for `Enum`, `Task` or `GenServer`. Their default
  version is the **server's Elixir**, so pass the project's Elixir version when
  it differs; `mix.lock` does not pin it.

## Form the query

Keep the package name out of `query`; the `package` argument already scopes it.
Use an exact identifier for a symbol lookup, or a concise description using the
package's vocabulary for a conceptual question. Public docs can describe functions
created by macros: an empty source search does not prove a public API is absent.

For prose queries, heading-only entries, title restatements, and bare typespecs
receive 40% of their RRF score before the final ten results are selected;
explanations and examples keep their full score. Identifier-only queries retain
ordinary RRF ordering. Use a bare exact identifier when looking up a generated
function whose stub may rank lower for a prose query. All entries remain indexed;
there is no learned reranker.

```text
search_docs(package: "req", query: "Req.merge/2")
search_docs(package: "text_chunker", query: "chunk overlap preserve context")
```

For a question spanning packages, issue separate calls with different queries and
combine the evidence. For OAuth around an MCP HTTP endpoint:

```text
search_docs(package: "anubis_mcp", query: "StreamableHTTP Plug router forward authorization")
search_docs(package: "boruta", query: "authorize access token bearer protect resource")
```

Use `include_examples_only: true` only when examples are specifically needed; it
can exclude the API or guide explaining the behavior. Issue searches sequentially
when ingestion is involved, avoiding competing jobs for the same package.

Use `doc_category: "guides"`, `"api"`, or `"changelogs"` when the question calls
for a particular kind of evidence; omit it (or use `"all"`) for mixed results.
API includes callbacks and types as well as functions and modules. Guides are
ExDoc extras excluding recognized changelog page names; migration guides remain
guides. Changelogs are recognized by common page names, so unusually named ones
may remain guides. The filter runs before ranking and combines with
`include_examples_only`; it does not require re-ingestion.

## Read surrounding context

Use `get_doc(id: <search result id>)` when a result is partial or needs context.
It returns the selected chunk and one neighbor on each side from the same entry,
in source order. Set `neighbors` from 0 to 5 to adjust the window. Follow
`previous_id` or `next_id` to continue; `complete?` means the whole entry is present.
IDs are local and may expire after re-ingestion; search again if one is missing.
This reads the index without network requests or embedding costs.

## Read the response before acting

Read **all returned chunks**, their versions, and `notices`. Rank is not a
relevance guarantee. `retrieval_mode`, when present, reports successful retrieval
arms (`hybrid`, `keyword`, `vector`, `none`), not answer quality. Older servers may
omit it. Distinguish empty results from ingestion in progress or failed retrieval.

| Response | Next action |
| --- | --- |
| Ingestion still running | Retry the same package/version/query **without `refresh: true`**; retain other filters |
| Repeated progress | Make at most two collection retries in this turn; if still pending, report that indexing continues |
| Embedding unavailable or an arm failed | Use relevant surviving results; mention degraded retrieval when it limits confidence |
| Model mismatch, unverified provenance, or exhausted repair | Explain the notice; retries cannot repair configuration or rebuild the index |
| Version drift or an unexpected version | Reconcile with the lockfile and the user's target before relying on the docs |
| Healthy search lacks the answer | Try a focused reformulation, inspect the cited source, or check upstream issues |

Do not refresh routinely. Before refreshing a package not indexed in this session,
call `list_indexed_packages` to inspect its stored version and completeness. Use
`check_hex: true` only for a release-drift question. Refresh re-downloads and
re-embeds the package; pin the stored version explicitly to rebuild a pre-release
in place. Only one version per package is retained, so repeated version replacement
across projects calls for separate database paths, not repeated retries.

## Use and cite the evidence

Include the **returned package version** with each documentation-based conclusion.
Link only exact returned `hexdocs_url` or `source_url` values, or URLs independently
verified; never synthesize HexDocs or source links. Source links may be absent.

API documentation includes `module`, `function`, `macro`, `callback`, `type`,
`opaque`, and other API row kinds; `extras` identifies handwritten guides. A
documented generated function can have only a heading, which identifies the API
without explaining its behavior. Check important defaults and version-sensitive
claims against the matching API or source. Documentation describes intended behavior; it does
not establish transport, concurrency or deployment behavior. When observed behavior
differs, investigate source and upstream issues rather than extrapolating from a
docstring. State when the available evidence does not answer the question.
