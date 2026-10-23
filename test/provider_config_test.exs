defmodule StdioMcp.ProviderConfigTest do
  use ExUnit.Case, async: false

  alias StdioMcp.AI.Client
  alias StdioMcp.Knowledge
  alias StdioMcp.Knowledge.Decision
  alias StdioMcp.Memory
  alias StdioMcp.Repo
  alias StdioMcp.Tools.Recall
  alias StdioMcp.Tools.Remember

  @runtime Path.expand("../config/runtime.exs", __DIR__)
  @variables ~w(AI_PROVIDER AI_API_KEY AI_API_URL AI_EMBED_URL AI_CHAT_URL AI_EMBED_MODEL
    AI_CHAT_MODEL_SMALL AI_CHAT_MODEL_LARGE MEMORY_ENABLED EMBED_BATCH_SIZE
    EMBED_CONCURRENCY EMBED_PAUSE_MS)

  setup do
    original_env = Map.new(@variables, &{&1, System.get_env(&1)})
    original_app = Application.get_all_env(:stdio_mcp)
    Enum.each(@variables, &System.delete_env/1)

    on_exit(fn ->
      for {name, value} <- original_env do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end

      for {key, _} <- Application.get_all_env(:stdio_mcp),
          do: Application.delete_env(:stdio_mcp, key)

      for {key, value} <- original_app, do: Application.put_env(:stdio_mcp, key, value)
    end)

    :ok
  end

  test "hosted presets need only a provider and key; legacy default stays Mistral" do
    System.put_env("AI_API_KEY", "fixture-key")
    config = resolve()
    assert config[:ai_provider] == "mistral"
    assert config[:ai_embed_model] == "mistral-embed"
    assert config[:ai_chat_model_large] == "mistral-large-latest"
    refute config[:memory_enabled]

    System.put_env("AI_PROVIDER", " OpenAI ")
    config = resolve()
    assert config[:ai_api_key] == "fixture-key"
    assert config[:ai_api_url] == "https://api.openai.com/v1"
    assert config[:ai_embed_url] == config[:ai_api_url]
    assert config[:ai_chat_url] == config[:ai_api_url]
    assert config[:ai_embed_model] == "text-embedding-3-small"
    assert config[:ai_chat_model_small] == "gpt-4o-mini"
    assert config[:ai_chat_model_large] == "gpt-4o-mini"
    refute config[:memory_enabled]

    System.delete_env("AI_API_KEY")
    assert resolve()[:ai_api_key] == nil
  end

  test "Ollama needs no key and uses local models and conservative ingestion" do
    System.put_env("AI_PROVIDER", "ollama")
    config = resolve()
    assert config[:ai_api_key] == "ollama"
    assert config[:ai_api_url] == "http://localhost:11434/v1"
    assert config[:ai_embed_model] == "embeddinggemma"
    assert config[:ai_chat_model_small] == "llama3.2"
    assert config[:ai_chat_model_large] == "llama3.2"
    assert config[:embed_batch_size] == 8
    assert config[:embed_concurrency] == 1
    assert config[:embed_pause_ms] == 200
    refute config[:memory_enabled]
  end

  test "explicit endpoints, models, keys and ingestion settings override a preset" do
    System.put_env(%{
      "AI_PROVIDER" => "ollama",
      "AI_API_KEY" => "custom-key",
      "AI_API_URL" => "http://shared/v1",
      "AI_EMBED_URL" => "http://embed/v1",
      "AI_CHAT_URL" => "http://chat/v1",
      "AI_EMBED_MODEL" => "custom-embed",
      "AI_CHAT_MODEL_SMALL" => "custom-small",
      "AI_CHAT_MODEL_LARGE" => "custom-large",
      "EMBED_BATCH_SIZE" => "32",
      "EMBED_CONCURRENCY" => "3",
      "EMBED_PAUSE_MS" => "0",
      "MEMORY_ENABLED" => "true"
    })

    config = resolve()
    assert config[:ai_api_key] == "custom-key"
    assert config[:ai_api_url] == "http://shared/v1"
    assert config[:ai_embed_url] == "http://embed/v1"
    assert config[:ai_chat_url] == "http://chat/v1"
    assert config[:ai_embed_model] == "custom-embed"
    assert config[:ai_chat_model_small] == "custom-small"
    assert config[:ai_chat_model_large] == "custom-large"
    assert config[:embed_batch_size] == 32
    assert config[:embed_concurrency] == 3
    assert config[:embed_pause_ms] == 0
    assert config[:memory_enabled]

    System.delete_env("AI_EMBED_URL")
    System.delete_env("AI_CHAT_URL")
    assert resolve()[:ai_embed_url] == "http://shared/v1"
    assert resolve()[:ai_chat_url] == "http://shared/v1"
  end

  test "invalid selections fail clearly rather than choosing a different provider" do
    System.put_env("AI_PROVIDER", "open-ai")
    assert_raise ArgumentError, ~r/Unknown AI_PROVIDER/, &resolve/0
    System.put_env("AI_PROVIDER", "mistral")
    System.put_env("MEMORY_ENABLED", "yesplease")
    assert_raise ArgumentError, ~r/Invalid MEMORY_ENABLED/, &resolve/0
  end

  test "remember is disabled with a valid key until explicitly enabled" do
    System.put_env("AI_PROVIDER", "openai")
    System.put_env("AI_API_KEY", "fixture-key")
    apply_runtime()
    refute Client.memory_enabled?()

    before = Repo.aggregate(Decision, :count)
    assert {:reply, response, %{}} = Remember.execute(%{texts: ["A lesson"]}, %{})
    [%{"text" => text}] = response.content
    assert %{"status" => "disabled", "reason" => reason} = Jason.decode!(text)
    assert reason =~ "MEMORY_ENABLED=true"
    assert Repo.aggregate(Decision, :count) == before
    assert {:error, :memory_disabled} = Memory.process_remember("A lesson", nil)

    System.put_env("MEMORY_ENABLED", "true")
    apply_runtime()
    assert Client.memory_enabled?()

    Application.put_env(:stdio_mcp, :ai_api_key, nil)
    refute Client.memory_enabled?()
    Application.put_env(:stdio_mcp, :ai_api_key, "fixture-key")
    Application.put_env(:stdio_mcp, :ai_chat_model_large, "")
    refute Client.memory_enabled?()
  end

  test "preset embeddings work while memory is disabled, without chat requests" do
    test_pid = self()

    {url, stop} =
      ProviderStub.start(fn body ->
        send(test_pid, {:provider_request, body})
        {200, %{"data" => [%{"embedding" => [1.0, 0.0]}]}}
      end)

    on_exit(stop)
    System.put_env("AI_PROVIDER", "openai")
    System.put_env("AI_API_KEY", "fixture-key")
    System.put_env("AI_API_URL", url)
    apply_runtime()

    assert {:ok, [1.0, 0.0]} = Client.embed("Documentation query")

    assert_receive {:provider_request,
                    %{"model" => "text-embedding-3-small", "input" => ["Documentation query"]}}

    assert {:reply, _, %{}} = Remember.execute(%{texts: ["A lesson"]}, %{})
    refute_receive {:provider_request, _}, 100
  end

  test "recall can read an existing memory with curation disabled and no API key" do
    apply_runtime()
    refute Client.memory_enabled?()

    entry =
      Repo.insert!(%Knowledge{
        title: "Presetrecallfixture",
        kind: "pattern",
        content: "Presetrecallfixture documents an existing lesson."
      })

    on_exit(fn -> Repo.delete(entry) end)

    assert {:reply, response, %{}} =
             Recall.execute(%{query: "Presetrecallfixture"}, %{})

    [%{"text" => text}] = response.content
    assert Enum.any?(Jason.decode!(text), &(&1["id"] == entry.id))
    assert Repo.get!(Knowledge, entry.id).content == entry.content
  end

  defp resolve do
    @runtime |> Config.Reader.read!(env: :test) |> Keyword.fetch!(:stdio_mcp)
  end

  defp apply_runtime do
    for {key, value} <- resolve(), do: Application.put_env(:stdio_mcp, key, value)
  end
end
