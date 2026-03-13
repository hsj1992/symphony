defmodule SymphonyElixirWeb.ConsoleLive do
  @moduledoc """
  Standalone bridge-backed console for project-local Symphony integrations.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  @default_lang "zh"
  @default_refresh_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    lang = @default_lang

    socket =
      socket
      |> assign(:lang, lang)
      |> assign(:meta, nil)
      |> assign(:runs, [])
      |> assign(:status, nil)
      |> assign(:selected_issue, nil)
      |> assign(:error_message, nil)
      |> assign(:log_options, log_options(lang))
      |> assign(:refresh_options, refresh_options(lang))
      |> assign(:issue_query, "")
      |> assign(:branch_override, "")
      |> assign(:events_limit, 10)
      |> assign(:include_logs, "none")
      |> assign(:include_doctor, true)
      |> assign(:include_workpad, true)
      |> assign(:instruction_message, "")
      |> assign(:sync_linear, true)
      |> assign(:refresh_interval_ms, @default_refresh_ms)
      |> assign(:detail_panel, "workpad")
      |> assign(:active_log_stream, nil)

    socket = refresh_console(socket, load_status?: false)

    if connected?(socket) do
      schedule_refresh(socket.assigns.refresh_interval_ms)
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    lang = normalize_lang(params["lang"])

    {:noreply,
     socket
     |> assign(:lang, lang)
     |> assign(:log_options, log_options(lang))
     |> assign(:refresh_options, refresh_options(lang))}
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
  def handle_event("set_lang", %{"lang" => lang}, socket) do
    {:noreply, push_patch(socket, to: console_path(normalize_lang(lang)))}
  end

  @impl true
  def handle_event("set_detail_panel", %{"panel" => panel}, socket) do
    {:noreply, assign(socket, :detail_panel, normalize_detail_panel(panel))}
  end

  @impl true
  def handle_event("set_log_stream", %{"stream" => stream}, socket) do
    {:noreply, assign(socket, :active_log_stream, stream)}
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
        {:noreply, put_flash(socket, :error, tr(socket.assigns.lang, "Issue key is required", "必须先输入议题编号"))}

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
      {:noreply, put_flash(socket, :error, tr(socket.assigns.lang, "Instruction cannot be empty", "补充指令不能为空"))}
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
            <p class="eyebrow"><%= tr(@lang, "Symphony Workflow", "Symphony 工作流") %></p>
            <h1 class="hero-title"><%= tr(@lang, "Bridge Console", "工作流控制台") %></h1>
            <p class="hero-copy">
              <%= tr(@lang, "This is the standalone Symphony workflow console. Recent runs, issue detail, and control actions all flow through the bridge API instead of being embedded into the product application.", "这是独立于业务前后端的 Symphony 工作流控制台。最近运行、议题详情和控制动作都通过 bridge API 完成，而不是嵌入到产品系统里。") %>
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              <%= adapter_label(@meta) %>
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              <%= refresh_badge_label(@lang, @refresh_interval_ms) %>
            </span>
            <div class="locale-switch">
              <button id="lang-zh" type="button" class={locale_button_class(@lang, "zh")} phx-click="set_lang" phx-value-lang="zh">中文</button>
              <button id="lang-en" type="button" class={locale_button_class(@lang, "en")} phx-click="set_lang" phx-value-lang="en">EN</button>
            </div>
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
          <h2 class="error-title"><%= tr(@lang, "Bridge unavailable", "Bridge 服务不可用") %></h2>
          <p class="error-copy"><%= @error_message %></p>
        </section>
      <% end %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title"><%= tr(@lang, "Controls", "控制面板") %></h2>
            <p class="section-copy"><%= tr(@lang, "Load an issue from the bridge, tune refresh, and include doctor/workpad/log data on demand.", "从 bridge 加载议题，按需查看 doctor、workpad、日志，并调整刷新策略。") %></p>
          </div>
          <button type="button" class="subtle-button" phx-click="refresh"><%= tr(@lang, "Refresh now", "立即刷新") %></button>
        </div>

        <form id="issue-query-form" class="toolbar-form" phx-submit="load_issue">
          <label class="toolbar-field">
            <span><%= tr(@lang, "Issue key", "议题编号") %></span>
            <input class="form-input" type="text" name="issue" value={@issue_query} placeholder={tr(@lang, "For example PROJ-123", "例如 PROJ-123")} />
          </label>

          <label class="toolbar-field">
            <span><%= tr(@lang, "Branch override", "分支覆盖") %></span>
            <input class="form-input" type="text" name="branch" value={@branch_override} placeholder={tr(@lang, "Optional", "可选")} />
          </label>

          <label class="toolbar-field">
            <span><%= tr(@lang, "Events", "事件条数") %></span>
            <input class="form-input" type="number" min="1" max="50" name="events" value={@events_limit} />
          </label>

          <label class="toolbar-field">
            <span><%= tr(@lang, "Logs", "日志范围") %></span>
            <select class="form-input" name="include_logs">
              <option :for={{label, value} <- @log_options} value={value} selected={value == @include_logs}>
                <%= label %>
              </option>
            </select>
          </label>

          <label class="toolbar-field">
            <span><%= tr(@lang, "Auto refresh", "自动刷新") %></span>
            <select class="form-input" name="refresh_interval" phx-change="set_refresh_interval">
              <option :for={{label, value} <- @refresh_options} value={value} selected={refresh_selected?(value, @refresh_interval_ms)}>
                <%= label %>
              </option>
            </select>
          </label>

          <label class="checkbox-field">
            <input type="checkbox" name="doctor" value="true" checked={@include_doctor} />
            <span><%= tr(@lang, "Include doctor", "包含 doctor") %></span>
          </label>

          <label class="checkbox-field">
            <input type="checkbox" name="workpad" value="true" checked={@include_workpad} />
            <span><%= tr(@lang, "Include workpad", "包含 workpad") %></span>
          </label>

          <button type="submit" class="subtle-button subtle-button-primary"><%= tr(@lang, "Load issue", "加载议题") %></button>
        </form>
      </section>

      <div class="console-grid">
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= tr(@lang, "Recent runs", "最近运行") %></h2>
              <p class="section-copy"><%= tr(@lang, "Project-local bridge state from `/runs`.", "来自项目本地 `/runs` 的 bridge 运行态。") %></p>
            </div>
          </div>

          <%= if @runs == [] do %>
        <p class="empty-state"><%= tr(@lang, "The bridge has not returned any recent runs yet.", "bridge 还没有返回最近运行数据。") %></p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th><%= tr(@lang, "Issue", "议题") %></th>
                    <th><%= tr(@lang, "Phase", "阶段") %></th>
                    <th><%= tr(@lang, "Route", "路由") %></th>
                    <th><%= tr(@lang, "Updated", "更新时间") %></th>
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
                    <td><span class={state_badge_class(field(run, "phase"))}><%= field(run, "phase") || tr(@lang, "n/a", "未提供") %></span></td>
                    <td><%= field(run, "route_hint") || tr(@lang, "n/a", "未提供") %></td>
                    <td class="mono"><%= field(run, "updated_at") || tr(@lang, "n/a", "未提供") %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title"><%= tr(@lang, "Run detail", "运行详情") %></h2>
              <p class="section-copy"><%= tr(@lang, "Loaded from `/status` for the selected issue.", "展示当前选中议题的 `/status` 聚合结果。") %></p>
            </div>
          </div>

          <%= if is_nil(@status) do %>
            <p class="empty-state"><%= tr(@lang, "Load an issue to inspect current status, checks, and actions.", "先加载一个议题，才能查看当前状态、检查结果和控制动作。") %></p>
          <% else %>
            <div class="detail-grid">
              <article class="metric-card">
                <p class="metric-label"><%= tr(@lang, "Issue", "议题") %></p>
                <p class="metric-value"><%= field(@status, "issue") %></p>
                <p class="metric-detail"><%= field(@status, "summary") || tr(@lang, "n/a", "未提供") %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label"><%= tr(@lang, "Phase", "阶段") %></p>
                <p class="metric-value"><%= field(@status, "phase") || tr(@lang, "n/a", "未提供") %></p>
                <p class="metric-detail"><%= tr(@lang, "Route hint", "路由提示") %>：<%= field(@status, "route_hint") || tr(@lang, "n/a", "未提供") %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label"><%= tr(@lang, "Branch / commit", "分支 / 提交") %></p>
                <p class="metric-value mono"><%= field(@status, "branch") || tr(@lang, "n/a", "未提供") %></p>
                <p class="metric-detail mono"><%= field(@status, "commit") || tr(@lang, "n/a", "未提供") %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label"><%= tr(@lang, "Next", "下一步") %></p>
                <p class="metric-value"><%= field(@status, "next") || tr(@lang, "n/a", "未提供") %></p>
                <p class="metric-detail"><%= tr(@lang, "Updated", "更新时间") %>：<span class="mono"><%= field(@status, "updated_at") || tr(@lang, "n/a", "未提供") %></span></p>
              </article>
            </div>

            <div class="section-stack">
              <section>
                <h3 class="section-subtitle"><%= tr(@lang, "Checks", "检查项") %></h3>
                <div class="table-wrap">
                  <table class="data-table">
                    <thead>
                      <tr>
                        <th><%= tr(@lang, "Check", "检查项") %></th>
                        <th><%= tr(@lang, "Status", "状态") %></th>
                        <th><%= tr(@lang, "Summary", "摘要") %></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={{name, payload} <- normalized_checks(field(@status, "checks"))}>
                        <td><%= name %></td>
                        <td><span class={state_badge_class(field(payload, "status"))}><%= field(payload, "status") || tr(@lang, "n/a", "未提供") %></span></td>
                        <td><%= field(payload, "summary") || tr(@lang, "n/a", "未提供") %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </section>

              <section>
                <h3 class="section-subtitle"><%= tr(@lang, "Timeline", "事件时间线") %></h3>
                <%= if normalized_events(field(@status, "latest_events")) == [] do %>
                  <p class="empty-state"><%= tr(@lang, "No events returned.", "当前没有返回事件。") %></p>
                <% else %>
                  <div class="timeline-list">
                    <article :for={event <- normalized_events(field(@status, "latest_events"))} class="timeline-item">
                      <div class="timeline-head">
                        <span class={state_badge_class(field(event, "type"))}><%= humanize_token(field(event, "type"), @lang) || tr(@lang, "n/a", "未提供") %></span>
                        <span class="timeline-time mono"><%= field(event, "ts") || tr(@lang, "n/a", "未提供") %></span>
                      </div>
                      <p class="timeline-summary"><%= field(event, "summary") || tr(@lang, "n/a", "未提供") %></p>
                      <p :if={present?(field(event, "actor"))} class="timeline-meta">
                        <%= tr(@lang, "Actor", "执行方") %>：<span class="mono"><%= field(event, "actor") %></span>
                      </p>
                    </article>
                  </div>
                <% end %>
              </section>

              <section>
                <h3 class="section-subtitle"><%= tr(@lang, "Actions", "控制动作") %></h3>
                <div class="action-row">
                  <button id="pause-run" type="button" class="subtle-button" phx-click="pause"><%= tr(@lang, "Pause", "暂停") %></button>
                  <button id="resume-run" type="button" class="subtle-button" phx-click="resume"><%= tr(@lang, "Continue", "继续") %></button>
                </div>

                <form id="instruction-form" class="instruction-form" phx-submit="append_instruction">
                  <label class="toolbar-field toolbar-field-full">
                    <span><%= tr(@lang, "Append instruction", "补充指令") %></span>
                    <textarea
                      class="form-input form-textarea"
                      name="message"
                      placeholder={tr(@lang, "Add a new instruction for this run", "为当前运行补充新的执行指令")}
                    ><%= @instruction_message %></textarea>
                  </label>

                  <label class="checkbox-field">
                    <input type="checkbox" name="sync_linear" value="true" checked={@sync_linear} />
                    <span><%= tr(@lang, "Sync to Linear", "同步到 Linear") %></span>
                  </label>

                  <button type="submit" class="subtle-button subtle-button-primary"><%= tr(@lang, "Append instruction", "追加指令") %></button>
                </form>
              </section>

              <section>
                <div class="section-header section-header-tight">
                  <div>
                    <h3 class="section-subtitle"><%= tr(@lang, "Inspector", "数据面板") %></h3>
                    <p class="section-copy"><%= tr(@lang, "Switch between workpad context, doctor output, and split log streams.", "在 workpad、doctor 输出和拆分日志流之间切换。") %></p>
                  </div>
                </div>

                <div class="panel-tab-row">
                  <button type="button" class={panel_button_class(@detail_panel, "workpad")} phx-click="set_detail_panel" phx-value-panel="workpad"><%= tr(@lang, "Workpad", "Workpad") %></button>
                  <button type="button" class={panel_button_class(@detail_panel, "doctor")} phx-click="set_detail_panel" phx-value-panel="doctor"><%= tr(@lang, "Doctor", "Doctor") %></button>
                  <button type="button" class={panel_button_class(@detail_panel, "logs")} phx-click="set_detail_panel" phx-value-panel="logs"><%= tr(@lang, "Logs", "日志流") %></button>
                </div>

                <div :if={@detail_panel == "workpad"} class="inspector-stack">
                  <%= if workpad_sections(field(@status, "workpad")) == [] do %>
                    <p class="empty-state"><%= tr(@lang, "No workpad data returned.", "当前没有返回 workpad 数据。") %></p>
                  <% else %>
                    <article :for={section <- workpad_sections(field(@status, "workpad"))} class="inspector-card">
                      <div class="inspector-card-head">
                        <h4><%= workpad_section_label(section.id, @lang) %></h4>
                      </div>
                      <pre class="code-panel"><%= section.content %></pre>
                    </article>
                  <% end %>
                </div>

                <div :if={@detail_panel == "doctor"} class="inspector-stack">
                  <%= if doctor_rows(field(@status, "doctor")) == [] do %>
                    <p class="empty-state"><%= tr(@lang, "No doctor output returned.", "当前没有返回 doctor 输出。") %></p>
                  <% else %>
                    <article class="inspector-card">
                      <div class="table-wrap">
                        <table class="data-table">
                          <thead>
                            <tr>
                              <th><%= tr(@lang, "Field", "字段") %></th>
                              <th><%= tr(@lang, "Value", "值") %></th>
                            </tr>
                          </thead>
                          <tbody>
                            <tr :for={{label, value} <- doctor_rows(field(@status, "doctor"))}>
                              <td><%= label %></td>
                              <td><%= value %></td>
                            </tr>
                          </tbody>
                        </table>
                      </div>
                    </article>
                  <% end %>
                </div>

                <div :if={@detail_panel == "logs"} class="inspector-stack">
                  <%= if log_streams(field(@status, "logs")) == [] do %>
                    <p class="empty-state"><%= tr(@lang, "No logs returned. Reload the issue with agent or raw logs enabled.", "当前没有返回日志。请重新加载议题并启用执行日志或原始日志。") %></p>
                  <% else %>
                    <div class="panel-tab-row">
                      <button
                        :for={stream <- log_streams(field(@status, "logs"))}
                        type="button"
                        class={panel_button_class(active_log_stream(@status, @active_log_stream), stream.id)}
                        phx-click="set_log_stream"
                        phx-value-stream={stream.id}
                      ><%= stream.label %></button>
                    </div>
                    <article :if={selected_stream = selected_log_stream(field(@status, "logs"), @active_log_stream)} class="inspector-card">
                      <div class="inspector-card-head">
                        <h4><%= selected_stream.label %></h4>
                      </div>
                      <pre class="code-panel"><%= selected_stream.content %></pre>
                    </article>
                  <% end %>
                </div>
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
          assign(socket, :error_message, error_message(socket.assigns.lang, reason))
      end

    socket =
      case client_module().list_runs(12) do
        {:ok, runs} -> assign(socket, :runs, runs)
        {:error, reason} -> assign(socket, :error_message, error_message(socket.assigns.lang, reason))
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
        |> assign(:active_log_stream, default_log_stream_id(field(status, "logs")))
        |> assign(:error_message, nil)

      {:error, reason} ->
        socket
        |> assign(:status, nil)
        |> assign(:error_message, error_message(socket.assigns.lang, reason))
    end
  end

  defp perform_action(%{assigns: %{selected_issue: nil, lang: lang}} = socket, _params) do
    put_flash(socket, :error, tr(lang, "Load an issue before triggering actions", "触发控制动作前，必须先加载一个议题"))
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
        |> put_flash(:info, action_success_message(socket.assigns.lang, params["action"]))
        |> refresh_console(load_status?: true)

      {:error, reason} ->
        put_flash(socket, :error, error_message(socket.assigns.lang, reason))
    end
  end

  defp client_module do
    Application.get_env(:symphony_elixir, :console_client_module, SymphonyElixir.ConsoleClient)
  end

  defp adapter_label(nil), do: "Project"
  defp adapter_label(meta), do: field(meta, "repo_name") || field(meta, "repo_key") || "Project"

  defp refresh_selected?(value, refresh_interval_ms) do
    selected =
      if refresh_interval_ms > 0 do
        Integer.to_string(refresh_interval_ms)
      else
        "off"
      end

    value == selected
  end

  defp action_success_message(lang, "pause"), do: tr(lang, "Pause recorded", "已记录暂停请求")
  defp action_success_message(lang, "resume"), do: tr(lang, "Continue recorded", "已记录继续请求")
  defp action_success_message(lang, "instruction"), do: tr(lang, "Instruction appended", "已追加指令")
  defp action_success_message(lang, _action), do: tr(lang, "Action recorded", "已记录动作")

  defp normalized_checks(nil), do: []
  defp normalized_checks(checks) when is_map(checks), do: Enum.sort_by(checks, fn {key, _value} -> to_string(key) end)
  defp normalized_checks(_checks), do: []

  defp normalized_events(nil), do: []
  defp normalized_events(events) when is_list(events), do: events
  defp normalized_events(_events), do: []

  defp workpad_sections(nil), do: []

  defp workpad_sections(workpad) when is_map(workpad) do
    ["current_status", "execution_timeline", "validation", "feedback_sweep"]
    |> Enum.map(fn key -> %{id: key, content: blank_to_nil(field(workpad, key))} end)
    |> Enum.reject(&is_nil(&1.content))
  end

  defp workpad_sections(_workpad), do: []

  defp doctor_rows(nil), do: []

  defp doctor_rows(doctor) when is_map(doctor) do
    doctor
    |> Enum.map(fn {key, value} -> {humanize_token(key, "en"), doctor_value(value)} end)
    |> Enum.sort_by(fn {label, _value} -> label end)
  end

  defp doctor_rows(_doctor), do: []

  defp doctor_value(value) when is_binary(value), do: value
  defp doctor_value(value) when is_boolean(value), do: to_string(value)
  defp doctor_value(value) when is_number(value), do: to_string(value)
  defp doctor_value(value), do: inspect(value, pretty: true, limit: :infinity)

  defp log_streams(nil), do: []

  defp log_streams(logs) when is_map(logs) do
    top_level =
      case blank_to_nil(field(logs, "agent")) do
        nil -> []
        content -> [%{id: "agent", label: "Agent", content: content}]
      end

    raw_streams =
      case field(logs, "raw") do
        raw when is_map(raw) ->
          raw
          |> Enum.map(fn {key, value} -> %{id: "raw:" <> to_string(key), label: to_string(key), content: to_string(value)} end)
          |> Enum.sort_by(& &1.label)

        _ ->
          []
      end

    top_level ++ raw_streams
  end

  defp log_streams(_logs), do: []

  defp default_log_stream_id(logs) do
    case log_streams(logs) do
      [first | _rest] -> first.id
      [] -> nil
    end
  end

  defp active_log_stream(status, active_stream) do
    active_stream || default_log_stream_id(field(status, "logs"))
  end

  defp selected_log_stream(logs, active_stream) do
    stream_id = active_stream || default_log_stream_id(logs)
    Enum.find(log_streams(logs), &(&1.id == stream_id))
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_atom(key))
  end

  defp field(_map, _key), do: nil

  defp error_message(lang, :not_configured),
    do:
      tr(
        lang,
        "Set SYMPHONY_CONSOLE_ADAPTER_BASE_URL and SYMPHONY_CONSOLE_ADAPTER_TOKEN before using the bridge console.",
        "使用控制台前，请先配置 SYMPHONY_CONSOLE_ADAPTER_BASE_URL 和 SYMPHONY_CONSOLE_ADAPTER_TOKEN。"
      )

  defp error_message(lang, {:http_error, status, body}),
    do: tr(lang, "Bridge request failed with HTTP #{status}: #{inspect(body)}", "Bridge 请求失败，HTTP #{status}: #{inspect(body)}")

  defp error_message(lang, reason), do: tr(lang, "Bridge request failed: #{inspect(reason)}", "Bridge 请求失败: #{inspect(reason)}")

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

  defp normalize_lang("en"), do: "en"
  defp normalize_lang("zh"), do: "zh"
  defp normalize_lang(_lang), do: @default_lang

  defp console_path("en"), do: "/console?lang=en"
  defp console_path(_lang), do: "/console?lang=zh"

  defp refresh_options("en"), do: [{"Off", "off"}, {"15s", "15000"}, {"30s", "30000"}, {"60s", "60000"}]
  defp refresh_options(_lang), do: [{"关闭", "off"}, {"15s", "15000"}, {"30s", "30000"}, {"60s", "60000"}]

  defp log_options("en"), do: [{"No logs", "none"}, {"Agent logs", "agent"}, {"Raw logs", "raw"}, {"All logs", "all"}]
  defp log_options(_lang), do: [{"不包含日志", "none"}, {"执行日志", "agent"}, {"原始日志", "raw"}, {"全部日志", "all"}]

  defp refresh_badge_label("en", refresh_interval_ms) when refresh_interval_ms > 0, do: "Auto #{div(refresh_interval_ms, 1000)}s"
  defp refresh_badge_label("en", _refresh_interval_ms), do: "Manual refresh"
  defp refresh_badge_label(_lang, refresh_interval_ms) when refresh_interval_ms > 0, do: "自动 #{div(refresh_interval_ms, 1000)}s"
  defp refresh_badge_label(_lang, _refresh_interval_ms), do: "手动刷新"

  defp normalize_detail_panel("doctor"), do: "doctor"
  defp normalize_detail_panel("logs"), do: "logs"
  defp normalize_detail_panel(_panel), do: "workpad"

  defp panel_button_class(active_panel, panel) when active_panel == panel,
    do: "subtle-button subtle-button-primary"

  defp panel_button_class(_active_panel, _panel), do: "subtle-button"

  defp workpad_section_label("current_status", "en"), do: "Current status"
  defp workpad_section_label("execution_timeline", "en"), do: "Execution timeline"
  defp workpad_section_label("validation", "en"), do: "Validation"
  defp workpad_section_label("feedback_sweep", "en"), do: "Feedback sweep"
  defp workpad_section_label("current_status", _lang), do: "当前状态"
  defp workpad_section_label("execution_timeline", _lang), do: "执行时间线"
  defp workpad_section_label("validation", _lang), do: "验证"
  defp workpad_section_label("feedback_sweep", _lang), do: "反馈清扫"
  defp workpad_section_label(section, _lang), do: humanize_token(section, "en")

  defp humanize_token(nil, _lang), do: nil

  defp humanize_token(value, lang) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> then(fn token ->
      if lang == "en" do
        Phoenix.Naming.humanize(token)
      else
        Phoenix.Naming.humanize(token)
      end
    end)
  end

  defp locale_button_class(active_lang, button_lang) when active_lang == button_lang,
    do: "subtle-button subtle-button-primary"

  defp locale_button_class(_active_lang, _button_lang), do: "subtle-button"

  defp tr("en", en, _zh), do: en
  defp tr(_lang, _en, zh), do: zh
end
