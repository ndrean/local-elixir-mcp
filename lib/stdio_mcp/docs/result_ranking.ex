defmodule StdioMcp.Docs.ResultRanking do
  @moduledoc """
  Applies a soft information-content prior to documentation candidates.

  Heading-only entries, title restatements and bare typespecs receive 40% of their
  RRF score for prose queries. They remain candidates and are returned when
  nothing stronger matches. Identifier queries retain the original RRF order.
  No preference is based on module names, test namespaces or document length.
  """
  alias StdioMcp.Docs.Fusion

  @identifier ~r/^[:\p{L}_][\p{L}\p{N}_.:!?]*(?:\/\d+)?$/u
  @stopwords ~w(a an the of for with and or to in is)
  # At depth 15 and k=60, even the strongest two-arm stub (2/61 * 0.4)
  # stays below an informative single-arm candidate at rank 15 (1/75).
  @thin_weight 0.4

  @doc "Ranks the entire union before applying the output limit."
  def rank(docs, ranked_lists, query, limit) do
    scores = Fusion.scores(ranked_lists)
    identifier? = Regex.match?(@identifier, query |> String.trim() |> String.trim("`"))

    docs
    |> Enum.sort_by(fn doc ->
      weight = if identifier? or informative?(doc), do: 1.0, else: @thin_weight
      -Map.fetch!(scores, doc.id) * weight
    end)
    |> Enum.take(limit)
  end

  defp informative?(doc) do
    body =
      (doc.content || "")
      |> String.replace(~r/^\s{0,3}\#{1,6}\s+.*$/m, "")
      |> String.trim()

    cond do
      body == "" -> false
      bare_typespec?(doc.doc_type, body) -> false
      true -> not MapSet.subset?(terms(body), terms(doc.signature || ""))
    end
  end

  defp bare_typespec?(type, body) when type in ["type", "opaque"] do
    body |> String.replace(~r/```.*?```/s, "") |> String.trim() == ""
  end

  defp bare_typespec?(_type, _body), do: false

  defp terms(text) do
    text
    |> String.replace(~r/(\p{Ll}|\d)(\p{Lu})/u, "\\1 \\2")
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> MapSet.new()
  end
end
