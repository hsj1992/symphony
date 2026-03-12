defmodule SymphonyElixir.ConsoleClient do
  @moduledoc """
  HTTP client for project-local Symphony bridge endpoints.
  """

  @type adapter_config :: %{
          base_url: String.t(),
          token: String.t(),
          timeout_ms: pos_integer()
        }

  @default_timeout_ms 15_000

  @spec meta() :: {:ok, map()} | {:error, term()}
  def meta do
    request(:get, "/meta")
  end

  @spec list_runs(nil | pos_integer()) :: {:ok, list(map())} | {:error, term()}
  def list_runs(limit \\ nil) do
    request(:get, "/runs", params: compact_params(%{limit: limit}))
  end

  @spec get_status(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def get_status(issue_identifier, opts \\ %{}) when is_binary(issue_identifier) do
    params =
      opts
      |> Map.merge(%{issue: issue_identifier})
      |> compact_params()

    request(:get, "/status", params: params)
  end

  @spec create_action(map()) :: {:ok, map()} | {:error, term()}
  def create_action(attrs) when is_map(attrs) do
    request(:post, "/actions", json: compact_params(attrs))
  end

  @spec adapter_config() :: {:ok, adapter_config()} | {:error, :not_configured}
  def adapter_config do
    configured = Application.get_env(:symphony_elixir, :console_adapter, [])
    base_url = System.get_env("SYMPHONY_CONSOLE_ADAPTER_BASE_URL") || configured[:base_url]
    token = System.get_env("SYMPHONY_CONSOLE_ADAPTER_TOKEN") || configured[:token]
    timeout_ms = configured[:timeout_ms] || @default_timeout_ms

    with true <- is_binary(base_url) and base_url != "",
         true <- is_binary(token) and token != "" do
      {:ok,
       %{
         base_url: String.trim_trailing(base_url, "/"),
         token: token,
         timeout_ms: timeout_ms
       }}
    else
      _ -> {:error, :not_configured}
    end
  end

  defp request(method, path, req_opts \\ []) do
    with {:ok, config} <- adapter_config(),
         {:ok, response} <- perform_request(method, config, path, req_opts) do
      case response.status do
        status when status in 200..299 -> {:ok, response.body}
        status -> {:error, {:http_error, status, response.body}}
      end
    end
  end

  defp perform_request(method, config, path, req_opts) do
    opts =
      [
        method: method,
        url: config.base_url <> path,
        receive_timeout: config.timeout_ms,
        retry: false,
        headers: [
          {"authorization", "Bearer #{config.token}"},
          {"accept", "application/json"}
        ]
      ] ++ req_opts

    case Req.request(opts) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp compact_params(map) do
    Enum.reduce(map, %{}, fn
      {_key, nil}, acc -> acc
      {_key, ""}, acc -> acc
      {key, value}, acc -> Map.put(acc, key, value)
    end)
  end
end
