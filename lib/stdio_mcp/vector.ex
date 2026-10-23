defmodule StdioMcp.Vector do
  @moduledoc """
  Nonempty little-endian float32 vectors, stored and bound to SQLite as BLOBs.

  Numeric lists are accepted at the boundary. Values are packed
  once, rather than parsing the same JSON for every row of a cosine scan.
  This is the float32 representation sqlite-vec already uses, not quantization
  to a smaller dimension or a change of embedding model.
  """
  use Ecto.Type

  @impl true
  def type, do: :binary

  @impl true
  def cast(nil), do: {:ok, nil}

  def cast([_ | _] = values) do
    if Enum.all?(values, &is_number/1) do
      {:ok, for(value <- values, into: <<>>, do: <<value::float-32-little>>)}
    else
      :error
    end
  rescue
    ArgumentError -> :error
  end

  def cast(value) when is_binary(value) do
    if byte_size(value) > 0 and rem(byte_size(value), 4) == 0, do: {:ok, value}, else: :error
  end

  def cast(_value), do: :error

  @impl true
  def dump(value), do: cast(value)

  @impl true
  def load(value), do: cast(value)

  def encode!(value) do
    case cast(value) do
      {:ok, binary} -> binary
      :error -> raise ArgumentError, "expected a nonempty float32 vector or numeric list"
    end
  end

  # JSON decoding is explicit: a valid packed float can happen to contain bytes
  # that look like JSON, so storage must never guess its encoding from its prefix.
  def from_json!(json), do: json |> Jason.decode!() |> encode!()

  def dimensions(value) do
    case encode!(value) do
      nil -> nil
      binary -> div(byte_size(binary), 4)
    end
  end
end
