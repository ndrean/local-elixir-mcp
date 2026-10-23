defmodule StdioMcp.GetDocTest do
  use ExUnit.Case, async: false
  alias StdioMcp.{PackageDoc, Repo}
  alias StdioMcp.Tools.GetDoc

  setup do
    Repo.delete_all(PackageDoc)
    :ok
  end

  test "returns neighbors in source order without crossing entries, packages, or versions" do
    docs =
      for i <- 1..5 do
        doc = insert(%{content: "part #{i}"})
        insert(%{hexdocs_url: "https://example.test/other"})
        insert(%{package: "other"})
        insert(%{version: "2"})
        doc
      end

    [a, b, c, d, e] = docs
    result = GetDoc.fetch(c.id)
    assert Enum.map(result.chunks, & &1.id) == [b.id, c.id, d.id]
    assert result.previous_id == a.id
    assert result.next_id == e.id
    refute result.complete?
    assert GetDoc.fetch(c.id, 5).complete?
    assert GetDoc.fetch(a.id).previous_id == nil
    assert GetDoc.fetch(e.id).next_id == nil
    assert Enum.map(GetDoc.fetch(c.id, 0).chunks, & &1.id) == [c.id]
  end

  test "missing URLs do not combine unrelated documentation" do
    a = insert(%{hexdocs_url: nil})
    insert(%{hexdocs_url: nil})
    assert [%{id: id}] = GetDoc.fetch(a.id).chunks
    assert id == a.id
  end

  test "reports stale ids and invalid arguments" do
    doc = insert(%{})
    Repo.delete!(doc)
    assert %{error: "not_found"} = GetDoc.fetch(doc.id)

    for {id, neighbors} <- [{0, 1}, {"1", 1}, {1, -1}, {1, 6}, {1, nil}] do
      assert %{error: "invalid_arguments"} = GetDoc.fetch(id, neighbors)
    end
  end

  test "tool response preserves citations and excludes embedding data" do
    doc = insert(%{source_url: "https://example.test/source"})
    assert {:reply, response, %{}} = GetDoc.execute(%{id: doc.id}, %{})
    [%{"text" => text}] = response.content
    payload = Jason.decode!(text)
    assert [chunk] = payload["chunks"]
    assert chunk["source_url"] == doc.source_url
    assert chunk["version"] == "1"
    refute Map.has_key?(chunk, "embedding")
  end

  defp insert(attrs) do
    Repo.insert!(
      struct(
        PackageDoc,
        Map.merge(
          %{
            package: "fixture",
            version: "1",
            doc_type: "extras",
            hexdocs_url: "https://example.test/guide",
            content: "body"
          },
          attrs
        )
      )
    )
  end
end
