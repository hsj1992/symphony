defmodule SymphonyElixirWeb.ConsoleLive do
  @moduledoc """
  Standalone bridge-backed console for project-local Symphony integrations.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  @default_refresh_ms 15_000
  @refresh_options [
    {"关闭", "off"},
    {"15s", "15000"},
    {"30s", "30000"},
    {"60s", "60000"}
  ]
  @log_options [
    {"不包含日志", "none"},
    {"执行日志", "agent"},
    {"原始日志", "raw"},
    {"全部日志", "all"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:meta, nil)
      |> assign(:runs, [])
      |> assign(:status, nil)
      |> assign(:selected_issue, nil)
      |> assign(:error_message, nil)
      |> assign(:log_options, @log_options)
      |> assign(:refresh_options, @refresh_options)
      |> assign(:issue_query, "")
      |> assign(:branch_override, "")
      |> assign(:events_limit, 10)
      |> assign(:include_logs, "none")
      |> assign(:include_doctor, true)
      |> assign(:include_workpad, true)
      |> assign(:instruction_message, "")
      |> assign(:sync_linear, true)
      |> assign(:refresh_interval_ms, @default_refresh_ms)

    socket = refresh_console(socket, load_status?: false)

    if connected?(socket) do
      schedule_refresh(socket.assigns.refresh_interval_ms)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh_tick, socket) do
    schedule_refresh(socket.assigns.refresh_interval_ms)
    {:noreply, refresh_console(socket, load_status?: not is_nil(socket.assigns.selected_issue))}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_console(socket, load_status?: not is_nil(socket.assigns.selected_issue))}
  end

  @impl true
  def handle_event("set_refresh_interval", %{"refresh_interval" => value}, socket) do
    refresh_interval_ms =
      case Integer.parse(value || "") do
        {parsed, _} when parsed in [15_000, 30_000, 60_000] -> parsed
        _ -> 0
      end

    {:noreply, assign(socket, :refresh_interval_ms, refresh_interval_ms)}
  end

  @impl true
  def handle_event("load_issue", params, socket) do
    socket =
      socket
      |> assign(:issue_query, params["issue"] || "")
      |> assign(:branch_override, params["branch"] || "")
      |> assign(:include_logs, params["include_logs"] || "none")
      |> assign(:include_doctor, truthy?(params["doctor"]))
      |> assign(:include_workpad, truthy?(params["workpad"]))
      |> assign(:events_limit, parse_integer(params["events"], socket.assigns.events_limit))

    case String.trim(socket.assigns.issue_query) do
      "" ->
        {:noreply, put_flash(socket, :error, "必须先输入议题编号")}

      issue ->
        {:noreply,
         socket
         |> assign(:selected_issue, issue)
         |> load_status()
         |> refresh_console(load_status?: false)}
    end
  end

  @impl true
  def handle_event("select_issue", %{"issue" => issue}, socket) do
    {:noreply,
     socket
     |> assign(:issue_query, issue)
     |> assign(:selected_issue, issue)
     |> load_status()}
  end

  @impl true
  def handle_event("pause", _params, socket) do
    {:noreply, perform_action(socket, %{"action" => "pause"})}
  end

  @impl true
  def handle_event("resume", _params, socket) do
    {:noreply, perform_action(socket, %{"action" => "resume"})}
  end

  @impl true
  def handle_event("append_instruction", %{"message" => message, "sync_linear" => sync_linear}, socket) do
    socket =
      socket
      |> assign(:instruction_message, message || "")
      |> assign(:sync_linear, truthy?(sync_linear))

    if String.trim(socket.assigns.instruction_message) == "" do
      {:noreply, put_flash(socket, :error, "补充指令不能为空")}
    else
      {:noreply,
       socket
       |> perform_action(%{
         "action" => "instruction",
         "message" => socket.assigns.instruction_message,
         "sync_linear" => socket.assigns.sync_linear
       })
       |> assign(:instruction_message, "")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section class="dashboard-shell">
      <header class="hero-card">
        <div class="hero-grid">
          <div>
            <p class="eyebrow">Symphony 工作流</p>
            <h1 class="hero-title">工作流控制台</h1>
            <p class="hero-copy">
              这是独立于业务前后端的 Symphony 工作流控制台。最近运行、议题详情和控制动作都通过 bridge API 完成，而不是嵌入到产品系统里。
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              <%= adapter_label(@meta) %>
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              <%= if @refresh_interval_ms > 0, do: "自动 #{div(@refresh_interval_ms, 1000)}s", else: "手动刷新" %>
            </span>
          </div>
        </div>
      </header>

      <%= if flash = Phoenix.Flash.get(@flash, :info) do %>
        <section class="section-card">
          <p class="section-copy"><%= flash %></p>
        </section>
      <% end %>

      <%= if flash = Phoenix.Flash.get(@flash, :error) do %>
        <section class="error-card">
          <p class="error-copy"><%= flash %></p>
        </section>
      <% end %>

      <%= if @error_message do %>
        <section class="error-card">
          <h2 class="error-title">Bridge 服务不可用</h2>
          <p class="error-copy"><%= @error_message %></p>
        </section>
      <% end %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">控制面板</h2>
            <p class="section-copy">从 bridge 加载议题，按需查看 doctor、workpad、日志，并调整刷新策略。</p>
          </div>
          <button type="button" class="subtle-button" phx-click="refresh">立即刷新</button>
        </div>

        <form id="issue-query-form" class="toolbar-form" phx-submit="load_issue">
          <label class="toolbar-field">
            <span>议题编号</span>
            <input class="form-input" type="text" name="issue" value={@issue_query} placeholder="例如 PROJ-123" />
          </label>

          <label class="toolbar-field">
            <span>分支覆盖</span>
            <input class="form-input" type="text" name="branch" value={@branch_override} placeholder="可选" />
          </label>

          <label class="toolbar-field">
            <span>事件条数</span>
            <input class="form-input" type="number" min="1" max="50" name="events" value={@events_limit} />
          </label>

          <label class="toolbar-field">
            <span>日志范围</span>
            <select class="form-input" name="include_logs">
              <option :for={{label, value} <- @log_options} value={value} selected={value == @include_logs}>
                <%= label %>
              </option>
            </select>
          </label>

          <label class="toolbar-field">
            <span>自动刷新</span>
            <select class="form-input" name="refresh_interval" phx-change="set_refresh_interval">
              <option :for={{label, value} <- @refresh_options} value={value} selected={refresh_selected?(value, @refresh_interval_ms)}>
                <%= label %>
              </option>
            </select>
          </label>

          <label class="checkbox-field">
            <input type="checkbox" name="doctor" value="true" checked={@include_doctor} />
            <span>包含 doctor</span>
          </label>

          <label class="checkbox-field">
            <input type="checkbox" name="workpad" value="true" checked={@include_workpad} />
            <span>包含 workpad</span>
          </label>

          <button type="submit" class="subtle-button subtle-button-primary">加载议题</button>
        </form>
      </section>

      <div class="console-grid">
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">最近运行</h2>
              <p class="section-copy">来自项目本地 `/runs` 的 bridge 运行态。</p>
            </div>
          </div>

          <%= if @runs == [] do %>
        <p class="empty-state">bridge 还没有返回最近运行数据。</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>议题</th>
                    <th>阶段</th>
                    <th>路由</th>
                    <th>更新时间</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={run <- @runs}>
                    <td>
                      <button
                        type="button"
                        class="issue-link issue-button"
                        phx-click="select_issue"
                        phx-value-issue={field(run, "issue")}
                      >
                        <%= field(run, "issue") %>
                      </button>
                    </td>
                    <td><span class={state_badge_class(field(run, "phase"))}><%= field(run, "phase") || "未提供" %></span></td>
                    <td><%= field(run, "route_hint") || "未提供" %></td>
                    <td class="mono"><%= field(run, "updated_at") || "未提供" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">运行详情</h2>
              <p class="section-copy">展示当前选中议题的 `/status` 聚合结果。</p>
            </div>
          </div>

          <%= if is_nil(@status) do %>
            <p class="empty-state">先加载一个议题，才能查看当前状态、检查结果和控制动作。</p>
          <% else %>
            <div class="detail-grid">
              <article class="metric-card">
                <p class="metric-label">议题</p>
                <p class="metric-value"><%= field(@status, "issue") %></p>
                <p class="metric-detail"><%= field(@status, "summary") || "未提供" %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label">阶段</p>
                <p class="metric-value"><%= field(@status, "phase") || "未提供" %></p>
                <p class="metric-detail">路由提示：<%= field(@status, "route_hint") || "未提供" %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label">分支 / 提交</p>
                <p class="metric-value mono"><%= field(@status, "branch") || "未提供" %></p>
                <p class="metric-detail mono"><%= field(@status, "commit") || "未提供" %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label">下一步</p>
                <p class="metric-value"><%= field(@status, "next") || "未提供" %></p>
                <p class="metric-detail">更新时间：<span class="mono"><%= field(@status, "updated_at") || "未提供" %></span></p>
              </article>
            </div>

            <div class="section-stack">
              <section>
                <h3 class="section-subtitle">检查项</h3>
                <div class="table-wrap">
                  <table class="data-table">
                    <thead>
                      <tr>
                        <th>检查项</th>
                        <th>状态</th>
                        <th>摘要</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={{name, payload} <- normalized_checks(field(@status, "checks"))}>
                        <td><%= name %></td>
                        <td><span class={state_badge_class(field(payload, "status"))}><%= field(payload, "status") || "未提供" %></span></td>
                        <td><%= field(payload, "summary") || "未提供" %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </section>

              <section>
                <h3 class="section-subtitle">最新事件</h3>
                <%= if normalized_events(field(@status, "latest_events")) == [] do %>
                  <p class="empty-state">当前没有返回事件。</p>
                <% else %>
                  <div class="table-wrap">
                    <table class="data-table">
                      <thead>
                        <tr>
                          <th>时间</th>
                          <th>类型</th>
                          <th>摘要</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={event <- normalized_events(field(@status, "latest_events"))}>
                          <td class="mono"><%= field(event, "ts") || "未提供" %></td>
                          <td><%= field(event, "type") || "未提供" %></td>
                          <td><%= field(event, "summary") || "未提供" %></td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </section>

              <section>
                <h3 class="section-subtitle">控制动作</h3>
                <div class="action-row">
                  <button id="pause-run" type="button" class="subtle-button" phx-click="pause">暂停</button>
                  <button id="resume-run" type="button" class="subtle-button" phx-click="resume">继续</button>
                </div>

                <form id="instruction-form" class="instruction-form" phx-submit="append_instruction">
                  <label class="toolbar-field toolbar-field-full">
                    <span>补充指令</span>
                    <textarea
                      class="form-input form-textarea"
                      name="message"
                      placeholder="为当前运行补充新的执行指令"
                    ><%= @instruction_message %></textarea>
                  </label>

                  <label class="checkbox-field">
                    <input type="checkbox" name="sync_linear" value="true" checked={@sync_linear} />
                    <span>同步到 Linear</span>
                  </label>

                  <button type="submit" class="subtle-button subtle-button-primary">追加指令</button>
                </form>
              </section>

              <section :if={present?(field(@status, "doctor"))}>
                <h3 class="section-subtitle">Doctor 检查</h3>
                <pre class="code-panel"><%= inspect(field(@status, "doctor"), pretty: true, limit: :infinity) %></pre>
              </section>

              <section :if={present?(field(@status, "workpad"))}>
                <h3 class="section-subtitle">Workpad 工作面板</h3>
                <pre class="code-panel"><%= inspect(field(@status, "workpad"), pretty: true, limit: :infinity) %></pre>
              </section>

              <section :if={present?(field(@status, "logs"))}>
                <h3 class="section-subtitle">日志</h3>
                <pre class="code-panel"><%= inspect(field(@status, "logs"), pretty: true, limit: :infinity) %></pre>
              </section>
            </div>
          <% end %>
        </section>
      </div>
    </section>
    """
  end

  defp refresh_console(socket, opts) do
    socket =
      case client_module().meta() do
        {:ok, meta} ->
          events_limit = socket.assigns.events_limit || field(meta, "default_event_limit") || 10
          assign(socket, :meta, meta) |> assign(:events_limit, events_limit) |> assign(:error_message, nil)

        {:error, reason} ->
          assign(socket, :error_message, error_message(reason))
      end

    socket =
      case client_module().list_runs(12) do
        {:ok, runs} -> assign(socket, :runs, runs)
        {:error, reason} -> assign(socket, :error_message, error_message(reason))
      end

    if opts[:load_status?] && socket.assigns.selected_issue do
      load_status(socket)
    else
      socket
    end
  end

  defp load_status(socket) do
    opts = %{
      branch: blank_to_nil(socket.assigns.branch_override),
      events: socket.assigns.events_limit,
      includeLogs: socket.assigns.include_logs,
      doctor: socket.assigns.include_doctor,
      workpad: socket.assigns.include_workpad
    }

    case client_module().get_status(socket.assigns.selected_issue, opts) do
      {:ok, status} ->
        socket
        |> assign(:status, status)
        |> assign(:error_message, nil)

      {:error, reason} ->
        socket
        |> assign(:status, nil)
        |> assign(:error_message, error_message(reason))
    end
  end

  defp perform_action(%{assigns: %{selected_issue: nil}} = socket, _params) do
    put_flash(socket, :error, "触发控制动作前，必须先加载一个议题")
  end

  defp perform_action(socket, params) do
    payload =
      %{
        issue: socket.assigns.selected_issue,
        action: params["action"],
        branch: blank_to_nil(socket.assigns.branch_override),
        message: blank_to_nil(params["message"]),
        syncLinear: params["sync_linear"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case client_module().create_action(payload) do
      {:ok, response} ->
        socket
        |> assign(:status, field(response, "status") || socket.assigns.status)
        |> put_flash(:info, action_success_message(params["action"]))
        |> refresh_console(load_status?: true)

      {:error, reason} ->
        put_flash(socket, :error, error_message(reason))
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :console_client_module, SymphonyElixir.ConsoleClient)
  end

  defp adapter_label(nil), do: "项目"
  defp adapter_label(meta), do: field(meta, "repo_name") || field(meta, "repo_key") || "项目"

  defp refresh_selected?(value, refresh_interval_ms) do
    selected =
      if refresh_interval_ms > 0 do
        Integer.to_string(refresh_interval_ms)
      else
        "off"
      end

    value == selected
  end

  defp action_success_message("pause"), do: "已记录暂停请求"
  defp action_success_message("resume"), do: "已记录继续请求"
  defp action_success_message("instruction"), do: "已追加指令"
  defp action_success_message(_action), do: "已记录动作"

  defp normalized_checks(nil), do: []
  defp normalized_checks(checks) when is_map(checks), do: Enum.sort_by(checks, fn {key, _value} -> to_string(key) end)
  defp normalized_checks(_checks), do: []

  defp normalized_events(nil), do: []
  defp normalized_events(events) when is_list(events), do: events
  defp normalized_events(_events), do: []

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp field(_map, _key), do: nil

  defp error_message(:not_configured),
    do: "使用控制台前，请先配置 SYMPHONY_CONSOLE_ADAPTER_BASE_URL 和 SYMPHONY_CONSOLE_ADAPTER_TOKEN。"

  defp error_message({:http_error, status, body}),
    do: "Bridge 请求失败，HTTP #{status}: #{inspect(body)}"

  defp error_message(reason), do: "Bridge 请求失败: #{inspect(reason)}"

  defp state_badge_class(value) when value in [nil, ""], do: "state-badge"

  defp state_badge_class(value) do
    normalized = String.downcase(to_string(value))

    cond do
      normalized in ["passed", "success", "done", "merging", "handoff"] -> "state-badge state-badge-active"
      normalized in ["failed", "error", "rework", "blocked"] -> "state-badge state-badge-danger"
      true -> "state-badge state-badge-warning"
    end
  end

  defp truthy?(value), do: value in [true, "true", "on", "1"]

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp parse_integer(nil, fallback), do: fallback

  defp parse_integer(value, fallback) do
    case Integer.parse(to_string(value)) do
      {parsed, _} when parsed in 1..50 -> parsed
      _ -> fallback
    end
  end

  defp present?(value), do: not is_nil(value) and value != "" and value != []

  defp schedule_refresh(0), do: :ok
  defp schedule_refresh(interval_ms), do: Process.send_after(self(), :refresh_tick, interval_ms)
end
