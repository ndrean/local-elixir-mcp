# JSON versus binary vector storage — 2026-10-23

Measured on a frozen copy of the local OpenAI index. Baseline code: `4011149`.
Both conditions use `text-embedding-3-small`, 1536 dimensions, and the same 23
saved query vectors. No provider requests or re-embedding were performed.

The corpus has 3722 document chunks: anubis_mcp 2.2.0 (1527), nimble_options
1.1.1 (54), phoenix 1.8.16 (1225), plug 1.20.3 (561), req 0.8.0-rc.0 (355).
There are no knowledge rows in this measurement; populated knowledge storage,
retrieval and migration are covered by regression tests.

## Speed and storage

Each query is warmed once, then timed five times through production
`Search.search_detailed/2` with an explicit version and a saved query vector.
The median row below is the median of the 23 per-query medians. P95 is over all
115 timed searches. These are local retrieval times, not end-to-end MCP or
provider latency measurements. The final binary run is reported here; an earlier
run ranged down to a 14.7 ms median, illustrating normal timing variation.

| Metric | JSON text | float32 BLOB |
| --- | ---: | ---: |
| Median retrieval | 296.046 ms | 17.562 ms |
| P95 retrieval | 307.457 ms | 30.536 ms |
| Stored vector payload | 109402931 bytes | 22867968 bytes |
| Dimensions | 1536 | 1536 |

Median retrieval is 16.86× faster. Vector payload is 79.1% smaller. Payload means
the sum of vector lengths, not the allocated SQLite file size; conversion can
leave reusable free pages in the file.

## Accuracy and preservation

Every query retained the identical final ten document IDs in identical order.
The complete cosine distance and ordering for every matching document also
matched exactly, not only the first hit or a rounded quality metric.

Canonical checksums over every document field and its float32 vector matched
before and after conversion:

```text
d6ec59227efb97f61077bc6172fed9be085a917a7eae74134c349ad22cc91f46
```

This establishes unchanged retrieval accuracy on this query set; it does not
establish that every returned passage is relevant or that the regression suite
generalizes to other questions. The ranking algorithm was unchanged.

## Reproducing a comparison

Use [vector_storage_benchmark.exs](vector_storage_benchmark.exs) against copies of
the same index, recording a baseline before upgrading and then the migrated copy.
Use a query file with the model and saved vectors from that model, for example:

```json
{"model":"text-embedding-3-small","queries":[{"package":"anubis_mcp","version":"2.2.0","query":"define tool schema field required execute","embedding":["replace with the saved numeric vector"]}]}
```

The embedding array must contain all 1536 numeric elements; the string above is
a placeholder. Set `DATABASE_PATH` and `AI_EMBED_MODEL` consistently for each run.
An API key is unnecessary because the benchmark never calls the provider.

```sh
mix run priv/eval/vector_storage_benchmark.exs --queries /tmp/queries.json --output /tmp/before.json
# Upgrade the code and start against a copy of the same index, allowing migration.
mix run priv/eval/vector_storage_benchmark.exs --queries /tmp/queries.json --output /tmp/after.json --compare /tmp/before.json
```

The comparison fails if model, dimensions, canonical corpus values, full cosine
distances/order, or final result order differ. Keep the complete corpus fixed:
FTS5 statistics are global, so an unrelated ingestion can change keyword ranks.
