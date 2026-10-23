defmodule StdioMcp.Repo.Migrations.PackVectors do
  use Ecto.Migration

  # SQLite can store BLOBs in the existing columns despite their TEXT affinity.
  # Converting values in place avoids rebuilding tables, indexes or FTS triggers.
  # vec_f32 is the same conversion cosine previously performed on every scan;
  # model, dimensions, provenance, timestamps and document IDs stay unchanged.
  def up do
    for table <- ["package_docs", "knowledge"] do
      execute(
        "UPDATE #{table} SET embedding=NULL WHERE typeof(embedding)='text' AND trim(embedding)=''"
      )

      execute("UPDATE #{table} SET embedding=vec_f32(embedding) WHERE typeof(embedding)='text'")
    end
  end

  def down do
    for table <- ["package_docs", "knowledge"] do
      execute(fn -> unpack(table) end)
    end
  end

  # vec_to_json formats floats to six decimal places. It is suitable for display,
  # but changes float32 values on a round trip. Jason preserves enough precision
  # to recover the exact binary value. Batches bound memory during rollback.
  defp unpack(table) do
    case Ecto.Adapters.SQL.query!(
           repo(),
           "SELECT id,embedding FROM #{table} WHERE typeof(embedding)='blob' LIMIT 200",
           []
         ).rows do
      [] ->
        :ok

      rows ->
        Enum.each(rows, fn [id, binary] ->
          values = for <<value::float-32-little <- binary>>, do: value

          Ecto.Adapters.SQL.query!(
            repo(),
            "UPDATE #{table} SET embedding=? WHERE id=?",
            [Jason.encode!(values), id]
          )
        end)

        unpack(table)
    end
  end
end
