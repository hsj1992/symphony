defmodule SymphonyElixirWeb.ConsoleLive do
  @moduledoc """
  Standalone adapter-backed console for project-local Symphony integrations.
  """

  use Phoenix.LiveView, layout: {SymphonyElixirWeb.Layouts, :app}

  @default_refresh_ms 15_000
  @refresh_options [
    {"Off", "off"},
    {"15s", "15000"},
    {"30s", "30000"},
    {"60s", "60000"}
  ]
  @log_options [
    {"No logs", "none"},
    {"Agent logs", "agent"},
    {"Raw logs", "raw"},
    {"All logs", "all"}
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
        {:noreply, put_flash(socket, :error, "Issue key is required")}

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
      {:noreply, put_flash(socket, :error, "Instruction cannot be empty")}
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
            <p class="eyebrow">Symphony Console</p>
            <h1 class="hero-title">Adapter Console</h1>
            <p class="hero-copy">
              Independent control plane for project-local Symphony adapters. Recent runs, issue detail, and control actions all flow through the adapter API, not the business frontend.
            </p>
          </div>

          <div class="status-stack">
            <span class="status-badge status-badge-live">
              <span class="status-badge-dot"></span>
              <%= adapter_label(@meta) %>
            </span>
            <span class="status-badge status-badge-offline">
              <span class="status-badge-dot"></span>
              <%= if @refresh_interval_ms > 0, do: "Auto #{div(@refresh_interval_ms, 1000)}s", else: "Manual refresh" %>
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
          <h2 class="error-title">Adapter unavailable</h2>
          <p class="error-copy"><%= @error_message %></p>
        </section>
      <% end %>

      <section class="section-card">
        <div class="section-header">
          <div>
            <h2 class="section-title">Controls</h2>
            <p class="section-copy">Load an issue from the adapter, tune refresh, and include doctor/workpad/log data on demand.</p>
          </div>
          <button type="button" class="subtle-button" phx-click="refresh">Refresh now</button>
        </div>

        <form id="issue-query-form" class="toolbar-form" phx-submit="load_issue">
          <label class="toolbar-field">
            <span>Issue</span>
            <input class="form-input" type="text" name="issue" value={@issue_query} placeholder="CNS-123" />
          </label>

          <label class="toolbar-field">
            <span>Branch override</span>
            <input class="form-input" type="text" name="branch" value={@branch_override} placeholder="optional" />
          </label>

          <label class="toolbar-field">
            <span>Events</span>
            <input class="form-input" type="number" min="1" max="50" name="events" value={@events_limit} />
          </label>

          <label class="toolbar-field">
            <span>Logs</span>
            <select class="form-input" name="include_logs">
              <option :for={{label, value} <- @log_options} value={value} selected={value == @include_logs}>
                <%= label %>
              </option>
            </select>
          </label>

          <label class="toolbar-field">
            <span>Auto refresh</span>
            <select class="form-input" name="refresh_interval" phx-change="set_refresh_interval">
              <option :for={{label, value} <- @refresh_options} value={value} selected={refresh_selected?(value, @refresh_interval_ms)}>
                <%= label %>
              </option>
            </select>
          </label>

          <label class="checkbox-field">
            <input type="checkbox" name="doctor" value="true" checked={@include_doctor} />
            <span>Include doctor</span>
          </label>

          <label class="checkbox-field">
            <input type="checkbox" name="workpad" value="true" checked={@include_workpad} />
            <span>Include workpad</span>
          </label>

          <button type="submit" class="subtle-button subtle-button-primary">Load issue</button>
        </form>
      </section>

      <div class="console-grid">
        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Recent runs</h2>
              <p class="section-copy">Project-local adapter state from `/runs`.</p>
            </div>
          </div>

          <%= if @runs == [] do %>
            <p class="empty-state">No recent runs returned by the adapter.</p>
          <% else %>
            <div class="table-wrap">
              <table class="data-table">
                <thead>
                  <tr>
                    <th>Issue</th>
                    <th>Phase</th>
                    <th>Route</th>
                    <th>Updated</th>
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
                    <td><span class={state_badge_class(field(run, "phase"))}><%= field(run, "phase") || "n/a" %></span></td>
                    <td><%= field(run, "route_hint") || "n/a" %></td>
                    <td class="mono"><%= field(run, "updated_at") || "n/a" %></td>
                  </tr>
                </tbody>
              </table>
            </div>
          <% end %>
        </section>

        <section class="section-card">
          <div class="section-header">
            <div>
              <h2 class="section-title">Run detail</h2>
              <p class="section-copy">Loaded from `/status` for the selected issue.</p>
            </div>
          </div>

          <%= if is_nil(@status) do %>
            <p class="empty-state">Load an issue to inspect current status, checks, and actions.</p>
          <% else %>
            <div class="detail-grid">
              <article class="metric-card">
                <p class="metric-label">Issue</p>
                <p class="metric-value"><%= field(@status, "issue") %></p>
                <p class="metric-detail"><%= field(@status, "summary") || "n/a" %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label">Phase</p>
                <p class="metric-value"><%= field(@status, "phase") || "n/a" %></p>
                <p class="metric-detail">Route hint: <%= field(@status, "route_hint") || "n/a" %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label">Branch / commit</p>
                <p class="metric-value mono"><%= field(@status, "branch") || "n/a" %></p>
                <p class="metric-detail mono"><%= field(@status, "commit") || "n/a" %></p>
              </article>

              <article class="metric-card">
                <p class="metric-label">Next</p>
                <p class="metric-value"><%= field(@status, "next") || "n/a" %></p>
                <p class="metric-detail">Updated: <span class="mono"><%= field(@status, "updated_at") || "n/a" %></span></p>
              </article>
            </div>

            <div class="section-stack">
              <section>
                <h3 class="section-subtitle">Checks</h3>
                <div class="table-wrap">
                  <table class="data-table">
                    <thead>
                      <tr>
                        <th>Check</th>
                        <th>Status</th>
                        <th>Summary</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={{name, payload} <- normalized_checks(field(@status, "checks"))}>
                        <td><%= name %></td>
                        <td><span class={state_badge_class(field(payload, "status"))}><%= field(payload, "status") || "n/a" %></span></td>
                        <td><%= field(payload, "summary") || "n/a" %></td>
                      </tr>
                    </tbody>
                  </table>
                </div>
              </section>

              <section>
                <h3 class="section-subtitle">Latest events</h3>
                <%= if normalized_events(field(@status, "latest_events")) == [] do %>
                  <p class="empty-state">No events returned.</p>
                <% else %>
                  <div class="table-wrap">
                    <table class="data-table">
                      <thead>
                        <tr>
                          <th>Time</th>
                          <th>Type</th>
                          <th>Summary</th>
                        </tr>
                      </thead>
                      <tbody>
                        <tr :for={event <- normalized_events(field(@status, "latest_events"))}>
                          <td class="mono"><%= field(event, "ts") || "n/a" %></td>
                          <td><%= field(event, "type") || "n/a" %></td>
                          <td><%= field(event, "summary") || "n/a" %></td>
                        </tr>
                      </tbody>
                    </table>
                  </div>
                <% end %>
              </section>

              <section>
                <h3 class="section-subtitle">Actions</h3>
                <div class="action-row">
                  <button id="pause-run" type="button" class="subtle-button" phx-click="pause">Pause</button>
                  <button id="resume-run" type="button" class="subtle-button" phx-click="resume">Continue</button>
                </div>

                <form id="instruction-form" class="instruction-form" phx-submit="append_instruction">
                  <label class="toolbar-field toolbar-field-full">
                    <span>Append instruction</span>
                    <textarea
                      class="form-input form-textarea"
                      name="message"
                      placeholder="Add a new instruction for this run"
                    ><%= @instruction_message %></textarea>
                  </label>

                  <label class="checkbox-field">
                    <input type="checkbox" name="sync_linear" value="true" checked={@sync_linear} />
                    <span>Sync to Linear</span>
                  </label>

                  <button type="submit" class="subtle-button subtle-button-primary">Append instruction</button>
                </form>
              </section>

              <section :if={present?(field(@status, "doctor"))}>
                <h3 class="section-subtitle">Doctor</h3>
                <pre class="code-panel"><%= inspect(field(@status, "doctor"), pretty: true, limit: :infinity) %></pre>
              </section>

              <section :if={present?(field(@status, "workpad"))}>
                <h3 class="section-subtitle">Workpad</h3>
                <pre class="code-panel"><%= inspect(field(@status, "workpad"), pretty: true, limit: :infinity) %></pre>
              </section>

              <section :if={present?(field(@status, "logs"))}>
                <h3 class="section-subtitle">Logs</h3>
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
    put_flash(socket, :error, "Load an issue before triggering actions")
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

  defp adapter_label(nil), do: "Adapter"
  defp adapter_label(meta), do: field(meta, "repo_name") || field(meta, "repo_key") || "Adapter"

  defp refresh_selected?(value, refresh_interval_ms) do
    selected =
      if refresh_interval_ms > 0 do
        Integer.to_string(refresh_interval_ms)
      else
        "off"
      end

    value == selected
  end

  defp action_success_message("pause"), do: "Pause recorded"
  defp action_success_message("resume"), do: "Continue recorded"
  defp action_success_message("instruction"), do: "Instruction appended"
  defp action_success_message(_action), do: "Action recorded"

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
    do: "Set SYMPHONY_CONSOLE_ADAPTER_BASE_URL and SYMPHONY_CONSOLE_ADAPTER_TOKEN before using the adapter console."

  defp error_message({:http_error, status, body}),
    do: "Adapter request failed with HTTP #{status}: #{inspect(body)}"

  defp error_message(reason), do: "Adapter request failed: #{inspect(reason)}"

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
