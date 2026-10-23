defmodule StdioMcp.SearchArchitectureTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias ExUnit.CaptureIO
  alias Mix.Tasks.Docs.Eval
  alias Mix.Tasks.Docs.Reindex
  alias StdioMcp.{Knowledge, Memory, PackageDoc, Repo}
  alias StdioMcp.Vector

  alias StdioMcp.Docs.{
    Deadline,
    EmbeddingConfig,
    Fusion,
    IngestionJob,
    Judgements,
    QuerySanitizer,
    Retrieval,
    Search
  }

  alias StdioMcp.Tools.SearchDocs

  setup do
    Repo.delete_all(Knowledge)
    Repo.delete_all(PackageDoc)
    EmbeddingConfig.clear()
    original = Application.get_all_env(:stdio_mcp)
    Application.put_env(:stdio_mcp, :ai_embed_model, "new-model")
    Application.put_env(:stdio_mcp, :ai_api_key, nil)

    on_exit(fn ->
      for {key, value} <- original, do: Application.put_env(:stdio_mcp, key, value)
    end)

    :ok
  end

  test "one failed retrieval arm preserves the other and exposes its mode" do
    assert {[8, 9], [notice], :vector} =
             Retrieval.run(fn -> raise "FTS unavailable" end, fn -> [8, 9] end, 10)

    assert notice =~ "keyword retrieval failed"

    assert {[3], [_], :keyword} =
             Retrieval.run(fn -> [3] end, fn -> raise "bad dimensions" end, 10)

    assert {[], [_, _], :none} = Retrieval.run(fn -> raise "fts" end, fn -> raise "vec" end, 10)
  end

  test "slow query embedding falls back within its own budget" do
    provider(fn _ ->
      Process.sleep(2_500)
      {200, %{"data" => [%{"embedding" => [1.0, 0.0]}]}}
    end)

    insert_doc("answer")
    started = System.monotonic_time(:millisecond)

    assert {:reply, response, %{}} =
             SearchDocs.execute(
               %{query: "answer", package: "fixture", version: "1.0.0"},
               %{}
             )

    elapsed = System.monotonic_time(:millisecond) - started
    [%{"text" => text}] = response.content
    payload = Jason.decode!(text)
    assert payload["retrieval_mode"] == "keyword"
    assert payload["index_status"] == "ready"
    assert payload["ingested_this_request"] == false
    assert payload["resolved_version"] == "1.0.0"
    assert payload["version_source"] == "explicit"
    assert is_integer(payload["elapsed_ms"]) and payload["elapsed_ms"] >= 2_000
    assert length(payload["results"]) == 1
    assert Enum.any?(payload["notices"], &String.contains?(&1, "deadline_exceeded"))
    assert elapsed < 2_500
  end

  test "query embedding failure is visible to the tool caller" do
    insert_doc("answer")

    assert {:reply, response, %{}} =
             SearchDocs.execute(
               %{query: "answer", package: "fixture", version: "1.0.0"},
               %{}
             )

    [%{"text" => text}] = response.content
    payload = Jason.decode!(text)
    assert payload["retrieval_mode"] == "keyword"
    assert Enum.any?(payload["notices"], &String.contains?(&1, "missing_api_key"))
  end

  test "healthy empty arms do not masquerade as failed arms" do
    assert {[], [], :hybrid} = Retrieval.run(fn -> [] end, fn -> [] end, 10)
    assert {[1], [], :keyword} = Retrieval.run(fn -> [1] end, nil, 10)
  end

  test "deadline kills foreground waiting but leaves ingestion running for a retry" do
    parent = self()
    package = "deadline-#{System.unique_integer([:positive])}"

    assert {:error, :deadline_exceeded} =
             Deadline.run(Deadline.after_ms(100), fn ->
               IngestionJob.run(__MODULE__, package, "1", 5_000, fn ->
                 send(parent, :ingestion_started)
                 Process.sleep(300)
                 send(parent, :ingestion_finished)
                 :saved
               end)
             end)

    assert_receive :ingestion_started

    assert {:ok, :saved} =
             IngestionJob.run(__MODULE__, package, "1", 1_000, fn ->
               flunk("retry restarted ingestion")
             end)

    assert_receive :ingestion_finished
  end

  test "fresh tokenizer distinguishes identifiers and expands prose queries" do
    insert_doc("token/2 chunk_overlap")
    insert_doc("token/3 chunk overlap")
    assert fts_count(~s("token/2")) == 1
    assert fts_count(~s("chunk_overlap")) == 1
    assert fts_count(QuerySanitizer.to_match("chunk_overlap")) == 2
    assert fts_count(QuerySanitizer.to_match("token/2.")) == 1
  end

  test "tokenizer migration rebuilds existing rows and maintains triggers" do
    migration = 20_261_021_000_000

    Migrator.down(Repo, migration, StdioMcp.Repo.Migrations.VerifyVectorsAndIdentifiers,
      log: false
    )

    insert_doc("token/2 chunk_overlap")
    assert fts_count(~s("token")) == 1

    Migrator.up(Repo, migration, StdioMcp.Repo.Migrations.VerifyVectorsAndIdentifiers, log: false)

    assert fts_count(~s("token/2")) == 1
    assert fts_count(~s("token")) == 0
    Repo.delete_all(PackageDoc)
    assert fts_count(~s("token/2")) == 0
  end

  test "production preserves vector results when keyword retrieval fails" do
    insert_doc("semantic answer")
    EmbeddingConfig.record("new-model", 2)
    SQL.query!(Repo, "ALTER TABLE package_docs_fts RENAME TO unavailable_fts", [])

    try do
      result =
        Search.search_detailed("no lexical match",
          package: "fixture",
          version: "1.0.0",
          embedding: "[1.0,0.0]"
        )

      assert result.retrieval_mode == :vector
      assert length(result.results) == 1
      assert Enum.any?(result.notices, &String.contains?(&1, "keyword retrieval failed"))
    after
      SQL.query!(Repo, "ALTER TABLE unavailable_fts RENAME TO package_docs_fts", [])
    end
  end

  test "unverified docs provenance explicitly disables vector comparisons" do
    insert_doc("answer")

    result =
      Search.search_detailed("answer",
        package: "fixture",
        version: "1.0.0",
        embedding: "[1.0,0.0]"
      )

    assert result.retrieval_mode == :keyword
    assert Enum.any?(result.notices, &String.contains?(&1, "unverified"))
  end

  test "knowledge uses per-row provenance even when global docs config names the new model" do
    provider(fn _ -> {200, %{"data" => [%{"embedding" => [1.0, 0.0]}]}} end)
    EmbeddingConfig.record("new-model", 2)
    old = insert_knowledge("old unique fact", "old-model")
    legacy = insert_knowledge("legacy unique fact", nil)
    current = insert_knowledge("current unique fact", "new-model")
    assert Enum.map(Memory.search("semantic-only"), & &1.id) == [current.id]
    # Incompatible entries are still searchable by their text.
    assert old.id in Enum.map(Memory.search("old unique fact"), & &1.id)
    assert legacy.id in Enum.map(Memory.search("legacy unique fact"), & &1.id)
  end

  test "failed knowledge-only reindex preserves text and old provenance" do
    provider(fn _ -> {400, %{"error" => "embedding unavailable"}} end)
    old = insert_knowledge("preserved learning", "old-model")
    EmbeddingConfig.record("new-model", 2)
    Reindex.run(["--yes"])

    assert %{content: "preserved learning", embedding_model: "old-model"} =
             Repo.get!(Knowledge, old.id)

    assert Memory.search("unrelated semantic query") == []
  end

  test "successful knowledge-only reindex updates vectors and provenance together" do
    provider(fn _ -> {200, %{"data" => [%{"embedding" => [0.0, 1.0]}]}} end)
    old = insert_knowledge("preserved learning", "old-model")
    Reindex.run(["--yes"])
    updated = Repo.get!(Knowledge, old.id)
    assert updated.embedding == Vector.encode!([0.0, 1.0])
    assert updated.embedding_model == "new-model"
  end

  test "a malformed knowledge batch cannot partially update provenance" do
    provider(fn _ -> {200, %{"data" => [%{"embedding" => [0.0, 1.0]}, %{"embedding" => []}]}} end)
    one = insert_knowledge("one learning", "old-model")
    two = insert_knowledge("two learning", "old-model")
    Reindex.run(["--yes"])
    assert Repo.get!(Knowledge, one.id).embedding_model == "old-model"
    assert Repo.get!(Knowledge, two.id).embedding_model == "old-model"
  end

  test "judgements do not transfer to sibling chunks or changed content" do
    rows =
      for content <- ["relevant option", "irrelevant option"],
          do: %{
            package: "fixture",
            url: "https://example.test/docs",
            signature: "options",
            content: content
          }

    [one, two] = rows
    key = Judgements.key(one.url, one.content)
    existing = %{"question" => %{{one.package, key} => :yes, {one.package, one.url} => :yes}}
    output = Judgements.render([{"question", :concept, rows}], existing)
    assert output =~ "y fixture\t#{key}"
    assert output =~ "? fixture\t#{Judgements.key(two.url, two.content)}"
    refute Judgements.key(one.url, one.content) == Judgements.key(one.url, "edited option")
  end

  test "new ingestion cannot relabel docs whose model is unknown" do
    insert_doc("legacy embedding")
    assert {:error, :embedding_model_unverified} = EmbeddingConfig.allow_ingest("new-model")
    assert EmbeddingConfig.get() == nil
  end

  test "evaluation rejects same-dimension model mismatch before embedding queries" do
    EmbeddingConfig.record("old-model", 2)
    assert_raise Mix.Error, ~r/old-model/, fn -> Eval.run(["--modes", "rrf"]) end
  end

  test "evaluation scores its ten-result output, excluding a hit at rank eleven" do
    provider(fn _ -> {200, %{"data" => [%{"embedding" => [1.0, 0.0]}]}} end)
    EmbeddingConfig.record("new-model", 2)

    for i <- 1..20 do
      Repo.insert!(%PackageDoc{
        package: "req",
        version: "1.0.0",
        doc_type: "function",
        function: if(i == 11, do: "Req.Steps.retry/1", else: "other/1"),
        content: "backoff",
        embedding: Vector.encode!([1.0, i / 10])
      })
    end

    output =
      CaptureIO.capture_io(fn ->
        Eval.run(["--modes", "rrf", "--limit", "10"])
      end)

    assert output =~ "fused pool 10"
    assert output =~ "success@10"
    assert output =~ ~r/rrf\s+0\.00\s+0\.00\s+0\.00/
  end

  test "held-out query text is independent of the regression suite" do
    regression = MapSet.new(Eval.queries(), & &1.query)
    holdout = MapSet.new(Eval.queries("holdout"), & &1.query)
    assert MapSet.size(holdout) == 6
    assert MapSet.disjoint?(regression, holdout)
  end

  test "production output is exactly the ten-item fused pool" do
    for i <- 1..20, do: insert_doc("answer #{i}")
    EmbeddingConfig.record("new-model", 2)

    keyword =
      Repo.all(
        from(d in PackageDoc,
          join: f in "package_docs_fts",
          on: d.id == f.rowid,
          where: fragment("package_docs_fts MATCH ?", ^QuerySanitizer.to_match("answer")),
          order_by: [asc: fragment("rank")],
          limit: 15,
          select: d.id
        )
      )

    vector =
      SQL.query!(
        Repo,
        "SELECT id FROM package_docs ORDER BY vec_distance_cosine(embedding, ?) LIMIT 15",
        ["[1.0,0.0]"]
      ).rows
      |> List.flatten()

    {docs, []} =
      Search.search("answer", package: "fixture", version: "1.0.0", embedding: "[1.0,0.0]")

    assert Enum.map(docs, & &1.id) == Fusion.rrf([keyword, vector], 10)
    assert length(docs) == 10
  end

  test "production demotes stubs before the cutoff in hybrid and keyword searches" do
    for _ <- 1..15, do: insert_doc("# `schema`")
    guide = insert_doc("Define a tool schema with required fields and an execute callback.")
    EmbeddingConfig.record("new-model", 2)

    for embedding <- [nil, "[1.0,0.0]"] do
      {docs, []} =
        Search.search("define tool schema",
          package: "fixture",
          version: "1.0.0",
          embedding: embedding
        )

      assert hd(docs).id == guide.id
      assert length(docs) == 10
      assert Repo.aggregate(PackageDoc, :count) == 16
    end

    {docs, []} = Search.search("schema", package: "fixture", version: "1.0.0")
    assert Enum.any?(docs, &(&1.content == "# `schema`"))
  end

  defp insert_doc(content) do
    Repo.insert!(%PackageDoc{
      package: "fixture",
      version: "1.0.0",
      doc_type: "function",
      content: content,
      embedding: Vector.encode!([1.0, 0.0])
    })
  end

  defp insert_knowledge(content, model) do
    Repo.insert!(%Knowledge{
      title: content,
      kind: "pain_point",
      content: content,
      embedding: Vector.encode!([1.0, 0.0]),
      embedding_model: model
    })
  end

  defp fts_count(match) do
    [[count]] =
      SQL.query!(
        Repo,
        "SELECT count(*) FROM package_docs_fts WHERE package_docs_fts MATCH ?",
        [match]
      ).rows

    count
  end

  defp provider(handler) do
    {url, close} = ProviderStub.start(handler)
    Application.put_env(:stdio_mcp, :ai_embed_url, url)
    Application.put_env(:stdio_mcp, :ai_api_key, "test-key")
    on_exit(close)
  end
end
