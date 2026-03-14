defmodule SymphonyElixirWeb.ConsoleLive do
  @moduledoc """
  Standalone bridge-backed console for project-local Symphony integrations.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}
  alias SymphonyElixirWeb.{Endpoint, ObservabilityPubSub, Presenter}

  @default_lang "zh"
  @default_refresh_ms 15_000
  @runtime_tick_ms 1_000

  @impl true
  def mount(_params, _session, socket) do
    lang = @default_lang
    adapters = adapter_options()
    selected_adapter = default_adapter_id(adapters)

    socket =
      socket
      |> assign(:lang, lang)
      |> assign(:adapters, adapters)
      |> assign(:selected_adapter, selected_adapter)
      |> assign(:profiles, [])
      |> assign(:selected_profile, nil)
      |> assign(:profile_defaults_for, nil)
      |> assign(:meta, nil)
      |> assign(:runs, [])
      |> assign(:status, nil)
      |> assign(:runtime_payload, load_runtime_payload())
      |> assign(:now, DateTime.utc_now())
      |> assign(:selected_issue, nil)
      |> assign(:error_message, nil)
      |> assign(:action_feedback, nil)
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
      :ok = ObservabilityPubSub.subscribe()
      schedule_refresh(socket.assigns.refresh_interval_ms)
      schedule_runtime_tick()
    end

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    lang = normalize_lang(params["lang"])
    adapters = adapter_options()
    selected_adapter = selected_adapter_id(adapters, params["adapter"])
    selected_profile = blank_to_nil(params["profile"])

    {:noreply,
     socket
     |> assign(:lang, lang)
     |> assign(:adapters, adapters)
     |> assign(:selected_adapter, selected_adapter)
     |> assign(:selected_profile, selected_profile)
     |> assign(:log_options, log_options(lang))
     |> assign(:refresh_options, refresh_options(lang))
     |> refresh_console(load_status?: not is_nil(socket.assigns.selected_issue))}
  end

  @impl true
  def handle_info(:refresh_tick, socket) do
    schedule_refresh(socket.assigns.refresh_interval_ms)
    {:noreply, refresh_console(socket, load_status?: not is_nil(socket.assigns.selected_issue))}
  end

  @impl true
  def handle_info(:runtime_tick, socket) do
    schedule_runtime_tick()
    {:noreply, assign(socket, :now, DateTime.utc_now())}
  end

  @impl true
  def handle_info(:observability_updated, socket) do
    {:noreply,
     socket
     |> assign(:runtime_payload, load_runtime_payload())
     |> assign(:now, DateTime.utc_now())}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, refresh_console(socket, load_status?: not is_nil(socket.assigns.selected_issue))}
  end

  @impl true
  def handle_event("set_lang", %{"lang" => lang}, socket) do
    {:noreply,
     push_patch(
       socket,
       to: console_path(normalize_lang(lang), socket.assigns.selected_adapter, socket.assigns.selected_profile)
     )}
  end

  @impl true
  def handle_event("set_adapter", %{"adapter" => adapter_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_adapter, selected_adapter_id(socket.assigns.adapters, adapter_id))
     |> assign(:selected_profile, nil)
     |> assign(:profile_defaults_for, nil)
     |> assign(:profiles, [])
     |> assign(:selected_issue, nil)
     |> assign(:issue_query, "")
     |> assign(:branch_override, "")
     |> assign(:status, nil)
     |> assign(:instruction_message, "")
     |> assign(:active_log_stream, nil)
     |> push_patch(to: console_path(socket.assigns.lang, adapter_id, nil))}
  end

  @impl true
  def handle_event("set_profile", %{"profile" => profile_id}, socket) do
    {:noreply,
     socket
     |> assign(:selected_profile, blank_to_nil(profile_id))
     |> assign(:profile_defaults_for, nil)
     |> push_patch(to: console_path(socket.assigns.lang, socket.assigns.selected_adapter, blank_to_nil(profile_id)))}
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
  def handle_event("cancel", _params, socket) do
    {:noreply, perform_action(socket, %{"action" => "cancel"})}
  end

  @impl true
  def handle_event("restart", _params, socket) do
    {:noreply, perform_action(socket, %{"action" => "restart"})}
  end

  @impl true
  def handle_event("clear_instruction", _params, socket) do
    {:noreply, perform_action(socket, %{"action" => "clear_instruction"})}
  end

  @impl true
  def handle_event("hold", _params, socket) do
    {:noreply, perform_action(socket, %{"action" => "hold"})}
  end

  @impl true
  def handle_event("release", _params, socket) do
    {:noreply, perform_action(socket, %{"action" => "release"})}
  end

  @impl true
  def handle_event("append_instruction", %{"message" => message, "sync_linear" => sync_linear}, socket) do
    handle_event("instruction_action", %{"message" => message, "sync_linear" => sync_linear, "intent" => "append"}, socket)
  end

  @impl true
  def handle_event("instruction_action", %{"message" => message, "sync_linear" => sync_linear} = params, socket) do
    socket =
      socket
      |> assign(:instruction_message, message || "")
      |> assign(:sync_linear, truthy?(sync_linear))

    if String.trim(socket.assigns.instruction_message) == "" do
      {:noreply, put_flash(socket, :error, tr(socket.assigns.lang, "Instruction cannot be empty", "补充指令不能为空"))}
    else
      intent =
        case params["intent"] do
          "steer" -> "steer"
          _ -> "instruction"
        end

      {:noreply,
       socket
       |> perform_action(%{
         "action" => intent,
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
            <h1 class="hero-title"><%= tr(@lang, "Operator Cockpit", "运行控制台") %></h1>
            <p class="hero-copy">
              <%= tr(@lang, "Runtime observability, bridge-backed issue control, and delivery state now live on one operator page.", "运行态观测、bridge 驱动的议题控制、以及交付状态现在收敛在同一个操作台页面。") %>
            </p>
            <div class="hero-pulse-row">
              <span class="pulse-chip pulse-chip-live"><span class="pulse-dot"></span><%= heartbeat_label(@now, @lang) %></span>
              <span class="pulse-chip"><%= tr(@lang, "Runtime activity", "运行活跃度") %> <strong><%= runtime_activity_percent(@runtime_payload) %>%</strong></span>
            </div>
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
              <select
                :if={length(@adapters) > 1}
                id="adapter-select"
                class="form-input form-input-compact"
                phx-change="set_adapter"
                name="adapter"
              >
                <option :for={adapter <- @adapters} value={adapter.id} selected={adapter.id == @selected_adapter}>
                  <%= adapter.label %>
                </option>
              </select>
              <select
                :if={@profiles != []}
                id="profile-select"
                class="form-input form-input-compact"
                phx-change="set_profile"
                name="profile"
              >
                <option :for={profile <- @profiles} value={profile_id(profile)} selected={profile_id(profile) == @selected_profile}>
                  <%= profile_label(profile, @lang) %>
                </option>
              </select>
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

      <section class="cockpit-ribbon">
        <article class="ribbon-card ribbon-card-runtime">
          <p class="metric-label"><%= tr(@lang, "Runtime pulse", "运行脉搏") %></p>
          <h3 class="ribbon-title"><%= heartbeat_label(@now, @lang) %></h3>
          <p class="ribbon-copy"><%= heartbeat_copy(@runtime_payload, @lang) %></p>
          <div class="activity-meter">
            <span style={meter_width_style(runtime_activity_percent(@runtime_payload))}></span>
          </div>
        </article>

        <article class="ribbon-card">
          <p class="metric-label"><%= tr(@lang, "Issue spotlight", "当前任务焦点") %></p>
          <h3 class="ribbon-title mono"><%= spotlight_title(@status, @lang) %></h3>
          <p class="ribbon-copy"><%= spotlight_summary(@status, @lang) %></p>
        </article>

        <article class="ribbon-card">
          <p class="metric-label"><%= tr(@lang, "Operator feedback", "操作反馈") %></p>
          <h3 class="ribbon-title"><%= operator_feedback_title(@action_feedback, @lang) %></h3>
          <p class="ribbon-copy"><%= operator_feedback_copy(@action_feedback, @status, @lang) %></p>
        </article>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title"><%= tr(@lang, "Runtime Overview", "运行态总览") %></h2>
            <p class="section-copy"><%= tr(@lang, "Live runtime state from the current Symphony process, refreshed via pubsub and timer ticks.", "当前 Symphony 进程的实时运行态，通过 pubsub 与定时器持续刷新。") %></p>
          </div>
        </div>

        <%= if runtime_error = field(@runtime_payload, "error") do %>
          <p class="empty-state"><%= runtime_error_message(runtime_error, @lang) %></p>
        <% else %>
          <section class="metric-grid">
            <article class="metric-card">
              <p class="metric-label"><%= tr(@lang, "Running", "运行中") %></p>
              <p class="metric-value numeric"><%= field(field(@runtime_payload, "counts"), "running") || 0 %></p>
              <p class="metric-detail"><%= tr(@lang, "Active issue sessions in the current runtime.", "当前 runtime 中的活跃议题会话数。") %></p>
              <div class="activity-meter"><span style={meter_width_style(min((field(field(@runtime_payload, "counts"), "running") || 0) * 50, 100))}></span></div>
            </article>

            <article class="metric-card">
              <p class="metric-label"><%= tr(@lang, "Retrying", "重试队列") %></p>
              <p class="metric-value numeric"><%= field(field(@runtime_payload, "counts"), "retrying") || 0 %></p>
              <p class="metric-detail"><%= tr(@lang, "Issues waiting for the next retry window.", "等待下一次重试窗口的议题数。") %></p>
              <div class="activity-meter"><span style={meter_width_style(min((field(field(@runtime_payload, "counts"), "retrying") || 0) * 34, 100))}></span></div>
            </article>

            <article class="metric-card">
              <p class="metric-label"><%= tr(@lang, "Total tokens", "总 token") %></p>
              <p class="metric-value numeric"><%= format_int(field(field(@runtime_payload, "codex_totals"), "total_tokens")) %></p>
              <p class="metric-detail numeric">
                <%= tr(@lang, "In", "输入") %> <%= format_int(field(field(@runtime_payload, "codex_totals"), "input_tokens")) %>
                /
                <%= tr(@lang, "Out", "输出") %> <%= format_int(field(field(@runtime_payload, "codex_totals"), "output_tokens")) %>
              </p>
            </article>

            <article class="metric-card">
              <p class="metric-label"><%= tr(@lang, "Runtime", "运行时长") %></p>
              <p class="metric-value numeric"><%= format_runtime_seconds(total_runtime_seconds(@runtime_payload, @now)) %></p>
              <p class="metric-detail"><%= tr(@lang, "Total Codex runtime across completed and active sessions.", "已完成与进行中的会话累计运行时长。") %></p>
            </article>
          </section>

          <div class="section-stack">
            <section>
              <h3 class="section-subtitle"><%= tr(@lang, "Running sessions", "运行会话") %></h3>
              <%= if normalized_runtime_entries(field(@runtime_payload, "running")) == [] do %>
                <p class="empty-state"><%= tr(@lang, "No active sessions.", "当前没有活跃会话。") %></p>
              <% else %>
                <div class="table-wrap">
                  <table class="data-table">
                    <thead>
                      <tr>
                        <th><%= tr(@lang, "Issue", "议题") %></th>
                        <th><%= tr(@lang, "State", "状态") %></th>
                        <th><%= tr(@lang, "Session", "会话") %></th>
                        <th><%= tr(@lang, "Runtime / turns", "运行时长 / 轮次") %></th>
                        <th><%= tr(@lang, "Codex update", "Codex 更新") %></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={entry <- normalized_runtime_entries(field(@runtime_payload, "running"))}>
                        <td>
                          <button type="button" class="issue-link issue-button" phx-click="select_issue" phx-value-issue={field(entry, "issue_identifier")}>
                            <%= field(entry, "issue_identifier") %>
                          </button>
                        </td>
                        <td><span class={state_badge_class(field(entry, "state"))}><%= field(entry, "state") || tr(@lang, "n/a", "未提供") %></span></td>
                        <td class="mono"><%= field(entry, "session_id") || tr(@lang, "n/a", "未提供") %></td>
                        <td class="numeric"><%= format_runtime_and_turns(field(entry, "started_at"), field(entry, "turn_count"), @now) %></td>
                        <td><%= field(entry, "last_message") || field(entry, "last_event") || tr(@lang, "n/a", "未提供") %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </section>

            <section>
              <h3 class="section-subtitle"><%= tr(@lang, "Retry queue", "重试队列") %></h3>
              <%= if normalized_runtime_entries(field(@runtime_payload, "retrying")) == [] do %>
                <p class="empty-state"><%= tr(@lang, "No issues are currently backing off.", "当前没有议题在退避重试。") %></p>
              <% else %>
                <div class="table-wrap">
                  <table class="data-table">
                    <thead>
                      <tr>
                        <th><%= tr(@lang, "Issue", "议题") %></th>
                        <th><%= tr(@lang, "Attempt", "尝试") %></th>
                        <th><%= tr(@lang, "Due at", "预计重试时间") %></th>
                        <th><%= tr(@lang, "Error", "错误") %></th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={entry <- normalized_runtime_entries(field(@runtime_payload, "retrying"))}>
                        <td>
                          <button type="button" class="issue-link issue-button" phx-click="select_issue" phx-value-issue={field(entry, "issue_identifier")}>
                            <%= field(entry, "issue_identifier") %>
                          </button>
                        </td>
                        <td><%= field(entry, "attempt") || tr(@lang, "n/a", "未提供") %></td>
                        <td class="mono"><%= field(entry, "due_at") || tr(@lang, "n/a", "未提供") %></td>
                        <td><%= field(entry, "error") || tr(@lang, "n/a", "未提供") %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              <% end %>
            </section>
          </div>
        <% end %>
      </section>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title"><%= tr(@lang, "Controls", "控制面板") %></h2>
            <p class="section-copy"><%= tr(@lang, "Load an issue from the bridge, tune refresh, and include doctor/workpad/log data on demand.", "从 bridge 加载议题，按需查看 doctor、workpad、日志，并调整刷新策略。") %></p>
          </div>
          <button type="button" class="subtle-button" phx-click="refresh"><%= tr(@lang, "Refresh now", "立即刷新") %></button>
        </div>

        <form id="issue-query-form" class="toolbar-form" phx-submit="load_issue">
          <div :if={selected_profile(@profiles, @selected_profile)} class="toolbar-field toolbar-field-full">
            <span><%= tr(@lang, "Execution profile", "执行模板") %></span>
            <div class="inspector-card">
              <div class="inspector-card-head">
                <h4><%= profile_label(selected_profile(@profiles, @selected_profile), @lang) %></h4>
              </div>
              <p class="section-copy">
                <%= profile_description(selected_profile(@profiles, @selected_profile), @lang) %>
              </p>
            </div>
          </div>

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
            <div class="run-board">
              <article :for={run <- @runs} class="run-card">
                <div class="run-card-head">
                  <button
                    type="button"
                    class="issue-link issue-button run-card-issue"
                    phx-click="select_issue"
                    phx-value-issue={field(run, "issue")}
                  >
                    <%= field(run, "issue") %>
                  </button>
                  <span class={state_badge_class(field(run, "phase"))}><%= field(run, "phase") || tr(@lang, "n/a", "未提供") %></span>
                </div>
                <p class="run-card-summary"><%= recent_run_summary(run, @lang) %></p>
                <div class="run-card-meta">
                  <span><%= tr(@lang, "Route", "路由") %>: <strong><%= route_hint_text(run, @lang) %></strong></span>
                  <span class="mono"><%= field(run, "updated_at") || tr(@lang, "n/a", "未提供") %></span>
                </div>
              </article>
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
            <section class="mission-strip">
              <div class="section-header section-header-tight">
                <div>
                  <h3 class="section-subtitle"><%= tr(@lang, "Mission progress", "任务进度") %></h3>
                  <p class="section-copy"><%= tr(@lang, "Watch the selected issue move from queue to delivery without leaving the cockpit.", "在控制台里直接观察当前议题从排队到交付的推进。") %></p>
                </div>
              </div>
              <div class="progress-track">
                <article :for={step <- phase_progress_steps(@status, @lang)} class={phase_step_class(step.state)}>
                  <div class="progress-dot"></div>
                  <div>
                    <p class="progress-title"><%= step.title %></p>
                    <p class="progress-copy"><%= step.copy %></p>
                  </div>
                </article>
              </div>
            </section>

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

              <article class="metric-card">
                <p class="metric-label"><%= tr(@lang, "Runtime", "运行时") %></p>
                <p class="metric-value"><%= runtime_label(field(@status, "runtime_control"), @lang) %></p>
                <p class="metric-detail"><%= runtime_reason(field(@status, "runtime_control"), @lang) %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label"><%= tr(@lang, "Issue control", "议题控制") %></p>
                <p class="metric-value"><%= issue_control_label(field(@status, "issue_control"), @lang) %></p>
                <p class="metric-detail"><%= issue_control_reason(field(@status, "issue_control"), @lang) %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label"><%= tr(@lang, "Live session", "实时会话") %></p>
                <p class="metric-value mono"><%= runtime_issue_label(field(@status, "runtime_issue"), @lang) %></p>
                <p class="metric-detail"><%= runtime_issue_detail(field(@status, "runtime_issue"), @lang) %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label"><%= tr(@lang, "Operator instruction", "操作指令") %></p>
                <p class="metric-value"><%= operator_instruction_label(@status, @lang) %></p>
                <p class="metric-detail"><%= operator_instruction_detail(@status, @lang) %></p>
              </article>
            </div>

            <div class="section-stack">
              <section>
                <h3 class="section-subtitle"><%= tr(@lang, "Delivery", "交付状态") %></h3>
                <div class="detail-grid">
                  <article class="metric-card">
                    <p class="metric-label"><%= tr(@lang, "Route", "交付路线") %></p>
                    <p class="metric-value"><%= delivery_route_label(field(@status, "delivery"), @lang) %></p>
                    <p class="metric-detail"><%= delivery_route_detail(field(@status, "delivery"), @lang) %></p>
                  </article>

                  <article class="metric-card">
                    <p class="metric-label"><%= tr(@lang, "Pull request", "拉取请求") %></p>
                    <p class="metric-value"><%= delivery_pr_label(field(@status, "delivery"), @lang) %></p>
                    <p class="metric-detail"><%= delivery_pr_detail(field(@status, "delivery"), @lang) %></p>
                    <p :if={delivery_pr_url(field(@status, "delivery"))} class="metric-detail">
                      <a class="issue-link" href={delivery_pr_url(field(@status, "delivery"))} target="_blank" rel="noreferrer">
                        <%= tr(@lang, "Open pull request", "打开 PR") %>
                      </a>
                    </p>
                  </article>

                  <article class="metric-card">
                    <p class="metric-label"><%= tr(@lang, "Remote CI", "远端 CI") %></p>
                    <p class="metric-value"><%= delivery_ci_label(field(@status, "delivery"), @lang) %></p>
                    <p class="metric-detail"><%= delivery_ci_detail(field(@status, "delivery"), @lang) %></p>
                    <p :if={delivery_ci_url(field(@status, "delivery"))} class="metric-detail">
                      <a class="issue-link" href={delivery_ci_url(field(@status, "delivery"))} target="_blank" rel="noreferrer">
                        <%= tr(@lang, "Open pipeline", "打开流水线") %>
                      </a>
                    </p>
                  </article>

                  <article class="metric-card">
                    <p class="metric-label"><%= tr(@lang, "Merge automation", "合并自动化") %></p>
                    <p class="metric-value"><%= delivery_automation_label(field(@status, "delivery"), @lang) %></p>
                    <p class="metric-detail"><%= delivery_automation_detail(field(@status, "delivery"), @lang) %></p>
                  </article>
                </div>
              </section>

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
                <h3 class="section-subtitle"><%= tr(@lang, "Instruction history", "指令历史") %></h3>
                <%= if instruction_history(field(@status, "operator_instruction_history")) == [] do %>
                  <p class="empty-state"><%= tr(@lang, "No completed instruction transitions yet.", "当前还没有已完成的指令状态迁移。") %></p>
                <% else %>
                  <div class="timeline-list">
                    <article :for={instruction <- instruction_history(field(@status, "operator_instruction_history"))} class="timeline-item">
                      <div class="timeline-head">
                        <span class={state_badge_class(field(instruction, "delivery_state"))}><%= instruction_state_text(instruction, @lang) %></span>
                        <span class="timeline-time mono"><%= instruction_state_timestamp(instruction) || tr(@lang, "n/a", "未提供") %></span>
                      </div>
                      <p class="timeline-summary"><%= field(instruction, "message") || tr(@lang, "n/a", "未提供") %></p>
                      <p class="timeline-meta"><%= instruction_history_meta(instruction, @lang) %></p>
                    </article>
                  </div>
                <% end %>
              </section>

              <section>
                <h3 class="section-subtitle"><%= tr(@lang, "Actions", "控制动作") %></h3>
                <article class={guidance_callout_class(@status)}>
                  <p class="guidance-eyebrow"><%= tr(@lang, "What the cockpit suggests next", "控制台建议的下一步") %></p>
                  <p class="guidance-copy"><%= action_guidance(@status, @lang) %></p>
                </article>
                <%= if @action_feedback do %>
                  <div class={action_feedback_class(@action_feedback)}>
                    <span class="feedback-icon"><%= action_feedback_icon(@action_feedback, @lang) %></span>
                    <strong><%= field(@action_feedback, "label") %></strong>
                    <span><%= field(@action_feedback, "message") %></span>
                    <span :if={field(@action_feedback, "at")} class="mono"><%= field(@action_feedback, "at") %></span>
                  </div>
                <% end %>
                <div class="action-row">
                  <button id="pause-run" type="button" class="subtle-button" phx-click="pause" disabled={action_disabled?(@status, "pause")}><%= tr(@lang, "Pause intake", "暂停 intake") %></button>
                  <button id="resume-run" type="button" class="subtle-button" phx-click="resume" disabled={action_disabled?(@status, "resume")}><%= tr(@lang, "Resume intake", "恢复 intake") %></button>
                  <button id="cancel-run" type="button" class="subtle-button" phx-click="cancel" disabled={action_disabled?(@status, "cancel")}><%= tr(@lang, "Cancel current run", "取消当前运行") %></button>
                  <button id="hold-run" type="button" class="subtle-button" phx-click="hold" disabled={action_disabled?(@status, "hold")}><%= tr(@lang, "Hold issue", "挂起议题") %></button>
                  <button id="release-run" type="button" class="subtle-button" phx-click="release" disabled={action_disabled?(@status, "release")}><%= tr(@lang, "Release hold", "解除挂起") %></button>
                  <button id="restart-run" type="button" class="subtle-button" phx-click="restart" disabled={action_disabled?(@status, "restart")}><%= tr(@lang, "Restart run", "重启运行") %></button>
                  <button id="clear-instruction" type="button" class="subtle-button" phx-click="clear_instruction" disabled={action_disabled?(@status, "clear_instruction")}><%= tr(@lang, "Clear instruction", "清除指令") %></button>
                </div>

                <form id="instruction-form" class="instruction-form" phx-submit="instruction_action">
                  <label class="toolbar-field toolbar-field-full">
                    <span><%= tr(@lang, "Operator instruction", "操作指令") %></span>
                    <textarea
                      class="form-input form-textarea"
                      name="message"
                      placeholder={instruction_placeholder(@profiles, @selected_profile, @lang)}
                    ><%= @instruction_message %></textarea>
                  </label>

                  <label class="checkbox-field">
                    <input type="checkbox" name="sync_linear" value="true" checked={@sync_linear} />
                    <span><%= tr(@lang, "Sync to Linear", "同步到 Linear") %></span>
                  </label>

                  <div class="action-row">
                    <button type="submit" name="intent" value="append" class="subtle-button subtle-button-primary" disabled={action_disabled?(@status, "instruction")}><%= tr(@lang, "Append instruction", "追加指令") %></button>
                    <button id="steer-run" type="submit" name="intent" value="steer" class="subtle-button" disabled={action_disabled?(@status, "steer")}><%= tr(@lang, "Steer run", "引导运行") %></button>
                  </div>
                  <p class="section-copy action-copy">
                    <%= tr(@lang, "Append queues operator input for the next restart. Steer queues it and immediately requests a restart path.", "追加指令只会排队等待下次重启应用；引导运行会排队这条指令并立即请求重启路径。") %>
                  </p>
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
                  <%= if not has_console_streams?(@status) do %>
                    <p class="empty-state"><%= tr(@lang, "No logs returned. Reload the issue with agent or raw logs enabled.", "当前没有返回日志。请重新加载议题并启用执行日志或原始日志。") %></p>
                  <% else %>
                    <div class="stream-grid">
                      <article class="inspector-card stream-card">
                        <div class="inspector-card-head">
                          <h4><%= tr(@lang, "Agent stream", "执行流") %></h4>
                        </div>
                        <p class="section-copy"><%= tr(@lang, "Latest agent-facing execution output.", "最近的 agent 执行输出。") %></p>
                        <%= if content = agent_log_content(field(@status, "logs")) do %>
                          <pre class="code-panel"><%= content %></pre>
                        <% else %>
                          <p class="empty-state"><%= tr(@lang, "No agent log returned.", "当前没有返回执行日志。") %></p>
                        <% end %>
                      </article>

                      <article class="inspector-card stream-card">
                        <div class="inspector-card-head">
                          <h4><%= tr(@lang, "Decision stream", "决策流") %></h4>
                        </div>
                        <p class="section-copy"><%= tr(@lang, "Recent orchestration events, summarized as decision traces.", "最近的编排事件，整理为决策轨迹。") %></p>
                        <%= if content = decision_log_content(field(@status, "latest_events")) do %>
                          <pre class="code-panel"><%= content %></pre>
                        <% else %>
                          <p class="empty-state"><%= tr(@lang, "No decision events returned.", "当前没有返回决策事件。") %></p>
                        <% end %>
                      </article>

                      <article class="inspector-card stream-card">
                      <div class="inspector-card-head">
                          <h4><%= tr(@lang, "Raw stream", "原始流") %></h4>
                      </div>
                        <p class="section-copy"><%= tr(@lang, "Raw process/file output from the bridge adapter.", "来自 bridge adapter 的原始进程/文件输出。") %></p>
                        <%= if raw_log_streams(field(@status, "logs")) == [] do %>
                          <p class="empty-state"><%= tr(@lang, "No raw log returned.", "当前没有返回原始日志。") %></p>
                        <% else %>
                          <div :if={length(raw_log_streams(field(@status, "logs"))) > 1} class="panel-tab-row">
                            <button
                              :for={stream <- raw_log_streams(field(@status, "logs"))}
                              type="button"
                              class={panel_button_class(active_raw_log_stream(@status, @active_log_stream), stream.id)}
                              phx-click="set_log_stream"
                              phx-value-stream={stream.id}
                            ><%= stream.label %></button>
                          </div>
                          <article :if={selected_stream = selected_raw_log_stream(field(@status, "logs"), @active_log_stream)} class="stream-inner-card">
                            <div class="inspector-card-head">
                              <h4><%= selected_stream.label %></h4>
                            </div>
                            <pre class="code-panel"><%= selected_stream.content %></pre>
                          </article>
                        <% end %>
                      </article>
                    </div>
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
      case client_meta(socket.assigns.selected_adapter) do
        {:ok, meta} ->
          events_limit = socket.assigns.events_limit || field(meta, "default_event_limit") || 10

          socket
          |> assign(:meta, meta)
          |> assign(:events_limit, events_limit)
          |> assign(:error_message, nil)
          |> reconcile_profile_assigns(meta)

        {:error, reason} ->
          assign(socket, :error_message, error_message(socket.assigns.lang, reason))
      end

    socket =
      case client_list_runs(12, socket.assigns.selected_adapter) do
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

    case client_get_status(socket.assigns.selected_issue, opts, socket.assigns.selected_adapter) do
      {:ok, status} ->
        socket
        |> assign(:status, status)
        |> assign(:active_log_stream, default_raw_log_stream_id(field(status, "logs")))
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
        profile: socket.assigns.selected_profile,
        branch: blank_to_nil(socket.assigns.branch_override),
        message: blank_to_nil(params["message"]),
        syncLinear: params["sync_linear"]
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    case client_create_action(payload, socket.assigns.selected_adapter) do
      {:ok, response} ->
        socket
        |> assign(:status, field(response, "status") || socket.assigns.status)
        |> assign(:action_feedback, %{
          "kind" => "success",
          "label" => tr(socket.assigns.lang, "Action applied", "动作已执行"),
          "message" => action_success_message(socket.assigns.lang, params["action"]),
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })
        |> put_flash(:info, action_success_message(socket.assigns.lang, params["action"]))
        |> refresh_console(load_status?: true)

      {:error, reason} ->
        socket
        |> assign(:action_feedback, %{
          "kind" => "error",
          "label" => tr(socket.assigns.lang, "Action failed", "动作失败"),
          "message" => error_message(socket.assigns.lang, reason),
          "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
        })
        |> put_flash(:error, error_message(socket.assigns.lang, reason))
    end
  end

  defp client_module do
    module = Application.get_env(:symphony_elixir, :console_client_module, SymphonyElixir.ConsoleClient)
    if is_atom(module), do: Code.ensure_loaded(module)
    module
  end

  defp adapter_options do
    module = client_module()

    if function_exported?(module, :list_adapters, 0) do
      module.list_adapters()
    else
      []
    end
  end

  defp default_adapter_id([first | _rest]), do: first.id
  defp default_adapter_id([]), do: nil

  defp selected_adapter_id([], _requested), do: nil
  defp selected_adapter_id(adapters, requested) when requested in [nil, ""], do: default_adapter_id(adapters)

  defp selected_adapter_id(adapters, requested) do
    if Enum.any?(adapters, &(&1.id == requested)) do
      requested
    else
      default_adapter_id(adapters)
    end
  end

  defp client_meta(adapter_id) do
    module = client_module()

    cond do
      function_exported?(module, :meta, 1) -> module.meta(adapter_id)
      function_exported?(module, :meta, 0) -> module.meta()
      true -> {:error, :not_configured}
    end
  end

  defp client_list_runs(limit, adapter_id) do
    module = client_module()

    cond do
      function_exported?(module, :list_runs, 2) -> module.list_runs(limit, adapter_id)
      function_exported?(module, :list_runs, 1) -> module.list_runs(limit)
      function_exported?(module, :list_runs, 0) -> module.list_runs()
      true -> {:error, :not_configured}
    end
  end

  defp client_get_status(issue_identifier, opts, adapter_id) do
    module = client_module()

    cond do
      function_exported?(module, :get_status, 3) -> module.get_status(issue_identifier, opts, adapter_id)
      function_exported?(module, :get_status, 2) -> module.get_status(issue_identifier, opts)
      true -> {:error, :not_configured}
    end
  end

  defp client_create_action(payload, adapter_id) do
    module = client_module()

    cond do
      function_exported?(module, :create_action, 2) -> module.create_action(payload, adapter_id)
      function_exported?(module, :create_action, 1) -> module.create_action(payload)
      true -> {:error, :not_configured}
    end
  end

  defp adapter_label(nil), do: "Project"
  defp adapter_label(meta), do: field(meta, "repo_name") || field(meta, "repo_key") || "Project"

  defp reconcile_profile_assigns(socket, meta) do
    previous_selected_profile = socket.assigns.selected_profile
    profiles = profile_options(meta)
    selected_profile = selected_profile_id(profiles, socket.assigns.selected_profile, default_profile_id(meta, profiles))

    socket =
      socket
      |> assign(:profiles, profiles)
      |> assign(:selected_profile, selected_profile)

    if selected_profile != socket.assigns.profile_defaults_for or previous_selected_profile != selected_profile do
      apply_profile_defaults(socket, selected_profile(profiles, selected_profile))
    else
      socket
    end
  end

  defp profile_options(meta) when is_map(meta) do
    case field(meta, "profiles") do
      profiles when is_list(profiles) -> Enum.filter(profiles, &present?(profile_id(&1)))
      _ -> []
    end
  end

  defp profile_options(_meta), do: []

  defp default_profile_id(meta, profiles) do
    requested = blank_to_nil(field(meta, "default_profile"))

    if requested && Enum.any?(profiles, &(profile_id(&1) == requested)) do
      requested
    else
      case profiles do
        [first | _rest] -> profile_id(first)
        [] -> nil
      end
    end
  end

  defp selected_profile_id([], _requested, _default_id), do: nil
  defp selected_profile_id(profiles, requested, default_id) when requested in [nil, ""], do: default_id || profile_id(hd(profiles))

  defp selected_profile_id(profiles, requested, default_id) do
    if Enum.any?(profiles, &(profile_id(&1) == requested)) do
      requested
    else
      default_id || profile_id(hd(profiles))
    end
  end

  defp selected_profile(profiles, selected_id) when is_list(profiles) do
    Enum.find(profiles, &(profile_id(&1) == selected_id))
  end

  defp apply_profile_defaults(socket, nil), do: socket

  defp apply_profile_defaults(socket, profile) do
    defaults = field(profile, "defaults")
    template = localized_field(profile, "instructionTemplate", socket.assigns.lang)
    profile_id = profile_id(profile)

    socket
    |> maybe_assign(:events_limit, profile_default(defaults, "events", socket.assigns.events_limit))
    |> maybe_assign(:include_logs, profile_default(defaults, "includeLogs", socket.assigns.include_logs))
    |> maybe_assign(:include_doctor, profile_default(defaults, "includeDoctor", socket.assigns.include_doctor))
    |> maybe_assign(:include_workpad, profile_default(defaults, "includeWorkpad", socket.assigns.include_workpad))
    |> maybe_assign(:sync_linear, profile_default(defaults, "syncLinear", socket.assigns.sync_linear))
    |> maybe_assign(
      :instruction_message,
      if(blank_to_nil(socket.assigns.instruction_message),
        do: socket.assigns.instruction_message,
        else: template
      )
    )
    |> assign(:profile_defaults_for, profile_id)
  end

  defp profile_default(defaults, key, fallback) when is_map(defaults) do
    case field(defaults, key) do
      nil -> fallback
      value -> value
    end
  end

  defp profile_default(_defaults, _key, fallback), do: fallback

  defp maybe_assign(socket, _key, nil), do: socket
  defp maybe_assign(socket, key, value), do: assign(socket, key, value)

  defp profile_id(profile), do: blank_to_nil(field(profile, "id"))
  defp profile_label(profile, lang), do: localized_field(profile, "label", lang) || profile_id(profile) || "Profile"
  defp profile_description(profile, lang), do: localized_field(profile, "description", lang) || tr(lang, "No profile description.", "当前没有模板说明。")

  defp instruction_placeholder(profiles, selected_id, lang) do
    case selected_profile(profiles, selected_id) do
      nil ->
        tr(lang, "Add a new instruction for this run", "为当前运行补充新的执行指令")

      profile ->
        localized_field(profile, "instructionTemplate", lang) ||
          tr(lang, "Add a new instruction for this run", "为当前运行补充新的执行指令")
    end
  end

  defp localized_field(profile, key, lang) do
    case field(profile, key) do
      text when is_binary(text) -> blank_to_nil(text)
      localized when is_map(localized) -> blank_to_nil(field(localized, lang) || field(localized, "zh") || field(localized, "en"))
      _ -> nil
    end
  end

  defp refresh_selected?(value, refresh_interval_ms) do
    selected =
      if refresh_interval_ms > 0 do
        Integer.to_string(refresh_interval_ms)
      else
        "off"
      end

    value == selected
  end

  defp normalized_runtime_entries(nil), do: []
  defp normalized_runtime_entries(entries) when is_list(entries), do: entries
  defp normalized_runtime_entries(_entries), do: []

  defp runtime_error_message(%{"message" => message, "code" => code}, "en"),
    do: "#{message} (#{code})"

  defp runtime_error_message(%{"message" => message, "code" => code}, _lang),
    do: "#{message}（#{code}）"

  defp runtime_error_message(message, _lang) when is_binary(message), do: message

  defp runtime_error_message(_error, "en"), do: "Runtime snapshot unavailable"
  defp runtime_error_message(_error, _lang), do: "运行态快照不可用"

  defp action_success_message(lang, "pause"), do: tr(lang, "Pause recorded", "已记录暂停请求")
  defp action_success_message(lang, "resume"), do: tr(lang, "Continue recorded", "已记录继续请求")
  defp action_success_message(lang, "cancel"), do: tr(lang, "Current run cancelled", "已取消当前运行")
  defp action_success_message(lang, "hold"), do: tr(lang, "Issue hold applied", "已挂起议题")
  defp action_success_message(lang, "release"), do: tr(lang, "Issue hold released", "已解除挂起")
  defp action_success_message(lang, "restart"), do: tr(lang, "Restart scheduled", "已安排重启")
  defp action_success_message(lang, "clear_instruction"), do: tr(lang, "Pending instruction cleared", "已清除待生效指令")
  defp action_success_message(lang, "instruction"), do: tr(lang, "Instruction queued for the next restart", "已将指令排队，等待下次重启应用")
  defp action_success_message(lang, "steer"), do: tr(lang, "Instruction queued and restart requested", "已排队指令，并请求重启应用")
  defp action_success_message(lang, _action), do: tr(lang, "Action recorded", "已记录动作")

  defp action_feedback_class(nil), do: "action-feedback"

  defp action_feedback_class(feedback) when is_map(feedback) do
    case field(feedback, "kind") do
      "error" -> "action-feedback action-feedback-error"
      _ -> "action-feedback action-feedback-success"
    end
  end

  defp action_feedback_icon(feedback, "en") do
    case field(feedback, "kind") do
      "error" -> "Error"
      _ -> "Done"
    end
  end

  defp action_feedback_icon(feedback, _lang) do
    case field(feedback, "kind") do
      "error" -> "失败"
      _ -> "完成"
    end
  end

  defp heartbeat_label(now, "en"), do: "Heartbeat #{Calendar.strftime(now, "%H:%M:%S")}"
  defp heartbeat_label(now, _lang), do: "心跳 #{Calendar.strftime(now, "%H:%M:%S")}"

  defp heartbeat_copy(payload, lang) do
    running = field(field(payload, "counts"), "running") || 0
    retrying = field(field(payload, "counts"), "retrying") || 0

    if running > 0 do
      tr(lang, "#{running} active issue sessions are streaming live right now.", "当前有 #{running} 个议题会话正在实时运行。")
    else
      tr(lang, "No active issue session is streaming right now.", "当前没有议题会话正在实时运行。")
    end <>
      " " <>
      tr(lang, "#{retrying} issues are queued for retry.", "#{retrying} 个议题正在等待重试。")
  end

  defp spotlight_title(nil, lang),
    do: tr(lang, "Load an issue to focus the cockpit", "加载一个议题，让操作台聚焦到当前任务")

  defp spotlight_title(status, _lang), do: field(status, "issue") || "n/a"

  defp spotlight_summary(nil, lang),
    do: tr(lang, "The cockpit will surface live runtime state, operator controls, and delivery progress once an issue is selected.", "选中议题后，这里会显示实时运行态、控制动作和交付进度。")

  defp spotlight_summary(status, lang) do
    summary = field(status, "summary") || tr(lang, "No summary returned.", "当前没有返回摘要。")
    phase = field(status, "phase") || tr(lang, "n/a", "未提供")
    route = field(status, "route_hint") || tr(lang, "n/a", "未提供")
    "#{summary} " <> tr(lang, "Phase", "阶段") <> ": #{phase} · " <> tr(lang, "Route", "路由") <> ": #{route}"
  end

  defp operator_feedback_title(nil, lang),
    do: tr(lang, "No operator action yet", "当前没有新的操作反馈")

  defp operator_feedback_title(feedback, _lang), do: field(feedback, "label") || "n/a"

  defp operator_feedback_copy(nil, status, lang) do
    operator_instruction_detail(status, lang)
  end

  defp operator_feedback_copy(feedback, _status, _lang), do: field(feedback, "message") || "n/a"

  defp phase_progress_steps(status, lang) do
    current_index = phase_progress_index(status)

    [
      {1, tr(lang, "Queue", "排队"), tr(lang, "Issue is discovered and waiting to be worked.", "议题已被发现，等待进入执行。")},
      {2, tr(lang, "Build", "实现"), tr(lang, "Worker is changing code or preparing the workspace.", "执行器正在改代码或准备工作区。")},
      {3, tr(lang, "Validate", "验证"), tr(lang, "Checks, CI, and runtime verification are in progress.", "本地检查、CI 和运行验证进行中。")},
      {4, tr(lang, "Review", "评审"), tr(lang, "Human review and operator feedback decide the next route.", "人工评审和操作员反馈决定下一步路由。")},
      {5, tr(lang, "Ship", "交付"), tr(lang, "PR, merge automation, and completion state are converging.", "PR、合并自动化和完成状态正在收口。")}
    ]
    |> Enum.map(fn {index, title, copy} ->
      state =
        cond do
          index < current_index -> "complete"
          index == current_index -> "current"
          true -> "upcoming"
        end

      %{index: index, title: title, copy: copy, state: state}
    end)
  end

  defp phase_progress_index(nil), do: 1

  defp phase_progress_index(status) do
    phase = status |> field("phase") |> to_string() |> String.downcase()
    route = status |> field("route_hint") |> to_string() |> String.downcase()
    delivery = field(status, "delivery")
    merged = field(field(delivery, "pull_request"), "merged") in [true, "true"]

    cond do
      merged or route == "done" -> 5
      route in ["merging"] -> 5
      route in ["human review"] or phase in ["handoff", "review"] -> 4
      phase in ["validation"] or route in ["rework"] -> 3
      phase in ["implementation", "sync"] -> 2
      true -> 1
    end
  end

  defp phase_step_class("complete"), do: "progress-step progress-step-complete"
  defp phase_step_class("current"), do: "progress-step progress-step-current"
  defp phase_step_class(_state), do: "progress-step progress-step-upcoming"

  defp guidance_callout_class(status) do
    runtime_paused = field(field(status, "runtime_control"), "paused") in [true, "true"]
    issue_held = field(field(status, "issue_control"), "held") in [true, "true"]
    runtime_scope = runtime_scope(status)

    cond do
      runtime_paused or issue_held ->
        "guidance-callout guidance-callout-warning"

      runtime_scope in ["running", "retrying"] ->
        "guidance-callout guidance-callout-active"

      true ->
        "guidance-callout guidance-callout-neutral"
    end
  end

  defp meter_width_style(percent) when is_integer(percent),
    do: "width: #{min(max(percent, 0), 100)}%;"

  defp runtime_activity_percent(payload) do
    running = field(field(payload, "counts"), "running") || 0
    retrying = field(field(payload, "counts"), "retrying") || 0
    min(running * 45 + retrying * 15, 100)
  end

  defp recent_run_summary(run, lang) do
    route = route_hint_text(run, lang)
    updated = field(run, "updated_at") || tr(lang, "n/a", "未提供")
    tr(lang, "Route", "路由") <> ": #{route} · " <> tr(lang, "Updated", "更新时间") <> ": #{updated}"
  end

  defp route_hint_text(run, lang) do
    run
    |> field("route_hint")
    |> normalize_blank_text()
    |> Kernel.||(tr(lang, "n/a", "未提供"))
  end

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

  defp has_console_streams?(status) do
    present?(agent_log_content(field(status, "logs"))) or
      present?(decision_log_content(field(status, "latest_events"))) or
      raw_log_streams(field(status, "logs")) != []
  end

  defp agent_log_content(logs) when is_map(logs), do: blank_to_nil(field(logs, "agent"))
  defp agent_log_content(_logs), do: nil

  defp decision_log_content(nil), do: nil

  defp decision_log_content(events) when is_list(events) do
    events
    |> Enum.map(&decision_event_line/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      lines -> Enum.join(lines, "\n")
    end
  end

  defp decision_log_content(_events), do: nil

  defp decision_event_line(event) when is_map(event) do
    summary = blank_to_nil(field(event, "summary"))

    if summary do
      ts = blank_to_nil(field(event, "ts")) || "n/a"
      type = blank_to_nil(field(event, "type")) || "event"
      actor = blank_to_nil(field(event, "actor"))

      "[#{ts}] #{type}" <>
        if(actor, do: " @ #{actor}", else: "") <>
        "\n" <> summary
    else
      nil
    end
  end

  defp decision_event_line(_event), do: nil

  defp raw_log_streams(nil), do: []

  defp raw_log_streams(logs) when is_map(logs) do
    case field(logs, "raw") do
      raw when is_map(raw) ->
        raw
        |> Enum.map(fn {key, value} -> %{id: "raw:" <> to_string(key), label: to_string(key), content: to_string(value)} end)
        |> Enum.sort_by(& &1.label)

      _ ->
        []
    end
  end

  defp raw_log_streams(_logs), do: []

  defp default_raw_log_stream_id(logs) do
    case raw_log_streams(logs) do
      [first | _rest] -> first.id
      [] -> nil
    end
  end

  defp active_raw_log_stream(status, active_stream) do
    active_stream || default_raw_log_stream_id(field(status, "logs"))
  end

  defp selected_raw_log_stream(logs, active_stream) do
    stream_id = active_stream || default_raw_log_stream_id(logs)
    Enum.find(raw_log_streams(logs), &(&1.id == stream_id))
  end

  defp runtime_label(nil, lang), do: tr(lang, "Unknown", "未知")

  defp runtime_label(runtime_control, lang) when is_map(runtime_control) do
    if field(runtime_control, "paused") in [true, "true"] do
      tr(lang, "Paused", "已暂停")
    else
      tr(lang, "Running", "运行中")
    end
  end

  defp runtime_label(_runtime_control, lang), do: tr(lang, "Unknown", "未知")

  defp runtime_reason(nil, lang), do: tr(lang, "No runtime control state returned.", "当前没有返回运行时控制状态。")

  defp runtime_reason(runtime_control, lang) when is_map(runtime_control) do
    paused_at = blank_to_nil(field(runtime_control, "paused_at"))
    pause_reason = blank_to_nil(field(runtime_control, "pause_reason"))

    cond do
      (field(runtime_control, "paused") in [true, "true"] and pause_reason) && paused_at ->
        tr(lang, "Paused at #{paused_at}: #{pause_reason}", "于 #{paused_at} 暂停：#{pause_reason}")

      field(runtime_control, "paused") in [true, "true"] and pause_reason ->
        tr(lang, "Paused: #{pause_reason}", "已暂停：#{pause_reason}")

      field(runtime_control, "paused") in [true, "true"] ->
        tr(lang, "Dispatch is paused until resume is requested.", "新的 dispatch 已暂停，直到显式恢复。")

      true ->
        tr(lang, "Dispatch and retry intake are active.", "dispatch 和 retry intake 处于活跃状态。")
    end
  end

  defp runtime_reason(_runtime_control, lang), do: tr(lang, "No runtime control state returned.", "当前没有返回运行时控制状态。")

  defp issue_control_label(nil, lang), do: tr(lang, "Active", "活跃")

  defp issue_control_label(issue_control, lang) when is_map(issue_control) do
    if field(issue_control, "held") in [true, "true"] do
      tr(lang, "Held", "已挂起")
    else
      tr(lang, "Active", "活跃")
    end
  end

  defp issue_control_label(_issue_control, lang), do: tr(lang, "Active", "活跃")

  defp issue_control_reason(nil, lang),
    do: tr(lang, "This issue is eligible for dispatch when the runtime is active.", "该议题在 runtime 活跃时可被派发。")

  defp issue_control_reason(issue_control, lang) when is_map(issue_control) do
    held_at = blank_to_nil(field(issue_control, "held_at"))
    reason = blank_to_nil(field(issue_control, "reason"))

    cond do
      (field(issue_control, "held") in [true, "true"] and reason) && held_at ->
        tr(lang, "Held at #{held_at}: #{reason}", "于 #{held_at} 挂起：#{reason}")

      field(issue_control, "held") in [true, "true"] and reason ->
        tr(lang, "Held: #{reason}", "已挂起：#{reason}")

      field(issue_control, "held") in [true, "true"] ->
        tr(lang, "This issue is manually held until release is requested.", "该议题已被手动挂起，直到显式解除。")

      true ->
        tr(lang, "This issue is eligible for dispatch when the runtime is active.", "该议题在 runtime 活跃时可被派发。")
    end
  end

  defp issue_control_reason(_issue_control, lang),
    do: tr(lang, "This issue is eligible for dispatch when the runtime is active.", "该议题在 runtime 活跃时可被派发。")

  defp runtime_issue_label(nil, lang), do: tr(lang, "No live session", "当前没有实时会话")

  defp runtime_issue_label(runtime_issue, lang) when is_map(runtime_issue) do
    scope = field(runtime_issue, "scope")
    thread_id = blank_to_nil(field(runtime_issue, "thread_id"))
    turn_id = blank_to_nil(field(runtime_issue, "turn_id"))
    session_id = blank_to_nil(field(runtime_issue, "session_id"))

    cond do
      thread_id && turn_id -> "#{thread_id} / #{turn_id}"
      session_id -> session_id
      scope == "retrying" -> tr(lang, "Queued retry", "已排队重试")
      scope == "running" -> tr(lang, "Running", "运行中")
      true -> tr(lang, "No live session", "当前没有实时会话")
    end
  end

  defp runtime_issue_label(_runtime_issue, lang), do: tr(lang, "No live session", "当前没有实时会话")

  defp runtime_issue_detail(nil, lang),
    do: tr(lang, "Load a running issue to inspect live session metadata.", "加载一个运行中的议题后，可在这里看到实时会话元数据。")

  defp runtime_issue_detail(runtime_issue, lang) when is_map(runtime_issue) do
    scope = field(runtime_issue, "scope") || tr(lang, "unknown", "未知")
    pid = blank_to_nil(field(runtime_issue, "codex_app_server_pid"))
    last_event = blank_to_nil(field(runtime_issue, "last_codex_event"))
    worker_host = blank_to_nil(field(runtime_issue, "worker_host"))
    attempt = field(runtime_issue, "attempt")
    due_in_ms = field(runtime_issue, "due_in_ms")

    cond do
      scope == "running" ->
        parts =
          [
            tr(lang, "Scope", "范围") <> ": " <> to_string(scope),
            worker_host && tr(lang, "Worker", "工作节点") <> ": " <> worker_host,
            pid && tr(lang, "AppServer PID", "AppServer PID") <> ": " <> pid,
            last_event && tr(lang, "Last event", "最新事件") <> ": " <> to_string(last_event)
          ]
          |> Enum.reject(&is_nil/1)

        Enum.join(parts, " | ")

      scope == "retrying" ->
        parts =
          [
            tr(lang, "Scope", "范围") <> ": " <> to_string(scope),
            is_integer(attempt) && tr(lang, "Attempt", "尝试次数") <> ": " <> Integer.to_string(attempt),
            is_integer(due_in_ms) && tr(lang, "Due in", "预计开始") <> ": " <> Integer.to_string(due_in_ms) <> "ms"
          ]
          |> Enum.reject(&is_nil/1)

        Enum.join(parts, " | ")

      true ->
        tr(lang, "No live runtime entry returned for this issue.", "当前议题没有返回实时运行条目。")
    end
  end

  defp runtime_issue_detail(_runtime_issue, lang),
    do: tr(lang, "Load a running issue to inspect live session metadata.", "加载一个运行中的议题后，可在这里看到实时会话元数据。")

  defp delivery_route(nil), do: %{}
  defp delivery_route(delivery) when is_map(delivery), do: field(delivery, "route") || %{}
  defp delivery_route(_delivery), do: %{}

  defp delivery_pull_request(nil), do: %{}
  defp delivery_pull_request(delivery) when is_map(delivery), do: field(delivery, "pull_request") || %{}
  defp delivery_pull_request(_delivery), do: %{}

  defp delivery_ci(nil), do: %{}
  defp delivery_ci(delivery) when is_map(delivery), do: field(delivery, "ci") || %{}
  defp delivery_ci(_delivery), do: %{}

  defp delivery_automation(nil), do: %{}
  defp delivery_automation(delivery) when is_map(delivery), do: field(delivery, "automation") || %{}
  defp delivery_automation(_delivery), do: %{}

  defp delivery_route_label(delivery, lang) do
    case field(delivery_route(delivery), "status") do
      "merged" -> tr(lang, "Merged", "已合并")
      "done" -> tr(lang, "Done", "已完成")
      "merging" -> tr(lang, "Merging", "合并中")
      "awaiting_pr" -> tr(lang, "Awaiting PR", "等待创建 PR")
      "human_review" -> tr(lang, "Human Review", "人工评审")
      "ready_for_merging" -> tr(lang, "Ready for Merging", "可进入 Merging")
      "ready_for_human_review" -> tr(lang, "Ready for Human Review", "可进入人工评审")
      "in_progress" -> tr(lang, "In progress", "处理中")
      _ -> tr(lang, "Unknown", "未知")
    end
  end

  defp delivery_route_detail(delivery, lang) do
    route = delivery_route(delivery)
    summary = blank_to_nil(field(route, "summary"))
    linear_state = blank_to_nil(field(route, "linear_state"))
    route_hint = blank_to_nil(field(route, "route_hint"))

    cond do
      summary && linear_state && route_hint ->
        tr(lang, "Linear: #{linear_state} | Route hint: #{route_hint} | #{summary}", "Linear：#{linear_state}｜路由提示：#{route_hint}｜#{summary}")

      summary && linear_state ->
        tr(lang, "Linear: #{linear_state} | #{summary}", "Linear：#{linear_state}｜#{summary}")

      summary ->
        summary

      true ->
        tr(lang, "No delivery route summary returned.", "当前没有返回交付路线摘要。")
    end
  end

  defp delivery_pr_label(delivery, lang) do
    pr = delivery_pull_request(delivery)
    number = field(pr, "number")

    case field(pr, "status") do
      "merged" -> pr_number_text(number, lang, tr(lang, "Merged PR", "已合并 PR"))
      "open" -> pr_number_text(number, lang, tr(lang, "Open PR", "已打开 PR"))
      "closed" -> pr_number_text(number, lang, tr(lang, "Closed PR", "已关闭 PR"))
      "unknown" -> tr(lang, "No PR linked", "当前没有关联 PR")
      _ -> tr(lang, "No PR linked", "当前没有关联 PR")
    end
  end

  defp delivery_pr_detail(delivery, lang) do
    pr = delivery_pull_request(delivery)
    title = blank_to_nil(field(pr, "title"))
    head_branch = blank_to_nil(field(pr, "head_branch"))
    base_branch = blank_to_nil(field(pr, "base_branch"))
    merge_sha = blank_to_nil(field(pr, "merge_commit_sha"))

    cond do
      title && head_branch && base_branch ->
        detail = tr(lang, "#{head_branch} -> #{base_branch} | #{title}", "#{head_branch} -> #{base_branch}｜#{title}")
        if merge_sha, do: detail <> tr(lang, " | Merge SHA: #{merge_sha}", "｜合并 SHA：#{merge_sha}"), else: detail

      head_branch && base_branch ->
        tr(lang, "#{head_branch} -> #{base_branch}", "#{head_branch} -> #{base_branch}")

      true ->
        tr(lang, "No pull request metadata returned yet.", "当前还没有返回 PR 元数据。")
    end
  end

  defp delivery_pr_url(delivery), do: blank_to_nil(field(delivery_pull_request(delivery), "url"))

  defp delivery_ci_label(delivery, lang) do
    ci = delivery_ci(delivery)

    case field(ci, "status") do
      "success" -> pipeline_text(ci, lang, tr(lang, "CI passed", "CI 已通过"))
      "passed" -> pipeline_text(ci, lang, tr(lang, "CI passed", "CI 已通过"))
      "running" -> pipeline_text(ci, lang, tr(lang, "CI running", "CI 运行中"))
      "pending" -> pipeline_text(ci, lang, tr(lang, "CI pending", "CI 待执行"))
      "failed" -> pipeline_text(ci, lang, tr(lang, "CI failed", "CI 失败"))
      "error" -> pipeline_text(ci, lang, tr(lang, "CI failed", "CI 失败"))
      "unknown" -> tr(lang, "CI unknown", "CI 未知")
      nil -> tr(lang, "CI unknown", "CI 未知")
      other -> tr(lang, "CI #{other}", "CI #{other}")
    end
  end

  defp delivery_ci_detail(delivery, lang) do
    ci = delivery_ci(delivery)
    summary = blank_to_nil(field(ci, "summary"))

    summary || tr(lang, "No Woodpecker summary returned yet.", "当前还没有返回 Woodpecker 摘要。")
  end

  defp delivery_ci_url(delivery), do: blank_to_nil(field(delivery_ci(delivery), "url"))

  defp delivery_automation_label(delivery, lang) do
    case field(delivery_automation(delivery), "status") do
      "healthy" -> tr(lang, "Healthy", "健康")
      "degraded" -> tr(lang, "Degraded", "异常")
      _ -> tr(lang, "Unknown", "未知")
    end
  end

  defp delivery_automation_detail(delivery, lang) do
    automation = delivery_automation(delivery)
    summary = blank_to_nil(field(automation, "summary"))
    last_success_at = blank_to_nil(field(automation, "last_success_at"))
    last_error = blank_to_nil(field(automation, "last_error"))

    cond do
      summary && last_success_at && last_error ->
        tr(lang, "#{summary} Last success: #{last_success_at} | Last error: #{last_error}", "#{summary} 最近成功：#{last_success_at}｜最近错误：#{last_error}")

      summary && last_success_at ->
        tr(lang, "#{summary} Last success: #{last_success_at}", "#{summary} 最近成功：#{last_success_at}")

      summary && last_error ->
        tr(lang, "#{summary} Last error: #{last_error}", "#{summary} 最近错误：#{last_error}")

      summary ->
        summary

      true ->
        tr(lang, "No merge automation summary returned.", "当前没有返回合并自动化摘要。")
    end
  end

  defp pr_number_text(number, _lang, prefix) when is_integer(number), do: "#{prefix} ##{number}"
  defp pr_number_text(number, _lang, prefix) when is_binary(number) and number != "", do: "#{prefix} ##{number}"
  defp pr_number_text(_number, _lang, prefix), do: prefix

  defp pipeline_text(ci, _lang, prefix) do
    case field(ci, "pipeline") do
      nil -> prefix
      pipeline -> "#{prefix} ##{pipeline}"
    end
  end

  defp operator_instruction(status) when is_map(status) do
    field(status, "latest_operator_instruction") || field(status, "pending_operator_instruction")
  end

  defp operator_instruction(_status), do: nil

  defp operator_instruction_label(status, lang) do
    case operator_instruction(status) do
      nil -> tr(lang, "None tracked", "当前没有跟踪中的指令")
      instruction -> instruction_state_text(instruction, lang)
    end
  end

  defp operator_instruction_detail(status, lang) do
    case operator_instruction(status) do
      nil ->
        tr(lang, "Append or steer a run to start tracking an operator instruction lifecycle.", "通过追加指令或引导运行，开始跟踪一条操作指令的生命周期。")

      instruction ->
        instruction_detail_text(instruction, lang)
    end
  end

  defp instruction_state_text(instruction, lang) when is_map(instruction) do
    case field(instruction, "delivery_state") do
      "queued" -> tr(lang, "Queued", "待下次重启应用")
      "restart_requested" -> tr(lang, "Restart requested", "已请求重启应用")
      "applied" -> tr(lang, "Applied", "已应用")
      "superseded" -> tr(lang, "Superseded", "已被替换")
      "cleared" -> tr(lang, "Cleared", "已清除")
      _ -> tr(lang, "Tracked", "已跟踪")
    end
  end

  defp instruction_state_text(_instruction, lang), do: tr(lang, "Tracked", "已跟踪")

  defp instruction_detail_text(instruction, lang) when is_map(instruction) do
    message = blank_to_nil(field(instruction, "message"))
    profile = blank_to_nil(field(instruction, "profile"))
    queued_at = blank_to_nil(field(instruction, "queued_at"))
    queued_via_action = pending_action_label(field(instruction, "queued_via_action"), lang)
    restart_requested_at = blank_to_nil(field(instruction, "restart_requested_at"))
    restart_requested_via_action = pending_action_label(field(instruction, "restart_requested_via_action"), lang)
    applied_at = blank_to_nil(field(instruction, "applied_at"))
    applied_via_scope = blank_to_nil(field(instruction, "applied_via_scope"))
    superseded_at = blank_to_nil(field(instruction, "superseded_at"))
    superseded_by_action = pending_action_label(field(instruction, "superseded_by_action"), lang)
    cleared_at = blank_to_nil(field(instruction, "cleared_at"))
    cleared_by_action = pending_action_label(field(instruction, "cleared_by_action"), lang)

    cond do
      message && applied_at && queued_via_action && applied_via_scope ->
        tr(
          lang,
          "Queued via #{queued_via_action} at #{queued_at || "unknown"} and applied at #{applied_at} when runtime entered #{applied_via_scope}: #{message}",
          "已通过 #{queued_via_action} 在 #{queued_at || "未知时间"} 排队，并于 #{applied_at} 在 runtime 进入 #{applied_via_scope} 时应用：#{message}"
        )

      message && restart_requested_at && restart_requested_via_action && queued_via_action ->
        tr(
          lang,
          "Queued via #{queued_via_action} at #{queued_at || "unknown"} and marked for restart via #{restart_requested_via_action} at #{restart_requested_at}: #{message}",
          "已通过 #{queued_via_action} 在 #{queued_at || "未知时间"} 排队，并于 #{restart_requested_at} 通过 #{restart_requested_via_action} 标记为重启应用：#{message}"
        )

      message && superseded_at && superseded_by_action && queued_via_action ->
        tr(
          lang,
          "Queued via #{queued_via_action} at #{queued_at || "unknown"} and superseded via #{superseded_by_action} at #{superseded_at}: #{message}",
          "已通过 #{queued_via_action} 在 #{queued_at || "未知时间"} 排队，并于 #{superseded_at} 通过 #{superseded_by_action} 被替换：#{message}"
        )

      message && cleared_at && cleared_by_action && queued_via_action ->
        tr(
          lang,
          "Queued via #{queued_via_action} at #{queued_at || "unknown"} and cleared via #{cleared_by_action} at #{cleared_at}: #{message}",
          "已通过 #{queued_via_action} 在 #{queued_at || "未知时间"} 排队，并于 #{cleared_at} 通过 #{cleared_by_action} 清除：#{message}"
        )

      message && profile && queued_via_action ->
        tr(
          lang,
          "Profile #{profile} queued via #{queued_via_action} at #{queued_at || "unknown"}: #{message}",
          "模板 #{profile} 已通过 #{queued_via_action} 在 #{queued_at || "未知时间"} 排队：#{message}"
        )

      message && queued_via_action ->
        tr(
          lang,
          "Queued via #{queued_via_action} at #{queued_at || "unknown"}: #{message}",
          "已通过 #{queued_via_action} 在 #{queued_at || "未知时间"} 排队：#{message}"
        )

      true ->
        tr(lang, "Append or steer a run to start tracking an operator instruction lifecycle.", "通过追加指令或引导运行，开始跟踪一条操作指令的生命周期。")
    end
  end

  defp instruction_detail_text(_instruction, lang),
    do: tr(lang, "Append or steer a run to start tracking an operator instruction lifecycle.", "通过追加指令或引导运行，开始跟踪一条操作指令的生命周期。")

  defp instruction_history(entries) when is_list(entries), do: entries
  defp instruction_history(_entries), do: []

  defp instruction_state_timestamp(instruction) when is_map(instruction) do
    blank_to_nil(field(instruction, "applied_at")) ||
      blank_to_nil(field(instruction, "restart_requested_at")) ||
      blank_to_nil(field(instruction, "superseded_at")) ||
      blank_to_nil(field(instruction, "cleared_at")) ||
      blank_to_nil(field(instruction, "queued_at"))
  end

  defp instruction_state_timestamp(_instruction), do: nil

  defp instruction_history_meta(instruction, lang) when is_map(instruction) do
    detail = instruction_detail_text(instruction, lang)
    if is_binary(detail), do: detail, else: tr(lang, "No instruction metadata returned.", "当前没有返回指令元数据。")
  end

  defp instruction_history_meta(_instruction, lang),
    do: tr(lang, "No instruction metadata returned.", "当前没有返回指令元数据。")

  defp pending_action_label("instruction", lang), do: tr(lang, "append", "追加指令")
  defp pending_action_label("clear_instruction", lang), do: tr(lang, "clear", "清除指令")
  defp pending_action_label("restart", lang), do: tr(lang, "restart", "重启运行")
  defp pending_action_label("steer", lang), do: tr(lang, "steer", "引导运行")
  defp pending_action_label(_action, _lang), do: nil

  defp action_disabled?(nil, _action), do: true

  defp action_disabled?(status, "pause") do
    field(field(status, "runtime_control"), "paused") in [true, "true"]
  end

  defp action_disabled?(status, "resume") do
    field(field(status, "runtime_control"), "paused") not in [true, "true"]
  end

  defp action_disabled?(status, "cancel") do
    runtime_scope(status) not in ["running", "retrying"]
  end

  defp action_disabled?(status, "hold") do
    field(field(status, "issue_control"), "held") in [true, "true"]
  end

  defp action_disabled?(status, "release") do
    field(field(status, "issue_control"), "held") not in [true, "true"]
  end

  defp action_disabled?(status, "clear_instruction") do
    is_nil(field(status, "pending_operator_instruction"))
  end

  defp action_disabled?(status, action) when action in ["restart", "instruction", "steer"] do
    is_nil(field(status, "issue"))
  end

  defp action_disabled?(_status, _action), do: false

  defp action_guidance(nil, lang),
    do: tr(lang, "Load an issue first. Runtime and issue controls stay disabled until a concrete issue is selected.", "先加载一个议题。未选中具体议题前，运行时和议题控制会保持禁用。")

  defp action_guidance(status, lang) do
    runtime_paused = field(field(status, "runtime_control"), "paused") in [true, "true"]
    issue_held = field(field(status, "issue_control"), "held") in [true, "true"]
    runtime_scope = runtime_scope(status)
    pending_instruction = field(status, "pending_operator_instruction")
    pending_message = blank_to_nil(field(pending_instruction, "message"))
    pending_state = blank_to_nil(field(pending_instruction, "delivery_state"))
    latest_instruction = operator_instruction(status)
    latest_state = blank_to_nil(field(latest_instruction, "delivery_state"))

    cond do
      latest_state == "applied" ->
        tr(lang, "The latest operator instruction has already been applied. Queue a new one only if direction changed again.", "最近一条操作指令已经应用。只有在方向再次变化时才需要再排队新的指令。")

      latest_state == "superseded" ->
        tr(lang, "The latest visible instruction record was superseded. Check the newer queued instruction before acting.", "当前显示的最近一条指令记录已经被替换。继续操作前先看更新后的待生效指令。")

      latest_state == "cleared" ->
        tr(lang, "The pending operator instruction was cleared. Append or steer again only if a new direction is needed.", "待生效指令已经清除。只有在需要新的方向时才再次追加或引导。")

      pending_message && pending_state == "restart_requested" ->
        tr(lang, "A queued operator instruction is already marked for the next restart path. Monitor the next run instead of re-sending it.", "当前已有一条待生效指令标记为通过下次重启应用。优先观察下一轮运行，而不是重复发送。")

      pending_message ->
        tr(lang, "A queued operator instruction is waiting for the next restart. Use Restart run or Steer run to apply it sooner.", "当前有一条待生效指令正在等待下次重启。要立即生效，请使用“重启运行”或“引导运行”。")

      runtime_paused ->
        tr(lang, "Runtime intake is paused. You can resume intake, hold/release the issue, or restart it for later dispatch.", "runtime intake 当前已暂停。你可以恢复 intake，也可以挂起/解除该议题，或安排它稍后重启。")

      issue_held ->
        tr(lang, "This issue is manually held. Release the hold before expecting redispatch.", "该议题目前处于手动挂起状态。若希望重新派发，先解除挂起。")

      runtime_scope == "running" ->
        tr(lang, "A live run is active. Cancel stops the current run, restart relaunches it, and steer appends guidance before restart.", "当前已有活跃运行。取消会终止当前运行，重启会重新拉起，\"引导运行\" 会先追加指令再重启。")

      runtime_scope == "retrying" ->
        tr(lang, "This issue is queued for retry. Cancel removes the queued retry; restart or steer will bring it back in immediately.", "该议题当前处于重试排队中。取消会移除当前重试，重启或引导运行会尝试立即把它拉回。")

      true ->
        tr(lang, "This issue is currently idle. Restart or steer can bring it back into intake immediately when runtime capacity allows.", "该议题当前处于空闲状态。在 runtime 容量允许时，重启或引导运行可以立即把它拉回 intake。")
    end
  end

  defp runtime_scope(status) when is_map(status) do
    field(field(status, "runtime_issue"), "scope")
  end

  defp runtime_scope(_status), do: nil

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

  defp load_runtime_payload do
    Presenter.state_payload(orchestrator(), snapshot_timeout_ms())
  end

  defp orchestrator do
    Endpoint.config(:orchestrator) || SymphonyElixir.Orchestrator
  end

  defp snapshot_timeout_ms do
    Endpoint.config(:snapshot_timeout_ms) || 15_000
  end

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

  defp normalize_blank_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_blank_text(value), do: blank_to_nil(value)

  defp parse_integer(nil, fallback), do: fallback

  defp parse_integer(value, fallback) do
    case Integer.parse(to_string(value)) do
      {parsed, _} when parsed in 1..50 -> parsed
      _ -> fallback
    end
  end

  defp present?(value), do: not is_nil(value) and value != "" and value != []

  defp format_int(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.reverse/1)
    |> String.reverse()
  end

  defp format_int(_value), do: "n/a"

  defp completed_runtime_seconds(payload) do
    field(field(payload, "codex_totals"), "seconds_running") || 0
  end

  defp total_runtime_seconds(payload, now) do
    completed_runtime_seconds(payload) +
      Enum.reduce(normalized_runtime_entries(field(payload, "running")), 0, fn entry, total ->
        total + runtime_seconds_from_started_at(field(entry, "started_at"), now)
      end)
  end

  defp format_runtime_and_turns(started_at, turn_count, now) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))} / #{turn_count}"
  end

  defp format_runtime_and_turns(started_at, _turn_count, now),
    do: format_runtime_seconds(runtime_seconds_from_started_at(started_at, now))

  defp format_runtime_seconds(seconds) when is_integer(seconds) and seconds >= 3600 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h #{minutes}m"
  end

  defp format_runtime_seconds(seconds) when is_integer(seconds) and seconds >= 60 do
    minutes = div(seconds, 60)
    remaining = rem(seconds, 60)
    "#{minutes}m #{remaining}s"
  end

  defp format_runtime_seconds(seconds) when is_integer(seconds) and seconds >= 0,
    do: "#{seconds}s"

  defp format_runtime_seconds(_seconds), do: "0s"

  defp runtime_seconds_from_started_at(nil, _now), do: 0

  defp runtime_seconds_from_started_at(started_at, now) do
    with {:ok, started_at_dt, _offset} <- DateTime.from_iso8601(to_string(started_at)) do
      max(DateTime.diff(now, started_at_dt, :second), 0)
    else
      _ -> 0
    end
  end

  defp schedule_refresh(0), do: :ok
  defp schedule_refresh(interval_ms), do: Process.send_after(self(), :refresh_tick, interval_ms)
  defp schedule_runtime_tick, do: Process.send_after(self(), :runtime_tick, @runtime_tick_ms)

  defp normalize_lang("en"), do: "en"
  defp normalize_lang("zh"), do: "zh"
  defp normalize_lang(_lang), do: @default_lang

  defp console_path(lang, adapter_id, profile_id) do
    query =
      %{}
      |> maybe_put_query("lang", lang)
      |> maybe_put_query("adapter", adapter_id)
      |> maybe_put_query("profile", profile_id)
      |> URI.encode_query()

    if query == "" do
      "/"
    else
      "/?" <> query
    end
  end

  defp maybe_put_query(query, _key, nil), do: query
  defp maybe_put_query(query, _key, ""), do: query
  defp maybe_put_query(query, key, value), do: Map.put(query, key, value)

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
