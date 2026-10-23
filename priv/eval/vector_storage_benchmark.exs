# Run before and after upgrading, against the same frozen database and query file:
# mix run priv/eval/vector_storage_benchmark.exs --queries /tmp/queries.json --output /tmp/before.json
# mix run priv/eval/vector_storage_benchmark.exs --queries /tmp/queries.json --output /tmp/after.json --compare /tmp/before.json
# Input: {"model":"<index model>","queries":[{"package":"...","version":"...","query":"...","embedding":[...]}]}
# Uses saved vectors only: no embedding requests or automatic package ingestion.
defmodule VectorStorageBenchmark do
  alias Ecto.Adapters.SQL
  alias StdioMcp.Docs.Search
  alias StdioMcp.Repo

  def run do
    {opts, []} =
      OptionParser.parse!(System.argv(),
        strict: [queries: :string, output: :string, compare: :string, samples: :integer]
      )

    input = opts |> Keyword.fetch!(:queries) |> File.read!() |> Jason.decode!()
    samples = Keyword.get(opts, :samples, 5)
    true = samples > 0

    [[model, dims]] =
      SQL.query!(Repo, "SELECT model, dims FROM embedding_config WHERE id=1", []).rows

    true = input["model"] == model
    true = StdioMcp.AI.Client.embed_model() == model

    checksums =
      for table <- ["package_docs", "knowledge"], into: %{} do
        columns =
          SQL.query!(Repo, "PRAGMA table_info(#{table})", []).rows |> Enum.map(&Enum.at(&1, 1))

        select =
          Enum.map_join(columns, ",", fn
            "embedding" -> "CASE WHEN embedding IS NULL THEN NULL ELSE vec_f32(embedding) END"
            name -> name
          end)

        rows = SQL.query!(Repo, "SELECT #{select} FROM #{table} ORDER BY id", []).rows

        stats =
          SQL.query!(
            Repo,
            "SELECT typeof(embedding), count(*), sum(length(embedding)) FROM #{table} GROUP BY typeof(embedding)",
            []
          ).rows

        {table, %{rows: length(rows), checksum: hash(rows), storage: stats}}
      end

    runs =
      Enum.map(input["queries"], fn q ->
        true = length(q["embedding"]) == dims

        [[count]] =
          SQL.query!(Repo, "SELECT count(*) FROM package_docs WHERE package=? AND version=?", [
            q["package"],
            q["version"]
          ]).rows

        true = count > 0
        json = Jason.encode!(q["embedding"])

        search = fn ->
          Search.search_detailed(q["query"],
            package: q["package"],
            version: q["version"],
            embedding: json
          )
        end

        %{retrieval_mode: :hybrid, notices: []} = search.()

        times =
          for _ <- 1..samples do
            {us, %{retrieval_mode: :hybrid, notices: [], results: results}} = :timer.tc(search)
            {us / 1000, Enum.map(results, & &1.id)}
          end

        ids = times |> hd() |> elem(1)
        true = Enum.all?(times, &(elem(&1, 1) == ids))

        [[storage]] =
          SQL.query!(
            Repo,
            "SELECT typeof(embedding) FROM package_docs WHERE package=? AND version=? AND embedding IS NOT NULL LIMIT 1",
            [q["package"], q["version"]]
          ).rows

        param = if storage == "blob", do: {:blob, pack(q["embedding"])}, else: json

        cosine =
          SQL.query!(
            Repo,
            "SELECT id, vec_distance_cosine(embedding, ?) AS distance FROM package_docs WHERE package=? AND version=? AND embedding IS NOT NULL ORDER BY distance",
            [param, q["package"], q["version"]]
          ).rows

        ms = Enum.map(times, &elem(&1, 0))
        IO.puts(Jason.encode!(%{query: q["query"], median_ms: median(ms)}))

        %{
          query: q["query"],
          package: q["package"],
          version: q["version"],
          ids: ids,
          cosine: cosine,
          ms: ms
        }
      end)

    report = %{
      model: model,
      dims: dims,
      corpus: checksums,
      runs: runs,
      median_query_ms: median(Enum.map(runs, &median(&1.ms))),
      p95_ms: percentile(Enum.flat_map(runs, & &1.ms), 0.95)
    }

    File.write!(Keyword.fetch!(opts, :output), Jason.encode!(report))
    IO.puts(Jason.encode!(Map.drop(report, [:runs])))
    if before_path = opts[:compare], do: compare(Jason.decode!(File.read!(before_path)), report)
  end

  defp compare(before, report) do
    true = before["model"] == report.model and before["dims"] == report.dims
    true = length(before["runs"]) == length(report.runs)

    for {table, corpus} <- report.corpus do
      true = before["corpus"][table]["checksum"] == corpus.checksum
    end

    for {old, new} <- Enum.zip(before["runs"], report.runs) do
      true =
        {old["query"], old["package"], old["version"]} == {new.query, new.package, new.version}

      true = old["ids"] == new.ids
      true = old["cosine"] == new.cosine
    end

    IO.puts(
      "Verified identical corpus values, model, dimensions, full cosine distances/order and final result order for all #{length(report.runs)} queries."
    )

    IO.puts(
      "Retrieval speedup: #{Float.round(before["median_query_ms"] / report.median_query_ms, 2)}x"
    )
  end

  defp pack(values), do: for(value <- values, into: <<>>, do: <<value::float-32-little>>)

  defp hash(value),
    do: :crypto.hash(:sha256, :erlang.term_to_binary(value)) |> Base.encode16(case: :lower)

  defp median(values), do: values |> Enum.sort() |> Enum.at(div(length(values), 2))
  defp percentile(values, p), do: values |> Enum.sort() |> Enum.at(ceil(length(values) * p) - 1)
end

VectorStorageBenchmark.run()
