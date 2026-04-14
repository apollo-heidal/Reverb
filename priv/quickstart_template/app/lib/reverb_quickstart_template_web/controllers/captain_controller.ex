defmodule ReverbQuickstartTemplateWeb.CaptainController do
  use ReverbQuickstartTemplateWeb, :controller

  alias ReverbQuickstartTemplate.Captain

  plug :require_admin

  @running_states ["claimed", "running", "validating", "awaiting_approval"]
  @queued_states ["pending", "failed"]
  @finished_states ["stable", "shelved", "cancelled"]

  def index(conn, _params) do
    if Captain.any_provider_authed?() do
      {tasks, fetch_error} =
        case Captain.list_tasks() do
          {:ok, tasks} -> {tasks, nil}
          {:error, reason} -> {[], reason}
        end

      html(conn, index_html(conn, tasks, fetch_error))
    else
      conn
      |> put_flash(
        :info,
        "Authenticate a provider to let Reverb start steering your app."
      )
      |> redirect(to: ~p"/captain/providers")
    end
  end

  def create(conn, %{"captain" => %{"prompt" => prompt}}) do
    case Captain.submit(prompt) do
      :ok ->
        conn
        |> put_flash(:info, "Captain request queued. Reverb will pick it up before automated tasks.")
        |> redirect(to: ~p"/captain")

      {:error, :blank} ->
        conn
        |> put_flash(:error, "Write one concrete request before sending it to Captain.")
        |> redirect(to: ~p"/captain")
    end
  end

  defp require_admin(conn, _opts) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        conn
        |> put_flash(:error, "Sign in as the quickstart admin user to access Captain.")
        |> redirect(to: "/sign-in")
        |> halt()

      Captain.admin?(user) ->
        conn

      true ->
        conn
        |> put_flash(:error, "Captain is restricted to the configured quickstart admin account.")
        |> redirect(to: "/")
        |> halt()
    end
  end

  defp index_html(conn, tasks, fetch_error) do
    project_name = Captain.project_name() |> escape_html()
    running = Enum.filter(tasks, &(&1["state"] in @running_states))
    queued = Enum.filter(tasks, &(&1["state"] in @queued_states))
    finished = Enum.filter(tasks, &(&1["state"] in @finished_states)) |> Enum.take(8)

    info_flash = get_flash(conn, :info)
    error_flash = get_flash(conn, :error)
    fetch_error_html = if fetch_error, do: flash_block(fetch_error, :error), else: ""

    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Captain | #{project_name}</title>
        <style>
          :root { color-scheme: dark; }
          body {
            margin: 0;
            font-family: Inter, ui-sans-serif, system-ui, sans-serif;
            background: #020617;
            color: #e2e8f0;
          }
          main {
            max-width: 1100px;
            margin: 0 auto;
            padding: 28px 20px 72px;
          }
          .topbar {
            display: flex;
            align-items: center;
            justify-content: space-between;
            gap: 16px;
            flex-wrap: wrap;
            margin-bottom: 24px;
          }
          .title h1 { margin: 0; font-size: clamp(2rem, 5vw, 3rem); }
          .title p { margin: 8px 0 0; color: #94a3b8; }
          .nav { display: flex; gap: 12px; flex-wrap: wrap; }
          .nav a {
            color: #e2e8f0; text-decoration: none; padding: 10px 14px; border-radius: 12px;
            background: rgba(15, 23, 42, 0.8); border: 1px solid rgba(148, 163, 184, 0.18);
          }
          .panel {
            border: 1px solid rgba(148, 163, 184, 0.18); background: rgba(15, 23, 42, 0.84);
            border-radius: 20px; padding: 20px; box-shadow: 0 24px 80px rgba(2, 6, 23, 0.36);
          }
          .composer textarea {
            width: 100%; min-height: 168px; resize: vertical; border-radius: 16px;
            border: 1px solid rgba(148, 163, 184, 0.22); background: #0f172a; color: #e2e8f0;
            padding: 16px; font: inherit; box-sizing: border-box;
          }
          .composer-footer {
            margin-top: 14px; display: flex; gap: 14px; justify-content: space-between;
            align-items: center; flex-wrap: wrap;
          }
          .composer-note { color: #94a3b8; font-size: 0.95rem; max-width: 720px; }
          button {
            border: 0; border-radius: 14px; padding: 13px 18px; font: inherit; font-weight: 700;
            cursor: pointer; background: linear-gradient(135deg, #22c55e, #38bdf8); color: #020617;
          }
          .flash { margin: 14px 0; padding: 14px 16px; border-radius: 14px; }
          .flash-info { background: rgba(56, 189, 248, 0.14); color: #bae6fd; }
          .flash-error { background: rgba(248, 113, 113, 0.14); color: #fecaca; }
          .stats {
            margin-top: 20px; display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
          }
          .stat {
            padding: 18px; border-radius: 18px; background: rgba(15, 23, 42, 0.72);
            border: 1px solid rgba(148, 163, 184, 0.16);
          }
          .stat strong { display: block; font-size: 1.8rem; margin-bottom: 6px; }
          .columns {
            margin-top: 22px; display: grid; gap: 18px; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
          }
          .column h2 {
            margin-top: 0; margin-bottom: 12px; font-size: 1rem; letter-spacing: 0.04em;
            text-transform: uppercase; color: #cbd5e1;
          }
          .task-list { display: grid; gap: 12px; }
          .task {
            border-radius: 16px; padding: 14px; background: rgba(2, 6, 23, 0.72);
            border: 1px solid rgba(148, 163, 184, 0.14);
          }
          .task-top {
            display: flex; justify-content: space-between; align-items: center; gap: 12px; margin-bottom: 10px;
          }
          .pill {
            border-radius: 999px; padding: 5px 10px; font-size: 0.78rem;
            background: rgba(59, 130, 246, 0.16); color: #bfdbfe;
          }
          .task p { margin: 0; line-height: 1.55; color: #e2e8f0; }
          .meta { margin-top: 10px; color: #94a3b8; font-size: 0.92rem; }
          .empty { color: #94a3b8; font-style: italic; }
        </style>
      </head>
      <body>
        <main>
          <div class="topbar">
            <div class="title">
              <h1>Captain Console</h1>
              <p>#{project_name} ships changes from here. Captain is the single entrypoint for provider auth and for steering the app.</p>
            </div>
            <nav class="nav">
              <a href="/">Homepage</a>
              <a href="/captain/providers">Providers</a>
            </nav>
          </div>

          #{flash_block(info_flash, :info)}
          #{flash_block(error_flash, :error)}
          #{fetch_error_html}

          <section class="panel composer">
            <form action="/captain" method="post">
              <input type="hidden" name="_csrf_token" value="#{Plug.CSRFProtection.get_csrf_token() |> escape_html()}" />
              <textarea name="captain[prompt]" placeholder="Describe one concrete change you want to see in the app."></textarea>
              <div class="composer-footer">
                <div class="composer-note">
                  Keep requests small and concrete. Manage provider credentials at <a href="/captain/providers" style="color:#bae6fd;">/captain/providers</a>.
                </div>
                <button type="submit">Queue Captain Task</button>
              </div>
            </form>
          </section>

          <section class="stats">
            <div class="stat"><strong>#{length(running)}</strong>Active captain tasks</div>
            <div class="stat"><strong>#{length(queued)}</strong>Queued captain tasks</div>
            <div class="stat"><strong>#{length(finished)}</strong>Recent finished captain tasks</div>
          </section>

          <section class="columns">
            <div class="column panel">
              <h2>Active</h2>
              <div class="task-list">#{render_task_list(running, "No captain task is actively running right now.")}</div>
            </div>
            <div class="column panel">
              <h2>Queued</h2>
              <div class="task-list">#{render_task_list(queued, "No queued captain tasks yet.")}</div>
            </div>
            <div class="column panel">
              <h2>Recent Finished</h2>
              <div class="task-list">#{render_task_list(finished, "Finished captain tasks will show up here.")}</div>
            </div>
          </section>
        </main>
      </body>
    </html>
    """
  end

  defp render_task_list([], empty_message) do
    ~s(<div class="empty">#{escape_html(empty_message)}</div>)
  end

  defp render_task_list(tasks, _empty_message) do
    Enum.map_join(tasks, "", &render_task/1)
  end

  defp render_task(task) do
    body = task["body"] || "Untitled captain task"
    state = task["state"] || "pending"
    status = task["status"] || "todo"
    note = task["done_note"] || task["last_error"] || ""

    """
    <article class="task">
      <div class="task-top">
        <span class="pill">#{escape_html(state)}</span>
        <span class="meta">status: #{escape_html(status)}</span>
      </div>
      <p>#{escape_html(body)}</p>
      #{render_note(note)}
    </article>
    """
  end

  defp render_note(""), do: ""

  defp render_note(note) do
    ~s(<div class="meta">#{escape_html(note)}</div>)
  end

  defp flash_block(nil, _kind), do: ""
  defp flash_block("", _kind), do: ""

  defp flash_block(message, :info) do
    ~s(<div class="flash flash-info">#{escape_html(message)}</div>)
  end

  defp flash_block(message, :error) do
    ~s(<div class="flash flash-error">#{escape_html(message)}</div>)
  end

  defp escape_html(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
