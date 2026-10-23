defmodule StdioMcp.SearchCategoryTest do
  use ExUnit.Case, async: false
  alias StdioMcp.{PackageDoc, Repo, Vector}
  alias StdioMcp.Docs.{EmbeddingConfig, Search}
  alias StdioMcp.Tools.SearchDocs

  setup do
    Repo.delete_all(PackageDoc)
    EmbeddingConfig.clear()
    model = StdioMcp.AI.Client.embed_model()
    EmbeddingConfig.record(model, 2)
    on_exit(fn -> EmbeddingConfig.clear() end)
    :ok
  end

  test "categories partition extras and API entries before either retrieval arm's limit" do
    api = insert("module", "Changelog")
    for i <- 1..20, do: insert("function", "Example.fn#{i}")
    guide = insert("extras", "guides/jobs")

    history_guide =
      insert("extras", "migration_guide", %{content: "answer discusses changelog release history"})

    changelog = insert("extras", "CHANGELOG")
    nested = insert("extras", "guides/release_notes")

    for embedding <- [nil, [1.0, 0.0]] do
      assert ids("guides", embedding) == MapSet.new([guide.id, history_guide.id])
      assert ids("changelogs", embedding) == MapSet.new([changelog.id, nested.id])
      api_ids = ids("api", embedding)
      assert MapSet.size(api_ids) == if(embedding, do: 15, else: 21)
      assert api.id in api_ids
      refute guide.id in api_ids
      refute changelog.id in api_ids
    end
  end

  test "all is the default and category filtering composes with example filtering" do
    guide = insert("extras", "jobs", %{code_snippet: "perform(job)"})
    insert("extras", "other")
    insert("extras", "changes", %{code_snippet: "changed()"})
    insert("function", "Example.run", %{code_snippet: "run()"})
    default = Search.search_detailed("answer", package: "fixture", version: "1.0.0")
    assert MapSet.new(default.results, & &1.id) == ids("all", nil)

    result =
      Search.search_detailed("answer",
        package: "fixture",
        version: "1.0.0",
        doc_category: "guides",
        include_examples_only: true
      )

    assert Enum.map(result.results, & &1.id) == [guide.id]
  end

  test "changelog page matching is exact and handles nested pages case insensitively" do
    changelogs =
      for page <-
            ~w(changelog changes history release_notes release-notes releasenotes nested/CHANGELOG),
          do: insert("extras", page)

    guides =
      for page <- ~w(changelog_usage ancient_history nested/releaseXnotes),
          do: insert("extras", page)

    assert ids("changelogs", nil) == MapSet.new(changelogs, & &1.id)
    assert ids("guides", nil) == MapSet.new(guides, & &1.id)
  end

  test "invalid categories return validation notices without ingestion" do
    for category <- ["guide", "functions", "", 123] do
      result = Search.search_detailed("answer", package: "fixture", doc_category: category)
      assert result.results == []
      assert result.index_status == :not_checked
      assert Enum.any?(result.notices, &String.contains?(&1, "doc_category"))
    end
  end

  test "tool forwards category and keeps version metadata" do
    guide = insert("extras", "jobs")
    insert("function", "Example.run")

    assert {:reply, response, %{}} =
             SearchDocs.execute(
               %{query: "answer", package: "fixture", version: "1.0.0", doc_category: "guides"},
               %{}
             )

    [%{"text" => text}] = response.content
    payload = Jason.decode!(text)
    assert Enum.map(payload["results"], & &1["id"]) == [guide.id]
    assert payload["index_status"] == "ready"
    assert payload["resolved_version"] == "1.0.0"
  end

  defp ids(category, embedding) do
    result =
      Search.search_detailed("answer",
        package: "fixture",
        version: "1.0.0",
        doc_category: category,
        embedding: embedding,
        limit: 30
      )

    assert result.retrieval_mode == if(embedding, do: :hybrid, else: :keyword),
           inspect(result.notices)

    MapSet.new(result.results, & &1.id)
  end

  defp insert(type, module, attrs \\ %{}) do
    Repo.insert!(
      struct(
        PackageDoc,
        Map.merge(
          %{
            package: "fixture",
            version: "1.0.0",
            doc_type: type,
            module: module,
            content: "answer",
            embedding: Vector.encode!([1.0, 0.0])
          },
          attrs
        )
      )
    )
  end
end
