defmodule Reverb.Agent.Auth do
  @moduledoc """
  Owns the lifecycle of provider auth subprocesses for adapters that use an
  OAuth-style handshake (`claude setup-token`, etc.).

  A session is created with `start/1` which spawns the CLI via an Erlang Port,
  parses the OAuth URL from stdout, and holds the port open while the caller
  (Captain) displays the URL to the user. When the user pastes the returned
  code, the caller invokes `complete/2` which writes the code to the child's
  stdin and waits for the process to exit.

  Each in-flight session is identified by an opaque handle so the Captain
  LiveView can store it in socket assigns.
  """

  use GenServer
  require Logger

  @type handle :: String.t()
  @type provider :: :claude

  @claude_setup_token_command "claude"
  @claude_setup_token_args ["setup-token"]
  @default_session_timeout_ms 15 * 60 * 1000
  @url_regex ~r{https?://[^\s\"']+}
  @max_url_wait_ms 30_000

  defmodule Session do
    @moduledoc false
    defstruct [
      :handle,
      :provider,
      :port,
      :os_pid,
      :url,
      :waiters,
      :url_waiter,
      :output,
      :started_at,
      :expires_at,
      :completed?
    ]
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @doc """
  Start a new Claude auth session. Returns `{:ok, %{handle, url}}` once the
  child emits an OAuth URL, or `{:error, reason}` on failure.
  """
  @spec start(keyword()) :: {:ok, %{handle: handle(), url: String.t()}} | {:error, term()}
  def start(opts \\ []) do
    GenServer.call(__MODULE__, {:start, :claude, opts}, @max_url_wait_ms + 1_000)
  end

  @doc """
  Provide the OAuth code the user pasted back. Blocks until the child process
  confirms success or exits with a non-zero status.
  """
  @spec complete(handle(), String.t()) :: :ok | {:error, term()}
  def complete(handle, code) when is_binary(handle) and is_binary(code) do
    GenServer.call(__MODULE__, {:complete, handle, code}, 60_000)
  end

  @doc "Abort an in-flight auth session."
  @spec cancel(handle()) :: :ok
  def cancel(handle) when is_binary(handle) do
    GenServer.call(__MODULE__, {:cancel, handle})
  end

  @doc """
  Returns the current auth status for each known provider. Right now this only
  reports claude; opencode and others are reported as `:unknown` because their
  credential state lives in adapter-specific files we don't inspect yet.
  """
  @spec status() :: %{claude: :authed | :missing, opencode: :unknown}
  def status do
    %{
      claude: claude_status(),
      opencode: :unknown
    }
  end

  @impl true
  def init(_opts) do
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:start, :claude, opts}, from, state) do
    handle = generate_handle()
    command = Keyword.get(opts, :command, @claude_setup_token_command)
    args = Keyword.get(opts, :args, @claude_setup_token_args)

    case System.find_executable(command) do
      nil ->
        {:reply, {:error, {:command_not_found, command}}, state}

      path ->
        port =
          Port.open(
            {:spawn_executable, path},
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:line, 8192},
              {:args, args}
            ]
          )

        os_pid =
          case Port.info(port, :os_pid) do
            {:os_pid, pid} -> pid
            _ -> nil
          end

        now = System.monotonic_time(:millisecond)

        session = %Session{
          handle: handle,
          provider: :claude,
          port: port,
          os_pid: os_pid,
          url: nil,
          waiters: [],
          url_waiter: from,
          output: [],
          started_at: now,
          expires_at: now + @default_session_timeout_ms,
          completed?: false
        }

        # Hard timeout for URL discovery.
        Process.send_after(self(), {:url_timeout, handle}, @max_url_wait_ms)

        {:noreply, put_session(state, session)}
    end
  end

  def handle_call({:complete, handle, code}, from, state) do
    case state.sessions[handle] do
      nil ->
        {:reply, {:error, :unknown_handle}, state}

      %Session{completed?: true} ->
        {:reply, {:error, :already_completed}, state}

      %Session{port: port} = session ->
        # Claude CLI's setup-token prompt expects the code on a single line.
        _ = send_to_port(port, code <> "\n")
        session = %{session | waiters: [from | session.waiters], completed?: true}
        {:noreply, put_session(state, session)}
    end
  end

  def handle_call({:cancel, handle}, _from, state) do
    case state.sessions[handle] do
      nil ->
        {:reply, :ok, state}

      session ->
        safe_close_port(session.port)
        reply_to_waiters(session.waiters, {:error, :cancelled})
        maybe_reply_url(session, {:error, :cancelled})
        {:reply, :ok, %{state | sessions: Map.delete(state.sessions, handle)}}
    end
  end

  @impl true
  def handle_info({port, {:data, {_flag, line}}}, state) do
    case find_session_by_port(state, port) do
      nil ->
        {:noreply, state}

      {handle, session} ->
        session = %{session | output: [line | session.output]}
        text = IO.iodata_to_binary([line])

        session =
          case session.url do
            nil ->
              case extract_url(text) do
                nil ->
                  session

                url ->
                  maybe_reply_url(session, {:ok, %{handle: handle, url: url}})
                  %{session | url: url, url_waiter: nil}
              end

            _existing ->
              session
          end

        {:noreply, put_session(state, session)}
    end
  end

  def handle_info({port, {:exit_status, status}}, state) do
    case find_session_by_port(state, port) do
      nil ->
        {:noreply, state}

      {handle, session} ->
        reason = if status == 0, do: :ok, else: {:error, {:exit_status, status}}

        case reason do
          :ok ->
            # Credential was written by the CLI; refresh the adapter pool so
            # the scheduler picks up the new capability, then resume.
            safe_refresh_presence()
            safe_resume_scheduler()
            reply_to_waiters(session.waiters, :ok)
            maybe_reply_url(session, {:error, {:exit_status, status}})

          {:error, _} = err ->
            reply_to_waiters(session.waiters, err)
            maybe_reply_url(session, err)
        end

        {:noreply, %{state | sessions: Map.delete(state.sessions, handle)}}
    end
  end

  def handle_info({:url_timeout, handle}, state) do
    case state.sessions[handle] do
      %Session{url: nil} = session ->
        safe_close_port(session.port)
        maybe_reply_url(session, {:error, :url_not_emitted})
        reply_to_waiters(session.waiters, {:error, :url_not_emitted})
        {:noreply, %{state | sessions: Map.delete(state.sessions, handle)}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp put_session(state, session) do
    %{state | sessions: Map.put(state.sessions, session.handle, session)}
  end

  defp find_session_by_port(state, port) do
    Enum.find_value(state.sessions, fn {handle, session} ->
      if session.port == port, do: {handle, session}
    end)
  end

  defp extract_url(line) do
    case Regex.run(@url_regex, line) do
      [url | _] -> url
      _ -> nil
    end
  end

  defp send_to_port(port, data) do
    try do
      Port.command(port, data)
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  defp safe_close_port(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp reply_to_waiters(waiters, reply) do
    Enum.each(waiters, fn from -> GenServer.reply(from, reply) end)
  end

  defp maybe_reply_url(%Session{url_waiter: nil}, _reply), do: :ok

  defp maybe_reply_url(%Session{url_waiter: from}, reply) do
    GenServer.reply(from, reply)
  end

  defp generate_handle do
    16
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp safe_refresh_presence do
    if function_exported?(Reverb.Agent.Pool, :refresh_presence, 0) do
      Reverb.Agent.Pool.refresh_presence()
    end
  end

  defp safe_resume_scheduler do
    cond do
      function_exported?(Reverb, :resume, 0) ->
        try do
          Reverb.resume()
        rescue
          e ->
            Logger.warning("[Reverb.Auth] resume failed: #{Exception.message(e)}")
        end

      true ->
        :ok
    end
  end

  defp claude_status do
    cond do
      File.exists?(Path.expand("~/.claude/.credentials.json")) -> :authed
      File.exists?(Path.expand("~/.claude.json")) -> :authed
      true -> :missing
    end
  end
end
