defmodule StdioMcp.Docs.Judgements do
  @moduledoc """
  Human relevance judgements for the eval query set.

  ## Why this exists

  `mix docs.eval` scored each query against a single expectation — a substring
  that had to appear in one stored column. That mark means "matches the string
  chosen in advance", not "is a good answer", and the two came apart repeatedly:

    * `client_credentials` matched three `iex>` samples and no explanation.
    * `PKCE` matched a typespec listing `pkce: boolean()` among thirty fields,
      while the guide that answers the question ranked 8th.
    * `busy_timeout` missed `Transaction mode`, which tells you to set
      `default_transaction_mode: :immediate` — the actual remedy for lock
      contention under concurrent writes.

  A single-target expectation can only ever mark one row correct, while a good
  result set is usually several rows correct. So the old metric was a **floor**
  on answer quality, reported as if it described it.

  Judgements replace the guess with a record: a human reads what the pipeline
  returned and marks each result relevant or not. That is how retrieval is
  normally evaluated, and judging output is far cheaper than inventing targets.

  ## Chunk identity

  Judgements use package, URL and a hash of the exact chunk content. Unchanged
  chunks retain their marks across re-ingestion; changed chunks require a new
  judgement. Page-level legacy marks never apply to an arbitrary sibling chunk.
  """

  @path "priv/eval/judgements.md"

  @typedoc "Query text -> {package, url} -> :yes | :no"
  @type t :: %{String.t() => %{{String.t(), String.t()} => :yes | :no}}

  @doc "Where the judgements file lives, relative to the project root."
  @spec path() :: String.t()
  def path, do: @path

  @doc """
  Reads the judgements file.

  Returns an empty map when it does not exist yet, so the first `mix docs.judge`
  run has something to merge into.
  """
  @spec load() :: t()
  def load do
    case File.read(@path) do
      {:ok, text} -> parse(text)
      {:error, _} -> %{}
    end
  end

  @doc "Looks up a judgement. `:unjudged` when the pair has never been marked."
  @spec verdict(t(), String.t(), String.t(), String.t()) :: :yes | :no | :unjudged
  def verdict(judgements, query, package, url) do
    judgements
    |> Map.get(query, %{})
    |> Map.get({package, url}, :unjudged)
  end

  @doc "A chunk key, without changing its citable URL."
  def key(url, content) do
    hash = :crypto.hash(:sha256, to_string(content)) |> Base.encode16(case: :lower)
    "#{url}	#{hash}"
  end

  # A line-oriented format rather than a data structure, because the whole point
  # is that a person edits it: flipping `?` to `y` is one keystroke, and a diff
  # of the file reads as a list of decisions.
  defp parse(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({%{}, nil}, fn line, {acc, query} ->
      cond do
        String.starts_with?(line, "## ") ->
          {acc, String.trim_leading(line, "## ")}

        query && Regex.match?(~r/^[yn?]\s+\S/, line) ->
          {mark, package, url} = parse_entry(line)

          case mark do
            :unjudged -> {acc, query}
            verdict -> {put_in_query(acc, query, {package, url}, verdict), query}
          end

        true ->
          {acc, query}
      end
    end)
    |> elem(0)
  end

  defp parse_entry(line) do
    [mark, rest] = String.split(line, " ", parts: 2)
    [package, url | tail] = String.split(String.trim(rest), "\t")

    url =
      case tail do
        [hash | _] -> url <> "\t" <> hash
        [] -> url
      end

    verdict =
      case mark do
        "y" -> :yes
        "n" -> :no
        _ -> :unjudged
      end

    {verdict, package, url}
  end

  defp put_in_query(acc, query, key, verdict) do
    Map.update(acc, query, %{key => verdict}, &Map.put(&1, key, verdict))
  end

  @doc """
  Renders the file.

  `entries` is `[{query, kind, [%{package:, url:, signature:, content:}]}]`.
  Existing verdicts are carried over so regenerating after a re-index does not
  discard work — only genuinely new documents come back as `?`.
  """
  @spec render([{String.t(), atom(), [map()]}], t()) :: String.t()
  def render(entries, existing) do
    header = """
    # Relevance judgements

    Mark each result: `y` relevant, `n` not, `?` undecided. Only the leading
    character matters; everything after the tab-separated package and URL is
    there for you to read.

    A judgement is keyed on package + URL + chunk content hash. Unchanged chunks
    retain their marks; changed chunks and legacy page-level marks need review.

    Score against these with `mix docs.eval --judged`.
    """

    body =
      Enum.map_join(entries, "\n", fn {query, kind, results} ->
        rows =
          results
          |> Enum.uniq_by(&{&1.package, key(&1.url, &1.content)})
          |> Enum.map_join("\n\n", fn r ->
            mark =
              case verdict(existing, query, r.package, key(r.url, r.content)) do
                :yes -> "y"
                :no -> "n"
                :unjudged -> "?"
              end

            excerpt =
              r.content |> to_string() |> String.replace(~r/\s+/, " ") |> String.slice(0, 150)

            "#{mark} #{r.package}\t#{key(r.url, r.content)}\n  #{r.signature}\n  #{excerpt}"
          end)

        "\n## #{query}\n<!-- #{kind} -->\n\n#{rows}\n"
      end)

    header <> body
  end
end
