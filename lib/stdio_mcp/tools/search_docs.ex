defmodule StdioMcp.Tools.SearchDocs do
  @moduledoc """
  Search official HexDocs documentation, typespecs, guides, and code examples for
  a single Hex package using hybrid keyword (FTS5) and semantic (vector) ranking.

  ## Usage Notes

    * **Context**: Use `get_doc` with a result ID to read neighboring chunks from the same entry.
    * **Scope**: Always scoped to a single `package`. Issue separate calls for multi-package queries.
    * **Query**: Keep `query` concise and omit the package name to avoid keyword/vector noise.
    * **Version**: When `PROJECT_ROOT` is set, omitting `version` resolves `"latest"` to the version pinned in the calling project's `mix.lock` (falling back to Hex latest stable). Pass `version` explicitly to query an unpinned release.
    * **Notices**: Check returned `notices` for version drift, background ingestion progress, or missing embeddings.
    * **Metadata**: `index_status` reports indexing state; `ingested_this_request` reports observed completion, including joined jobs. `resolved_version` and `version_source` identify the selected target, which may differ from cached result versions during a pending or failed refresh. `elapsed_ms` includes query embedding.
    * **Source Code**: Results include `hexdocs_url` and a `source_url` linking directly to the file and line.
  """

  # Left at the `:forbidden` default deliberately. Declaring
  # `task_support: :optional` was probed on 2026-08-03 against anubis_mcp v1.14.0:
  # the tool advertised `execution.taskSupport` in tools/list and the client still
  # never populated `frame.task_id`, so Claude Code does not implement the MCP
  # 2025-11-25 task augmentation. Advertising a capability no client exercises
  # only invites augmented calls this tool has no code path for.
  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias StdioMcp.AI.Client
  alias StdioMcp.Docs.Deadline
  alias StdioMcp.Docs.Search

  schema do
    field(:query, :string,
      required: true,
      description:
        "Search query for Elixir package documentation, modules, typespecs, and code examples."
    )

    field(:package, :string,
      required: true,
      description:
        "Hex package name to search within (e.g. 'boruta', 'anubis_mcp', 'phoenix', 'ecto', 'req'). Searches are always scoped to one package — a cross-package search answers with rows from unrelated packages that merely share keywords, which is indistinguishable from a real answer. Also triggers ingestion from Hex.pm when the package is not indexed yet, so name the package even when unsure whether it is present."
    )

    field(:version, :string,
      description:
        "Optional package version, or 'latest' to target the newest release. Does not by itself re-download docs already indexed — use `refresh` for that."
    )

    field(:refresh, :boolean,
      description:
        "Optional boolean to force re-ingesting the package's docs from Hex.pm, replacing what is indexed. Use when docs are stale or the local index looks wrong."
    )

    field(:doc_category, :string,
      description:
        "Optional documentation category: all (default), guides, api, or changelogs. Guides are ExDoc extras excluding common changelog page names; api includes non-extras entries. Changelogs are identified by page name, not content."
    )

    field(:include_examples_only, :boolean,
      description: "Optional boolean to filter results to only entries containing code snippets."
    )
  end

  @impl true
  def execute(params, frame) do
    started = System.monotonic_time(:millisecond)
    query = params[:query]
    package = params[:package]
    version = params[:version]
    examples_only = params[:include_examples_only] || false

    # Re-ingesting used to be bound to `version == "latest"`, which is also the
    # most casual way to say "I don't care which version" — so ordinary queries
    # paid a full re-download, and asking to refresh one specific version was
    # impossible. It is its own flag now.
    refresh = params[:refresh] || false

    deadline = Deadline.after_ms(27_000)

    {vector, embedding_notices} =
      case Deadline.run(min(deadline, Deadline.after_ms(2_000)), fn -> Client.embed(query) end) do
        {:ok, {:ok, emb}} ->
          {emb, []}

        failure ->
          {nil, ["Query embedding unavailable (#{inspect(failure)}); using keyword retrieval."]}
      end

    opts = [
      package: package,
      version: version,
      refresh: refresh,
      include_examples_only: examples_only,
      doc_category: params[:doc_category] || "all",
      embedding: vector,
      # 10, and the fused pool is returned whole. Recall@5 is 0.96 against 1.00 at
      # ten on the 28-query eval: cutting at five drops a document the retrieval
      # arms did find, and nothing downstream puts it back — a pool of ten is
      # what fusion builds anyway, so five was throwing half of it away.
      #
      # This used to read "5, not 10", on the observation that the last two or
      # three rows of every search were changelog entries and unrelated functions.
      # That was true and is the cost being accepted here: with the cross-encoder
      # off, ranks 6-10 are RRF's, and their quality is unmeasured. The consumer
      # is an LLM that reads the whole payload before answering, so a mediocre
      # extra row is cheap to ignore while a missing row cannot be recovered
      # without a second round trip — which costs far more than the ~2k tokens
      # the extra five rows add.
      limit: 10
    ]

    search_result =
      case Deadline.run(deadline, fn -> Search.search_detailed(query, opts) end) do
        {:ok, result} ->
          result

        {:error, reason} ->
          %{
            results: [],
            index_status: :unknown,
            ingested_this_request: nil,
            resolved_version: nil,
            version_source: nil,
            retrieval_mode: :none,
            notices: [
              "Search did not finish within its request budget (#{inspect(reason)}). " <>
                "Any background ingestion continues; retry without refresh to collect it."
            ]
          }
      end

    %{results: results, notices: notices, retrieval_mode: mode} = search_result
    notices = embedding_notices ++ notices

    formatted =
      Enum.map(results, fn r ->
        %{
          id: r.id,
          package: r.package,
          version: r.version,
          doc_type: r.doc_type,
          module: r.module,
          function: r.function,
          signature: r.signature,
          content: r.content,
          hexdocs_url: r.hexdocs_url,
          source_url: r.source_url
        }
      end)

    payload =
      search_result
      |> Map.merge(%{results: formatted, notices: notices, retrieval_mode: mode})
      |> Map.put(:elapsed_ms, System.monotonic_time(:millisecond) - started)

    {:reply, Response.text(Response.tool(), Jason.encode!(payload)), frame}
  rescue
    e ->
      require Logger

      Logger.error(
        "[SearchDocs] Tool execution failed:\n#{Exception.format(:error, e, __STACKTRACE__)}"
      )

      {:reply, Response.text(Response.tool(), "Search docs failed: #{Exception.message(e)}"),
       frame}
  end
end
