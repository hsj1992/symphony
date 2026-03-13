defmodule SymphonyElixir.ConsoleClient do
  @moduledoc """
  HTTP client for project-local Symphony bridge endpoints.
  """

  @type adapter_option :: %{
          id: String.t(),
          label: String.t(),
          base_url: String.t(),
          token: String.t(),
          timeout_ms: pos_integer()
        }

  @type adapter_config :: %{
          base_url: String.t(),
          token: String.t(),
          timeout_ms: pos_integer()
        }

  @default_timeout_ms 15_000

  @spec meta(String.t() | nil) :: {:ok, map()} | {:error, term()}
  def meta(adapter_id \\ nil) do
    request(:get, "/meta", [], adapter_id)
  end

  @spec list_runs(nil | pos_integer(), String.t() | nil) :: {:ok, list(map())} | {:error, term()}
  def list_runs(limit \\ nil, adapter_id \\ nil) do
    request(:get, "/runs", [params: compact_params(%{limit: limit})], adapter_id)
  end

  @spec get_status(String.t(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def get_status(issue_identifier, opts \\ %{}, adapter_id \\ nil) when is_binary(issue_identifier) do
    params =
      opts
      |> Map.merge(%{issue: issue_identifier})
      |> compact_params()

    request(:get, "/status", [params: params], adapter_id)
  end

  @spec create_action(map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def create_action(attrs, adapter_id \\ nil) when is_map(attrs) do
    request(:post, "/actions", [json: compact_params(attrs)], adapter_id)
  end

  @spec list_adapters() :: [adapter_option()]
  def list_adapters do
    configured = configured_adapters()

    cond do
      configured != [] ->
        configured

      true ->
        case single_adapter_config() do
          {:ok, config} ->
            [
              %{
                id: "default",
                label: System.get_env("SYMPHONY_CONSOLE_ADAPTER_LABEL") || "Project",
                base_url: config.base_url,
                token: config.token,
                timeout_ms: config.timeout_ms
              }
            ]

          {:error, :not_configured} ->
            []
        end
    end
  end

  @spec adapter_config(String.t() | nil) :: {:ok, adapter_config()} | {:error, :not_configured}
  def adapter_config(adapter_id \\ nil) do
    adapters = list_adapters()

    if adapters != [] do
      selected =
        case adapter_id do
          nil -> List.first(adapters)
          "" -> List.first(adapters)
          id -> Enum.find(adapters, List.first(adapters), &(&1.id == id))
        end

      {:ok,
       %{
         base_url: selected.base_url,
         token: selected.token,
         timeout_ms: selected.timeout_ms
       }}
    else
      {:error, :not_configured}
    end
  end

  defp single_adapter_config do
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

  defp configured_adapters do
    env_json = System.get_env("SYMPHONY_CONSOLE_ADAPTERS_JSON")
    configured = Application.get_env(:symphony_elixir, :console_adapters, [])

    entries =
      cond do
        is_binary(env_json) and String.trim(env_json) != "" ->
          case Jason.decode(env_json) do
            {:ok, decoded} when is_list(decoded) -> decoded
            _ -> []
          end

        is_list(configured) ->
          configured

        true ->
          []
      end

    entries
    |> Enum.map(&normalize_adapter_entry/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_adapter_entry(entry) when is_map(entry) do
    id = entry["id"] || entry[:id]
    label = entry["label"] || entry[:label] || id
    base_url = entry["base_url"] || entry[:base_url]
    token = entry["token"] || entry[:token]
    token_env = entry["token_env"] || entry[:token_env]
    timeout_ms = entry["timeout_ms"] || entry[:timeout_ms] || @default_timeout_ms
    resolved_token = token || (is_binary(token_env) && System.get_env(token_env))

    with true <- is_binary(id) and id != "",
         true <- is_binary(label) and label != "",
         true <- is_binary(base_url) and base_url != "",
         true <- is_binary(resolved_token) and resolved_token != "" do
      %{
        id: id,
        label: label,
        base_url: String.trim_trailing(base_url, "/"),
        token: resolved_token,
        timeout_ms: timeout_ms
      }
    else
      _ -> nil
    end
  end

  defp normalize_adapter_entry(_entry), do: nil

  defp request(method, path, req_opts, adapter_id) do
    with {:ok, config} <- adapter_config(adapter_id),
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
