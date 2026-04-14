defmodule ReverbQuickstartTemplateWeb.CaptainProvidersController do
  use ReverbQuickstartTemplateWeb, :controller

  alias ReverbQuickstartTemplate.Captain

  plug :require_admin

  def index(conn, _params) do
    payload =
      case Captain.auth_status() do
        {:ok, map} -> map
        {:error, _} -> %{}
      end

    pending = get_session(conn, :claude_auth_pending)

    html(conn, index_html(conn, payload, pending))
  end

  def probe_claude(conn, _params) do
    case Captain.claude_auth_probe() do
      {:ok, _} ->
        conn
        |> put_flash(:info, "Claude probe succeeded. The stored credential is live.")
        |> redirect(to: ~p"/captain/providers")

      {:error, message} ->
        conn
        |> put_flash(:error, "Claude probe failed: #{message}")
        |> redirect(to: ~p"/captain/providers")
    end
  end

  def start_claude(conn, _params) do
    case Captain.claude_auth_start() do
      {:ok, %{"handle" => handle, "url" => url}} ->
        conn
        |> put_session(:claude_auth_pending, %{"handle" => handle, "url" => url})
        |> redirect(to: ~p"/captain/providers")

      {:error, message} ->
        conn
        |> put_flash(:error, "Could not start Claude auth: #{message}")
        |> redirect(to: ~p"/captain/providers")
    end
  end

  def complete_claude(conn, %{"claude" => %{"code" => code}}) do
    case get_session(conn, :claude_auth_pending) do
      %{"handle" => handle} ->
        case Captain.claude_auth_complete(handle, String.trim(code)) do
          {:ok, _} ->
            conn
            |> delete_session(:claude_auth_pending)
            |> put_flash(:info, "Claude authenticated. Reverb is now steering.")
            |> redirect(to: ~p"/captain")

          {:error, message} ->
            conn
            |> put_flash(:error, "Claude auth failed: #{message}")
            |> redirect(to: ~p"/captain/providers")
        end

      _ ->
        conn
        |> put_flash(:error, "No pending Claude auth session. Start a new one.")
        |> redirect(to: ~p"/captain/providers")
    end
  end

  def cancel_claude(conn, _params) do
    case get_session(conn, :claude_auth_pending) do
      %{"handle" => handle} -> Captain.claude_auth_cancel(handle)
      _ -> :ok
    end

    conn
    |> delete_session(:claude_auth_pending)
    |> put_flash(:info, "Cancelled pending Claude auth.")
    |> redirect(to: ~p"/captain/providers")
  end

  defp require_admin(conn, _opts) do
    user = conn.assigns[:current_user]

    cond do
      is_nil(user) ->
        conn
        |> put_session(:return_to, current_path(conn))
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

  defp index_html(conn, payload, pending) do
    project_name = Captain.project_name() |> escape_html()
    providers = Map.get(payload, "providers", %{})
    errors = Map.get(payload, "errors", %{})
    last_probe = Map.get(payload, "last_probe", %{})
    claude_status = Map.get(providers, "claude", "unknown")
    opencode_status = Map.get(providers, "opencode", "unknown")
    claude_error = Map.get(errors, "claude")
    claude_probe = Map.get(last_probe, "claude")

    info_flash = get_flash(conn, :info)
    error_flash = get_flash(conn, :error)
    csrf = Plug.CSRFProtection.get_csrf_token() |> escape_html()

    """
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>Providers | #{project_name}</title>
        <style>
          :root { color-scheme: dark; }
          body { margin: 0; font-family: Inter, ui-sans-serif, system-ui, sans-serif; background: #020617; color: #e2e8f0; }
          main { max-width: 900px; margin: 0 auto; padding: 28px 20px 72px; }
          h1 { margin: 0 0 12px; font-size: clamp(1.8rem, 4vw, 2.6rem); }
          .subtitle { color: #94a3b8; margin: 0 0 24px; }
          .panel {
            border: 1px solid rgba(148, 163, 184, 0.18); background: rgba(15, 23, 42, 0.84);
            border-radius: 20px; padding: 22px; margin-bottom: 18px;
            box-shadow: 0 24px 80px rgba(2, 6, 23, 0.36);
          }
          .row { display: flex; justify-content: space-between; align-items: center; gap: 16px; flex-wrap: wrap; }
          .pill { border-radius: 999px; padding: 5px 12px; font-size: 0.85rem; }
          .pill-authed { background: rgba(34, 197, 94, 0.18); color: #bbf7d0; }
          .pill-missing { background: rgba(248, 113, 113, 0.18); color: #fecaca; }
          .pill-expired { background: rgba(250, 204, 21, 0.18); color: #fde68a; }
          .pill-invalid { background: rgba(249, 115, 22, 0.18); color: #fed7aa; }
          .pill-failing { background: rgba(239, 68, 68, 0.24); color: #fecaca; }
          .pill-unknown { background: rgba(148, 163, 184, 0.18); color: #e2e8f0; }
          .error-note { margin-top: 10px; padding: 10px 14px; border-radius: 12px;
            background: rgba(239, 68, 68, 0.12); color: #fecaca; font-size: 0.92rem; word-break: break-word; }
          .probe-note { margin-top: 10px; padding: 10px 14px; border-radius: 12px;
            background: rgba(148, 163, 184, 0.12); color: #cbd5e1; font-size: 0.9rem; }
          button, .btn {
            border: 0; border-radius: 14px; padding: 11px 16px; font: inherit; font-weight: 700;
            cursor: pointer; background: linear-gradient(135deg, #22c55e, #38bdf8); color: #020617;
            text-decoration: none; display: inline-block;
          }
          .btn-secondary {
            background: rgba(148, 163, 184, 0.18); color: #e2e8f0;
          }
          .flash { margin: 10px 0 18px; padding: 14px 16px; border-radius: 14px; }
          .flash-info { background: rgba(56, 189, 248, 0.14); color: #bae6fd; }
          .flash-error { background: rgba(248, 113, 113, 0.14); color: #fecaca; }
          code, .url-box {
            display: block; padding: 12px 14px; border-radius: 12px;
            background: #0f172a; color: #bae6fd; word-break: break-all; font-family: ui-monospace, monospace;
          }
          input[type="text"] {
            width: 100%; padding: 12px 14px; border-radius: 12px; border: 1px solid rgba(148, 163, 184, 0.22);
            background: #0f172a; color: #e2e8f0; font: inherit; box-sizing: border-box;
          }
          nav a { color: #cbd5e1; text-decoration: none; }
          .step { color: #94a3b8; font-size: 0.95rem; margin: 8px 0 14px; }
        </style>
      </head>
      <body>
        <main>
          <nav style="margin-bottom: 14px;"><a href="/captain">&larr; Captain</a></nav>
          <h1>Providers</h1>
          <p class="subtitle">#{project_name} talks to the Reverb agent through a CLI provider. Claude is the default; OpenCode remains available as a fallback. Authenticate below to let Reverb start coding.</p>

          #{flash_block(info_flash, :info)}
          #{flash_block(error_flash, :error)}

          <section class="panel">
            <div class="row">
              <div>
                <strong>Claude Code CLI</strong>
                <div class="step">Anthropic's Claude CLI — the default agent adapter.</div>
              </div>
              <span class="pill #{status_class(claude_status)}">#{escape_html(to_string(claude_status))}</span>
            </div>
            #{render_claude_error(claude_error, claude_status)}
            #{render_claude_section(pending, claude_status, csrf)}
            #{render_probe_section(claude_status, claude_probe, csrf)}
          </section>

          <section class="panel">
            <div class="row">
              <div>
                <strong>OpenCode</strong>
                <div class="step">Configurable fallback adapter. Credentials are managed inside the reverb container when enabled.</div>
              </div>
              <span class="pill #{status_class(opencode_status)}">#{escape_html(to_string(opencode_status))}</span>
            </div>
          </section>
        </main>
      </body>
    </html>
    """
  end

  defp render_claude_error(nil, _status), do: ""

  defp render_claude_error(message, status) when status in ["failing", :failing] do
    ~s(<div class="error-note"><strong>Claude auth is failing.</strong> Last live error:<br/>#{escape_html(message)}</div>)
  end

  defp render_claude_error(_message, _status), do: ""

  defp render_probe_section(status, probe, csrf) when status in ["authed", :authed, "failing", :failing] do
    """
    <form action="/captain/providers/claude/probe" method="post" style="margin-top: 14px;">
      <input type="hidden" name="_csrf_token" value="#{csrf}" />
      <button type="submit" class="btn-secondary btn">Verify connection</button>
    </form>
    #{render_probe_result(probe)}
    """
  end

  defp render_probe_section(_status, _probe, _csrf), do: ""

  defp render_probe_result(nil), do: ""

  defp render_probe_result(%{"result" => "ok", "at" => at}) do
    ~s(<div class="probe-note">Last live probe succeeded at #{escape_html(at)}.</div>)
  end

  defp render_probe_result(%{"result" => result, "at" => at, "message" => message}) do
    reason = if is_binary(result), do: result, else: inspect(result)
    detail = if is_binary(message) and message != "", do: ": " <> escape_html(message), else: ""
    ~s(<div class="probe-note">Last live probe failed at #{escape_html(at)} (#{escape_html(reason)})#{detail}</div>)
  end

  defp render_probe_result(_), do: ""

  defp render_claude_section(nil, "authed", _csrf) do
    """
    <p class="step">Claude is authenticated. You can return to <a href="/captain">Captain</a>.</p>
    """
  end

  defp render_claude_section(nil, "failing", csrf) do
    """
    <p class="step" style="color: #fecaca;">Re-authenticate or verify the stored credential below.</p>
    <form action="/captain/providers/claude/start" method="post">
      <input type="hidden" name="_csrf_token" value="#{csrf}" />
      <button type="submit">Re-authenticate Claude</button>
    </form>
    """
  end

  defp render_claude_section(nil, status, csrf) when status in ["expired", "invalid"] do
    reason =
      case status do
        "expired" -> "The stored Claude token has expired."
        "invalid" -> "The Claude credentials file is unreadable or missing required fields."
      end

    """
    <p class="step" style="color: #fde68a;">#{reason} Re-authenticate to refresh it.</p>
    <form action="/captain/providers/claude/start" method="post">
      <input type="hidden" name="_csrf_token" value="#{csrf}" />
      <button type="submit">Re-authenticate Claude</button>
    </form>
    <p class="step">This runs <code>claude setup-token</code> inside the reverb container and overwrites the stored credential.</p>
    """
  end

  defp render_claude_section(nil, _status, csrf) do
    """
    <form action="/captain/providers/claude/start" method="post">
      <input type="hidden" name="_csrf_token" value="#{csrf}" />
      <button type="submit">Authenticate Claude</button>
    </form>
    <p class="step">Clicking this runs <code>claude setup-token</code> inside the reverb container. We'll show you the OAuth URL next.</p>
    """
  end

  defp render_claude_section(%{"handle" => _handle, "url" => url}, _status, csrf) do
    """
    <p class="step">1. Open this URL in your browser, approve access, and copy the code it gives you back here:</p>
    <div class="url-box">#{escape_html(url)}</div>
    <p class="step">2. Paste the code below:</p>
    <form action="/captain/providers/claude/complete" method="post" style="display: grid; gap: 12px; margin-top: 12px;">
      <input type="hidden" name="_csrf_token" value="#{csrf}" />
      <input type="text" name="claude[code]" placeholder="Paste the code from your browser" autocomplete="off" />
      <div class="row">
        <button type="submit">Complete Authentication</button>
        <a href="/captain/providers/claude/cancel" onclick="event.preventDefault(); document.getElementById('cancel-claude').submit();" class="btn btn-secondary">Cancel</a>
      </div>
    </form>
    <form id="cancel-claude" action="/captain/providers/claude/cancel" method="post" style="display: none;">
      <input type="hidden" name="_csrf_token" value="#{csrf}" />
    </form>
    """
  end

  defp status_class("authed"), do: "pill-authed"
  defp status_class(:authed), do: "pill-authed"
  defp status_class("missing"), do: "pill-missing"
  defp status_class(:missing), do: "pill-missing"
  defp status_class("expired"), do: "pill-expired"
  defp status_class(:expired), do: "pill-expired"
  defp status_class("invalid"), do: "pill-invalid"
  defp status_class(:invalid), do: "pill-invalid"
  defp status_class("failing"), do: "pill-failing"
  defp status_class(:failing), do: "pill-failing"
  defp status_class(_), do: "pill-unknown"

  defp flash_block(nil, _kind), do: ""
  defp flash_block("", _kind), do: ""
  defp flash_block(message, :info), do: ~s(<div class="flash flash-info">#{escape_html(message)}</div>)
  defp flash_block(message, :error), do: ~s(<div class="flash flash-error">#{escape_html(message)}</div>)

  defp escape_html(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
