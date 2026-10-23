defmodule StdioMcp.VectorStorageTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log
  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias StdioMcp.Docs.EmbeddingConfig
  alias StdioMcp.{Knowledge, PackageDoc, Repo, Vector}
  alias StdioMcp.Repo.Migrations.PackVectors
  @migration 20_261_023_000_000

  setup do
    Repo.delete_all(Knowledge)
    Repo.delete_all(PackageDoc)
    EmbeddingConfig.clear()
    :ok
  end

  test "packed values match SQLite's existing float32 conversion exactly" do
    values = [0.123456789012345, -0.987654321098765, 0.0, 1.0, 1.0e-20]
    binary = Vector.encode!(values)
    assert [[^binary]] = SQL.query!(Repo, "SELECT vec_f32(?)", [Jason.encode!(values)]).rows
    assert Vector.dimensions(binary) == length(values)
    assert Vector.from_json!(Jason.encode!(values)) == binary
    assert Vector.encode!(binary) == binary
    # A packed float's bytes can resemble JSON; storage must not reinterpret it.
    assert Vector.encode!("[12]") == "[12]"
    assert Vector.from_json!("[12]") != "[12]"
    assert Vector.cast([]) == :error
    assert Vector.cast([:not_a_number]) == :error
    assert Vector.cast(<<1, 2, 3>>) == :error
  end

  test "schema writes and bulk ingestion writes use BLOBs" do
    doc =
      Repo.insert!(%PackageDoc{
        package: "fixture",
        version: "1",
        doc_type: "function",
        embedding: [1.0, 0.0]
      })

    Repo.insert_all(PackageDoc, [
      %{
        package: "fixture",
        version: "1",
        doc_type: "function",
        embedding: [0.0, 1.0],
        inserted_at: doc.inserted_at,
        updated_at: doc.updated_at
      }
    ])

    {:ok, learning} =
      %Knowledge{}
      |> Knowledge.changeset(%{
        title: "binary",
        kind: "pattern",
        content: "keeps provenance",
        embedding: [1.0, 0.0],
        embedding_model: "old-model"
      })
      |> Repo.insert()

    assert Repo.get!(PackageDoc, doc.id).embedding == Vector.encode!([1.0, 0.0])
    assert Repo.get!(Knowledge, learning.id).embedding_model == "old-model"

    assert [["blob", 2]] =
             SQL.query!(
               Repo,
               "SELECT typeof(embedding),count(*) FROM package_docs GROUP BY typeof(embedding)",
               []
             ).rows

    assert [["blob", 8]] =
             SQL.query!(Repo, "SELECT typeof(embedding),length(embedding) FROM knowledge", []).rows
  end

  test "migration failure rolls back conversions across both tables" do
    doc = Repo.insert!(%PackageDoc{package: "fixture", version: "1", doc_type: "function"})

    learning =
      Repo.insert!(%Knowledge{
        title: "invalid legacy vector",
        kind: "pattern",
        content: "preserve text"
      })

    :ok = Migrator.down(Repo, @migration, PackVectors, log: false)
    SQL.query!(Repo, "UPDATE package_docs SET embedding=? WHERE id=?", ["[1.0,0.0]", doc.id])
    SQL.query!(Repo, "UPDATE knowledge SET embedding=? WHERE id=?", ["invalid JSON", learning.id])

    on_exit(fn ->
      SQL.query!(Repo, "DELETE FROM knowledge WHERE id=?", [learning.id])
      Migrator.up(Repo, @migration, PackVectors, log: false)
    end)

    assert_raise Exqlite.Error, fn -> Migrator.up(Repo, @migration, PackVectors, log: false) end
    refute @migration in Migrator.migrated_versions(Repo)

    assert [["text", "[1.0,0.0]"]] =
             SQL.query!(Repo, "SELECT typeof(embedding),embedding FROM package_docs WHERE id=?", [
               doc.id
             ]).rows

    assert [["preserve text", "invalid JSON"]] =
             SQL.query!(Repo, "SELECT content,embedding FROM knowledge WHERE id=?", [learning.id]).rows
  end

  test "migration converts legacy vectors without changing content, provenance or dimensions" do
    doc =
      Repo.insert!(%PackageDoc{
        package: "fixture",
        version: "1",
        doc_type: "function",
        content: "unique_option"
      })

    learning =
      Repo.insert!(%Knowledge{
        title: "lesson",
        kind: "pattern",
        content: "historical",
        embedding_model: "old-model"
      })

    EmbeddingConfig.record("unchanged-model", 2)
    config = EmbeddingConfig.get()
    :ok = Migrator.down(Repo, @migration, PackVectors, log: false)

    SQL.query!(Repo, "UPDATE package_docs SET embedding=? WHERE id=?", [
      "[0.123456789,1.0]",
      doc.id
    ])

    SQL.query!(Repo, "UPDATE knowledge SET embedding=? WHERE id=?", ["[1.0,0.0]", learning.id])
    :ok = Migrator.up(Repo, @migration, PackVectors, log: false)
    updated = Repo.get!(PackageDoc, doc.id)
    assert updated.id == doc.id and updated.content == doc.content
    assert updated.updated_at == doc.updated_at
    assert updated.embedding == Vector.from_json!("[0.123456789,1.0]")
    assert Vector.dimensions(updated.embedding) == 2
    assert Repo.get!(Knowledge, learning.id).embedding == Vector.encode!([1.0, 0.0])
    assert Repo.get!(Knowledge, learning.id).embedding_model == "old-model"
    assert EmbeddingConfig.get() == config

    assert [[1]] =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM package_docs_fts WHERE package_docs_fts MATCH ?",
               ["unique_option"]
             ).rows

    # Rollback retains the same float32 values, and reapplying is safe.
    :ok = Migrator.down(Repo, @migration, PackVectors, log: false)

    assert [["text", 2]] =
             SQL.query!(
               Repo,
               "SELECT typeof(embedding),vec_length(embedding) FROM package_docs",
               []
             ).rows

    :ok = Migrator.up(Repo, @migration, PackVectors, log: false)
    assert Repo.get!(PackageDoc, doc.id).embedding == updated.embedding
  end
end
