defmodule StdioMcp.Repo.Migrations.VerifyVectorsAndIdentifiers do
  use Ecto.Migration

  def up do
    alter table(:knowledge) do
      add(:embedding_model, :string)
    end

    # Legacy knowledge vectors have unknown provenance. Keep the text and vector,
    # but exclude them from cosine comparisons until reindex assigns a model.
    rebuild_fts("unicode61 tokenchars '_/'")
  end

  def down do
    rebuild_fts("unicode61")

    alter table(:knowledge) do
      remove(:embedding_model)
    end
  end

  defp rebuild_fts(tokenizer) do
    execute("DROP TABLE package_docs_fts")

    execute("""
    CREATE VIRTUAL TABLE package_docs_fts USING fts5(
      package, version, module, signature, content,
      content='package_docs', content_rowid='id',
      tokenize = "#{tokenizer}"
    )
    """)

    execute("INSERT INTO package_docs_fts(package_docs_fts) VALUES ('rebuild')")
  end
end
