defmodule StdioMcp.Tools.GetDoc do
  @moduledoc """
  Read an indexed search result and neighboring chunks from the same documentation
  entry, in source order. No network requests or embeddings are needed.

  IDs are local to the current index and may disappear after re-ingestion. Search
  again if an ID is missing. Neighbors never cross package, version, or entry URL.
  """
  use Anubis.Server.Component, type: :tool
  import Ecto.Query
  alias Anubis.Server.Response
  alias StdioMcp.{PackageDoc, Repo}

  @fields [
    :id,
    :package,
    :version,
    :doc_type,
    :module,
    :function,
    :signature,
    :content,
    :code_snippet,
    :hexdocs_url,
    :source_url
  ]

  schema do
    field(:id, :integer,
      required: true,
      description: "Documentation chunk ID returned by search_docs."
    )

    field(:neighbors, :integer,
      description:
        "Chunks to include on each side, 0–5. Defaults to 1. Use continuation IDs to read longer entries."
    )
  end

  @impl true
  def execute(params, frame) do
    payload = fetch(params[:id], Map.get(params, :neighbors, 1))
    {:reply, Response.text(Response.tool(), Jason.encode!(payload)), frame}
  end

  @doc false
  def fetch(id, neighbors \\ 1)

  def fetch(id, neighbors)
      when is_integer(id) and id > 0 and is_integer(neighbors) and neighbors in 0..5 do
    # Keep anchor and neighbors in one snapshot if ingestion replaces the package.
    {:ok, payload} =
      Repo.transaction(fn ->
        case Repo.get(PackageDoc, id) do
          nil ->
            %{
              error: "not_found",
              id: id,
              notices: ["Chunk not found; search again if the package was re-ingested."]
            }

          doc ->
            entry =
              from(d in PackageDoc,
                where: d.package == ^doc.package and d.version == ^doc.version,
                where: d.doc_type == ^doc.doc_type
              )

            # Missing URLs cannot establish a shared entry; return the anchor alone.
            entry =
              if is_binary(doc.hexdocs_url) and doc.hexdocs_url != "" do
                from(d in entry, where: d.hexdocs_url == ^doc.hexdocs_url)
              else
                from(d in entry, where: d.id == ^id)
              end

            before =
              Repo.all(
                from(d in entry,
                  where: d.id < ^id,
                  order_by: [desc: d.id],
                  limit: ^(neighbors + 1)
                )
              )

            after_docs =
              Repo.all(
                from(d in entry, where: d.id > ^id, order_by: d.id, limit: ^(neighbors + 1))
              )

            chunks =
              Enum.reverse(Enum.take(before, neighbors)) ++
                [doc] ++ Enum.take(after_docs, neighbors)

            %{
              requested_id: id,
              chunks: Enum.map(chunks, &Map.take(&1, @fields)),
              previous_id: continuation(before, neighbors),
              next_id: continuation(after_docs, neighbors),
              complete?: length(before) <= neighbors and length(after_docs) <= neighbors,
              notices: []
            }
        end
      end)

    payload
  end

  def fetch(_id, _neighbors),
    do: %{
      error: "invalid_arguments",
      notices: ["id must be a positive integer; neighbors must be an integer from 0 to 5."]
    }

  defp continuation(docs, neighbors) do
    case Enum.at(docs, neighbors) do
      nil -> nil
      doc -> doc.id
    end
  end
end
