---
name: hex-local
description: Use the Hex Local MCP server for version-aware Elixir and Erlang package documentation, Hex package discovery, and upstream dependency issues. Apply when implementing or checking a dependency's public API, finding a library for a technology, or investigating behavior that differs from its docs. Also supports local debugging knowledge with recall and remember. Skip for ordinary repository edits that need no dependency research.
---

# Hex Local

Use published documentation for the package and version the project actually runs.
Turn retrieved evidence into an answer or implementation, with exact citations.

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
