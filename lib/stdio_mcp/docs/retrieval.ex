defmodule StdioMcp.Docs.Retrieval do
  @moduledoc "Runs independent retrieval arms sequentially, preserving healthy results."
  alias StdioMcp.Docs.Fusion

  def run(keyword_arm, vector_arm, limit, ranker \\ &Fusion.rrf/2) do
    keyword = attempt(:keyword, keyword_arm)
    vector = attempt(:vector, vector_arm)

    mode =
      case {keyword, vector} do
        {{:ok, _}, {:ok, _}} -> :hybrid
        {{:ok, _}, _} -> :keyword
        {_, {:ok, _}} -> :vector
        _ -> :none
      end

    ids = for {:ok, ids} <- [keyword, vector], do: ids
    notices = for {:error, notice} <- [keyword, vector], do: notice
    {ranker.(ids, limit), notices, mode}
  end

  defp attempt(_name, nil), do: :unavailable

  defp attempt(name, work) do
    {:ok, work.()}
  rescue
    exception -> {:error, "#{name} retrieval failed: #{Exception.message(exception)}"}
  end
end
