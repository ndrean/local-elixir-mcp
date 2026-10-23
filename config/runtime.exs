import Config

# `AI_*` is the canonical spelling for every provider setting. The endpoint is
# pluggable — Mistral, OpenAI, Gemini, Cohere all speak a close-enough
# embeddings API — and naming the variables after one vendor made the config
# read as though it were not.
#
# The `MISTRAL_*` spellings no longer resolve to anything. They are still
# *detected*, and only so the server can say so: two names for one setting, with
# precedence between them, is how `anubis_mcp` came to be indexed at 1536
# dimensions (codestral-embed) while every query embedded at 1024
# (mistral-embed). sqlite-vec refuses that pair, `Docs.Search.run_query/4`
# rescues the error, and the search answers from FTS alone — the vector arm was
# dead for that package and nothing reported it. A fallback that quietly supplies
# a value the operator did not intend is the same failure in a smaller costume,
# so the legacy name gets a sentence and no effect.
#
# stderr, not stdout: stdout carries JSON-RPC and must stay clean.
for {legacy, canonical} <- [
      {"MISTRAL_API_URL", "AI_API_URL"},
      {"MISTRAL_API_KEY", "AI_API_KEY"},
      {"MISTRAL_MODEL_EMBED", "AI_EMBED_MODEL"},
      {"MISTRAL_MODEL_SMALL", "AI_CHAT_MODEL_SMALL"},
      {"MISTRAL_LARGE_MODEL", "AI_CHAT_MODEL_LARGE"}
    ],
    not is_nil(System.get_env(legacy)),
    is_nil(System.get_env(canonical)) do
  IO.puts(:stderr, "[config] #{legacy} is no longer read — rename it to #{canonical}")
end

# Resolve presets here so source runs and releases use exactly the same values.
# Explicit endpoint/model settings retain precedence for existing installations.
presets = %{
  "mistral" => %{
    url: "https://api.mistral.ai/v1",
    embed: "mistral-embed",
    small: "mistral-small-latest",
    large: "mistral-large-latest",
    batch_size: 200,
    concurrency: 2,
    pause_ms: 0
  },
  "openai" => %{
    url: "https://api.openai.com/v1",
    embed: "text-embedding-3-small",
    small: "gpt-4o-mini",
    large: "gpt-4o-mini",
    batch_size: 200,
    concurrency: 2,
    pause_ms: 0
  },
  "ollama" => %{
    url: "http://localhost:11434/v1",
    embed: "embeddinggemma",
    small: "llama3.2",
    large: "llama3.2",
    batch_size: 8,
    concurrency: 1,
    pause_ms: 200
  }
}

provider = System.get_env("AI_PROVIDER", "mistral") |> String.trim() |> String.downcase()

preset =
  Map.get(presets, provider) ||
    raise ArgumentError,
          "Unknown AI_PROVIDER #{inspect(provider)}; use mistral, openai, or ollama"

memory_enabled =
  case System.get_env("MEMORY_ENABLED", "false") |> String.trim() |> String.downcase() do
    value when value in ["true", "1"] -> true
    value when value in ["false", "0"] -> false
    value -> raise ArgumentError, "Invalid MEMORY_ENABLED #{inspect(value)}; use true or false"
  end

api_url = System.get_env("AI_API_URL", preset.url)

config :stdio_mcp,
  ai_provider: provider,
  memory_enabled: memory_enabled,
  ai_api_url: api_url,
  ai_embed_url: System.get_env("AI_EMBED_URL", api_url),
  ai_chat_url: System.get_env("AI_CHAT_URL", api_url),
  ai_api_key: System.get_env("AI_API_KEY", if(provider == "ollama", do: "ollama")),
  ai_embed_model: System.get_env("AI_EMBED_MODEL", preset.embed),
  ai_chat_model_small: System.get_env("AI_CHAT_MODEL_SMALL", preset.small),
  ai_chat_model_large: System.get_env("AI_CHAT_MODEL_LARGE", preset.large),
  github_api_url: System.get_env("GITHUB_API_URL", "https://api.github.com"),
  github_token: System.get_env("GITHUB_TOKEN"),
  hex_api_url: System.get_env("HEX_API_URL", "https://hex.pm/api")

# Ingestion tuning. These three are the values that actually depend on the
# environment rather than on the code: the MCP client's request ceiling and the
# embedding provider's rate limit. Exposed as env vars so they can be adjusted
# from .mcp.json and take effect on a server restart, with no recompile.
#
# Parsing never raises — a malformed value falls back to the default rather than
# taking down every release command that loads this file.
env_int = fn name, default ->
  with value when is_binary(value) <- System.get_env(name),
       {parsed, ""} <- Integer.parse(String.trim(value)),
       true <- parsed > 0 or (name == "EMBED_PAUSE_MS" and parsed == 0) do
    parsed
  else
    _ -> default
  end
end

config :stdio_mcp,
  # Must stay below the MCP transport's own request timeout (Anubis' session
  # GenServer.call is 30s) — at or above it the request dies before the
  # "still ingesting" notice can be returned.
  ingest_timeout_ms: env_int.("INGEST_TIMEOUT_MS", 25_000),
  # Inputs per embeddings request. Mistral rate-limits on requests_per_second,
  # so a bigger batch is the strongest lever against 429s; bounded above by the
  # model's context length.
  embed_batch_size: env_int.("EMBED_BATCH_SIZE", preset.batch_size),
  # Concurrent embedding requests. Bounded by the Finch pool (size 10) and the
  # provider's rate limit — not by CPU count.
  embed_concurrency: env_int.("EMBED_CONCURRENCY", preset.concurrency),
  # Pause after each embedding request, for providers that limit
  # requests-per-second. 0 disables pacing; hosted presets default to 0 and
  # Ollama to 200 ms. Raise it if 429s persist after lowering concurrency.
  embed_pause_ms: env_int.("EMBED_PAUSE_MS", preset.pause_ms)

repo_overrides =
  [load_extensions: [SqliteVec.path()]] ++
    if(db_path = System.get_env("DATABASE_PATH"), do: [database: db_path], else: [])

config :stdio_mcp, StdioMcp.Repo, repo_overrides
