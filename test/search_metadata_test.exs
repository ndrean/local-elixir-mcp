defmodule StdioMcp.SearchMetadataTest do
  use ExUnit.Case, async: false
  alias StdioMcp.{PackageDoc, Repo, Vector}
  alias StdioMcp.Docs.{IngestionJob, RepairBudget, Search, TarballIngestion}

  setup do
    Repo.delete_all(PackageDoc)
    previous_root = System.get_env("PROJECT_ROOT")
    System.delete_env("PROJECT_ROOT")
    original_timeout = Application.get_env(:stdio_mcp, :ingest_timeout_ms)
    original_hex = Application.get_env(:stdio_mcp, :hex_api_url)

    on_exit(fn ->
      if original_hex,
        do: Application.put_env(:stdio_mcp, :hex_api_url, original_hex),
        else: Application.delete_env(:stdio_mcp, :hex_api_url)

      if previous_root,
        do: System.put_env("PROJECT_ROOT", previous_root),
        else: System.delete_env("PROJECT_ROOT")

      if original_timeout,
        do: Application.put_env(:stdio_mcp, :ingest_timeout_ms, original_timeout),
        else: Application.delete_env(:stdio_mcp, :ingest_timeout_ms)
    end)

    :ok
  end

  test "cached explicit version metadata survives empty retrieval" do
    insert("fixture", "1.0.0")
    result = Search.search_detailed("absent", package: "fixture", version: "1.0.0")
    assert result.results == []
    assert result.index_status == :ready
    refute result.ingested_this_request
    assert result.resolved_version == "1.0.0"
    assert result.version_source == :explicit
    assert is_integer(result.elapsed_ms) and result.elapsed_ms >= 0
  end

  test "project lock and server application identify cached version authority" do
    root = Path.join(System.tmp_dir!(), "metadata-lock-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(
      Path.join(root, "mix.lock"),
      ~s(%{"fixture": {:hex, :fixture, "1.0.0", "checksum"}})
    )

    System.put_env("PROJECT_ROOT", root)
    insert("fixture", "1.0.0")
    assert Search.search_detailed("answer", package: "fixture").version_source == :project_lock
    System.delete_env("PROJECT_ROOT")
    version = Application.spec(:logger, :vsn) |> to_string()
    insert("logger", version)
    assert Search.search_detailed("answer", package: "logger").version_source == :server_app
  end

  test "missing scope and invalid options expose unchecked metadata" do
    for opts <- [[], [package: "fixture", limit: 0]] do
      result = Search.search_detailed("answer", opts)
      assert result.index_status == :not_checked
      assert result.resolved_version == nil
      assert result.version_source == nil
      refute result.ingested_this_request
    end
  end

  test "exhausted repair is incomplete rather than a successful ingestion" do
    insert("fixture", "1.0.0", nil)
    for _ <- 1..RepairBudget.max_attempts(), do: RepairBudget.record_attempt("fixture", "1.0.0")
    on_exit(fn -> RepairBudget.clear("fixture", "1.0.0") end)
    result = Search.search_detailed("answer", package: "fixture", version: "1.0.0")
    assert result.index_status == :incomplete
    refute result.ingested_this_request
    assert length(result.results) == 1
  end

  test "pending ingestion exposes target metadata and preserves cached result versions" do
    insert("eex", "0.0.1")
    Application.put_env(:stdio_mcp, :ingest_timeout_ms, 1)

    job =
      job("eex", System.version(), fn ->
        Process.sleep(150)
        {:ok, 1, System.version()}
      end)

    result = Search.search_detailed("answer", package: "eex", refresh: true)
    assert result.index_status == :indexing
    refute result.ingested_this_request
    assert result.resolved_version == System.version()
    assert result.version_source == :server_elixir
    assert [%{version: "0.0.1"}] = result.results
    Task.await(job)
  end

  test "joined successful ingestion reports completion even with no lexical matches" do
    Application.put_env(:stdio_mcp, :ingest_timeout_ms, 1_000)

    job =
      job("eex", "1.0.0", fn ->
        Process.sleep(150)
        insert("eex", "1.0.0")
        {:ok, 1, "1.0.0"}
      end)

    result = Search.search_detailed("absent", package: "eex", version: "1.0.0")
    assert result.index_status == :ready
    assert result.ingested_this_request
    assert result.resolved_version == "1.0.0"
    assert result.version_source == :explicit
    assert result.results == []
    Task.await(job)
  end

  test "failed ingestion reports the selected target without claiming completion" do
    job =
      job("eex", "1.0.0", fn ->
        Process.sleep(150)
        {:error, :fixture_failure}
      end)

    result = Search.search_detailed("answer", package: "eex", version: "1.0.0")
    assert result.index_status == :error
    refute result.ingested_this_request
    assert result.resolved_version == "1.0.0"
    assert result.version_source == :explicit
    Task.await(job)
  end

  test "retained cache reports its version even when Hex advertises a newer release" do
    hex_metadata(200, %{"latest_stable_version" => "2.0.0"})
    insert("fixture", "1.0.0")
    result = Search.search_detailed("answer", package: "fixture")
    assert result.index_status == :ready
    assert result.resolved_version == "1.0.0"
    assert result.version_source == :cache
    refute result.ingested_this_request
    assert Enum.any?(result.notices, &String.contains?(&1, "2.0.0"))
  end

  test "Hex latest resolution is carried through joined ingestion" do
    hex_metadata(200, %{"latest_stable_version" => "2.0.0"})

    job =
      job("fixture", "2.0.0", fn ->
        Process.sleep(150)
        insert("fixture", "2.0.0")
        {:ok, 1, "2.0.0"}
      end)

    result = Search.search_detailed("answer", package: "fixture")
    assert result.index_status == :ready
    assert result.ingested_this_request
    assert result.resolved_version == "2.0.0"
    assert result.version_source == :hex_latest
    Task.await(job)
  end

  test "version resolution failure does not invent a resolved version" do
    hex_metadata(404, %{})
    result = Search.search_detailed("answer", package: "nonexistent")
    assert result.index_status == :error
    assert result.resolved_version == nil
    assert result.version_source == nil
    refute result.ingested_this_request
  end

  # Hex metadata uses GET rather than the embedding stub's JSON POST protocol.
  defp hex_metadata(status, body) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)

    server =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
        json = Jason.encode!(body)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 #{status} Response\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(json)}\r\nconnection: close\r\n\r\n#{json}"
        )

        :gen_tcp.close(socket)
      end)

    Application.put_env(:stdio_mcp, :hex_api_url, "http://localhost:#{port}")

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :kill)
    end)
  end

  defp job(package, version, work) do
    parent = self()

    Task.async(fn ->
      IngestionJob.run(TarballIngestion, package, version, 2_000, fn ->
        send(parent, :job_ready)
        work.()
      end)
    end)
    |> tap(fn _ -> assert_receive :job_ready end)
  end

  defp insert(package, version, embedding \\ Vector.encode!([1.0, 0.0])) do
    Repo.insert!(%PackageDoc{
      package: package,
      version: version,
      doc_type: "function",
      content: "answer",
      embedding: embedding
    })
  end
end
