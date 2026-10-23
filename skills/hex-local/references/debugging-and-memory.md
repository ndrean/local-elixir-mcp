# Debugging and local knowledge

Read this reference when investigating failures, checking unexpected dependency
behavior, or recording a substantial lesson. It supplements the documentation
workflow; ordinary API lookups do not require memory or issue searches.

## Recall before repeating an investigation

When available, use `recall`:

- On a command or test failure, search the distinctive error text with
  `kind: "pain_point"` before attempting the fix.
- Before a second corrective edit after the first failed, search the relevant
  function or module and symptom.
- Before changing infrastructure or authentication configuration such as
  `runtime.exs`, a Caddyfile, Docker Compose, or OAuth settings, search for the
  affected component and intended change.

```text
recall(query: "database is locked concurrent writes", kind: "pain_point")
recall(query: "stdio request timeout during background ingestion", package: "anubis_mcp")
```

`kind` supports `pain_point`, `pattern`, `decision`, and `package_note`. Add the
package filter when known; omit a filter that would unnecessarily exclude results.
No match means no recorded answer was found, not that the cause has been ruled
out. Recall can use keyword retrieval without an API key. Old or incompatible
knowledge vectors are excluded from cosine comparisons, but their text remains
searchable. Treat recalled conclusions as historical evidence and check that their
versions and circumstances still apply.

If the tool is unavailable, say so briefly and continue the investigation; do not
pretend a recall happened or repeatedly try a missing tool.

## Check upstream before explaining a dependency surprise

Search issues **and pull requests**, open **and closed**, before attributing the
behavior to a design decision or proposing an upstream fix.

```text
search_github_issues(package: "anubis_mcp", query: "stdio sampling deadlock")
```

Use `package` normally; the server resolves its repository through Hex metadata.
Use a verified `repo: "owner/name"` for a known repository or a non-Hex project.
Use `org` for a question spanning repositories. Omit `type` to include issues and
PRs. Authenticated `gh` is an alternative; leave state unrestricted and cover both
issues and PRs. Do not invent an owner or repository URL.

Search sibling paths too: a transport, adapter or backend may already have the
same fix. An accepted or merged PR is evidence of an upstream change, but verify
which release includes it before saying the installed version is fixed.

## Remember only actionable, confirmed lessons

After fixing the problem, use `remember` when at least one condition applies:

- The solution required two or more failed attempts.
- The cause involved interactions between layers, such as proxy and application
  transport, container networking and database, or release configuration and runtime.
- A dependency had an undocumented behavior or version constraint.

Skip routine one-step corrections without a cross-layer cause or dependency
quirk. Capture the symptom, actual cause, affected package/version, fix, and evidence
or verification that made the conclusion useful.
Exclude credentials and unrelated personal data. Keep observed facts distinct
from hypotheses. Do not save raw logs when a short explanation is sufficient.

Batch a session's lessons into one call using **`texts`, a list**:

```text
remember(texts: ["Affected package/version and symptom. Verified cause. Fix and how it was checked."])
```

The reply acknowledges queued curation, not a confirmed stored entry. A curator
may merge, append, replace or discard submissions. Report acceptance accurately;
do not claim the text was saved verbatim. This skill does not authorize unrelated
changes to configuration, index rebuilds, or upstream issue/PR publication.

## Diagnostics

Use `list_indexed_packages` when results look stale, weak or unexpectedly empty.
Check the database path, stored package/version, embedding completeness and model
metadata. `app_version: null` says only that the server does not load that package;
it says nothing about the project being edited. Check the project's lockfile
separately when needed.

If model mismatch or unknown provenance requires `mix docs.reindex`, explain the
operator action. A reindex can replace docs and spend embedding-provider credits;
a lookup request is not a request to rebuild everything or alter the server's key,
model, `PROJECT_ROOT`, or `DATABASE_PATH`.

Use `get_token_usage` only when token spend or a usage report is relevant. Its
optional filters are `model`, `from`, and `until`. These statistics describe server
API usage; they are not the coding assistant's account usage limits.
