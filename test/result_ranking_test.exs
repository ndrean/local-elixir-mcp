defmodule StdioMcp.Docs.ResultRankingTest do
  use ExUnit.Case, async: true
  alias StdioMcp.Docs.{Fusion, ResultRanking}

  test "a useful single-arm example survives a full pool of heading-only matches" do
    stubs = for id <- 1..15, do: doc(id, "# `get_schema`", "function")

    example =
      doc(16, "```elixir\nschema do\n  field :query, :string, required: true\nend\n```", "extras")

    arms = [Enum.to_list(1..10) ++ [16], Enum.to_list(1..15)]
    refute 16 in Fusion.rrf(arms, 10)
    ranked = ResultRanking.rank(stubs ++ [example], arms, "declare a typed tool", 10)
    assert hd(ranked).id == 16
    assert length(ranked) == 10
    assert Enum.any?(ranked, &(&1.id <= 15))
  end

  test "identifier lookups retain RRF order, including undocumented functions" do
    stub = doc(1, "# `get_schema`", "function")
    example = doc(2, "Use schema blocks to define arguments.", "extras")
    arms = [[1, 2], [1]]

    for query <- ["TestTools.RequiredOptionTool.get_schema/1", "get_schema/1", "`get_schema/1`"] do
      ranked = ResultRanking.rank([stub, example], arms, query, 10)
      assert Enum.map(ranked, & &1.id) == Fusion.rrf(arms, 10)
    end
  end

  test "title restatements lose weight, while short explanations keep it" do
    title = %{doc(1, "A tool with output schema", "module") | signature: "ToolWithOutputSchema"}
    explanation = doc(2, "Validates options against a schema.", "function")

    ranked =
      ResultRanking.rank([title, explanation], [[1, 2], [1, 2]], "validate tool arguments", 10)

    assert Enum.map(ranked, & &1.id) == [2, 1]
  end

  test "bare typespecs lose weight but code examples and documented types keep it" do
    spec = doc(1, "# `schema`\n\n```elixir\n@type schema() :: map()\n```", "type")
    example = doc(2, "```elixir\nschema do\n  field :query, :string\nend\n```", "extras")

    described =
      doc(
        3,
        "Maps argument names to their validation rules.\n```elixir\n@type schema() :: map()\n```",
        "type"
      )

    ranked =
      ResultRanking.rank([spec, example, described], [[1, 2, 3]], "declare tool arguments", 10)

    assert Enum.map(ranked, & &1.id) == [2, 3, 1]
  end

  test "an index containing only stubs still returns them" do
    stub = doc(1, "# `get_schema`", "function")
    assert [^stub] = ResultRanking.rank([stub], [[1]], "how to define a schema", 10)
  end

  defp doc(id, content, type) do
    %{id: id, content: content, doc_type: type, signature: "Example#{id}"}
  end
end
