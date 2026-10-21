defmodule StdioMcp.DatabaseStartupTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Ecto.Adapters.SQL
  alias Ecto.Migrator
  alias ExUnit.CaptureIO
  alias StdioMcp.{PackageDoc, Repo}
  @migration 20_261_021_000_000
  @migration_module StdioMcp.Repo.Migrations.VerifyVectorsAndIdentifiers

  setup do
    original = Application.fetch_env!(:stdio_mcp, Repo)
    directory = Path.join(System.tmp_dir!(), "hex_boot_#{System.unique_integer([:positive])}")
    database = Path.join(directory, "nested/index.db")
    :ok = Application.stop(:stdio_mcp)
    Application.put_env(:stdio_mcp, Repo, Keyword.put(original, :database, database))

    on_exit(fn ->
      Application.stop(:stdio_mcp)
      Application.put_env(:stdio_mcp, Repo, original)
      {:ok, _} = Application.ensure_all_started(:stdio_mcp)
      File.rm_rf!(directory)
    end)

    %{database: database}
  end

  test "cold startup creates directories and schema without writing to stdout", %{
    database: database
  } do
    refute File.exists?(database)

    output =
      CaptureIO.capture_io(fn ->
        assert {:ok, _} = Application.ensure_all_started(:stdio_mcp)
      end)

    assert output == ""
    assert File.exists?(database)
    assert Repo.config()[:database] == database
    assert Repo.aggregate(PackageDoc, :count) == 0
    assert @migration in Migrator.migrated_versions(Repo)

    assert %{rows: [[0]]} =
             SQL.query!(Repo, "SELECT count(*) FROM package_docs_fts", [])
  end

  test "restarting applies pending migrations and preserves existing documents" do
    {:ok, _} = Application.ensure_all_started(:stdio_mcp)
    :ok = Migrator.down(Repo, @migration, @migration_module, log: false)

    doc =
      Repo.insert!(%PackageDoc{
        package: "fixture",
        version: "1.0.0",
        doc_type: "function",
        content: "chunk_overlap"
      })

    refute @migration in Migrator.migrated_versions(Repo)

    :ok = Application.stop(:stdio_mcp)
    assert {:ok, _} = Application.ensure_all_started(:stdio_mcp)
    assert @migration in Migrator.migrated_versions(Repo)
    assert Repo.get!(PackageDoc, doc.id).content == "chunk_overlap"

    assert %{rows: [[1]]} =
             SQL.query!(
               Repo,
               "SELECT count(*) FROM package_docs_fts WHERE package_docs_fts MATCH ?",
               [~s("chunk_overlap")]
             )

    # A fully migrated restart is idempotent too.
    :ok = Application.stop(:stdio_mcp)
    assert {:ok, _} = Application.ensure_all_started(:stdio_mcp)
    assert Repo.get!(PackageDoc, doc.id).content == "chunk_overlap"
  end

  test "a migration error prevents application startup" do
    {:ok, _} = Application.ensure_all_started(:stdio_mcp)
    :ok = Migrator.down(Repo, @migration, @migration_module, log: false)
    SQL.query!(Repo, "ALTER TABLE knowledge ADD COLUMN embedding_model TEXT", [])
    :ok = Application.stop(:stdio_mcp)

    assert {:error, {:stdio_mcp, reason}} = Application.ensure_all_started(:stdio_mcp)
    assert inspect(reason) =~ "duplicate column"
    assert Process.whereis(StdioMcp.Supervisor) == nil
    assert Process.whereis(StdioMcp.TaskSupervisor) == nil
  end
end
