if Process.whereis(StdioMcp.Repo) do
  raise "Run mix test --no-start so the test helper can select its disposable database before app startup."
end

ExUnit.start()
Logger.configure(level: :error)

# Run with mix test --no-start: all DB writes go to this disposable database.
System.delete_env("MCP_TRANSPORT")

database =
  Path.join(System.tmp_dir!(), "hex_search_test_#{System.unique_integer([:positive])}.db")

config = Application.fetch_env!(:stdio_mcp, StdioMcp.Repo)

Application.put_env(
  :stdio_mcp,
  StdioMcp.Repo,
  Keyword.merge(config, database: database, pool_size: 1)
)

Application.put_env(:stdio_mcp, :ai_api_key, nil)
{:ok, _} = Application.ensure_all_started(:stdio_mcp)
Logger.configure(level: :error)

ExUnit.after_suite(fn _ ->
  Application.stop(:stdio_mcp)
  for suffix <- ["", "-wal", "-shm"], do: File.rm(database <> suffix)
end)

defmodule ProviderStub do
  def start(handler) do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_, port}} = :inet.sockname(listener)
    {:ok, pid} = Task.start(fn -> accept(listener, handler) end)

    {"http://localhost:#{port}",
     fn ->
       :gen_tcp.close(listener)
       Process.exit(pid, :kill)
     end}
  end

  defp accept(listener, handler) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {:ok, _} = Task.start(fn -> serve(socket, handler) end)
        accept(listener, handler)

      {:error, :closed} ->
        :ok
    end
  end

  defp serve(socket, handler) do
    request = read(socket, "")
    body = request |> String.split("\r\n\r\n", parts: 2) |> List.last() |> Jason.decode!()
    {status, response} = handler.(body)
    json = Jason.encode!(response)

    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} Response\r\ncontent-type: application/json\r\ncontent-length: #{byte_size(json)}\r\nconnection: close\r\n\r\n#{json}"
    )

    :gen_tcp.close(socket)
  end

  defp read(socket, acc) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    acc = acc <> bytes

    case String.split(acc, "\r\n\r\n", parts: 2) do
      [headers, body] ->
        [_, length] = Regex.run(~r/content-length: (\d+)/i, headers)
        if byte_size(body) >= String.to_integer(length), do: acc, else: read(socket, acc)

      _ ->
        read(socket, acc)
    end
  end
end
