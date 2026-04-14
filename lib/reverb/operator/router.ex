defmodule Reverb.Operator.Router do
  @moduledoc """
  Minimal operator HTTP surface for health checks and scheduler control.
  """

  use Plug.Router

  plug Plug.Parsers, parsers: [:json], pass: ["application/json"], json_decoder: Jason
  plug :match
  plug :dispatch

  get "/health" do
    send_json(conn, 200, %{ok: true, mode: Application.get_env(:reverb, :mode, :disabled)})
  end

  get "/api/status" do
    send_json(conn, 200, %{status: Reverb.status(), runtime: Reverb.Runtime.snapshot()})
  end

  get "/api/tasks" do
    opts = keyword_params(conn.params, [:limit, :since_minutes, :status, :state, :source_kind])
    send_json(conn, 200, %{tasks: Reverb.tasks(opts)})
  end

  post "/api/tasks/manual" do
    with %{"body" => body} when is_binary(body) <- conn.body_params,
         attrs <- %{
           body: body,
           source_kind: "captain",
           category: "manual",
           metadata: Map.get(conn.body_params, "metadata", %{})
         },
         {:ok, task} <- Reverb.create_manual_task(attrs) do
      send_json(conn, 201, %{task: task})
    else
      %{} ->
        send_json(conn, 422, %{error: "body is required"})

      {:error, error} ->
        send_json(conn, 422, %{error: inspect(error)})
    end
  end

  get "/api/runs" do
    opts = keyword_params(conn.params, [:limit, :task_id, :status])
    send_json(conn, 200, %{runs: Reverb.runs(opts)})
  end

  post "/api/scheduler/pause" do
    send_json(conn, 200, %{result: Reverb.pause()})
  end

  post "/api/scheduler/resume" do
    send_json(conn, 200, %{result: Reverb.resume()})
  end

  get "/api/agent/pool" do
    send_json(conn, 200, %{pool: Reverb.Agent.Pool.status()})
  end

  get "/api/agent/auth/status" do
    send_json(conn, 200, %{providers: Reverb.Agent.Auth.status()})
  end

  post "/api/agent/auth/claude/start" do
    case Reverb.Agent.Auth.start() do
      {:ok, %{handle: handle, url: url}} ->
        send_json(conn, 200, %{handle: handle, url: url})

      {:error, reason} ->
        send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/api/agent/auth/claude/complete" do
    with %{"handle" => handle, "code" => code} when is_binary(handle) and is_binary(code) <-
           conn.body_params,
         :ok <- Reverb.Agent.Auth.complete(handle, String.trim(code)) do
      send_json(conn, 200, %{result: "ok"})
    else
      %{} ->
        send_json(conn, 422, %{error: "handle and code are required"})

      {:error, reason} ->
        send_json(conn, 422, %{error: inspect(reason)})
    end
  end

  post "/api/agent/auth/claude/cancel" do
    with %{"handle" => handle} when is_binary(handle) <- conn.body_params,
         :ok <- Reverb.Agent.Auth.cancel(handle) do
      send_json(conn, 200, %{result: "ok"})
    else
      _ -> send_json(conn, 422, %{error: "handle is required"})
    end
  end

  match _ do
    send_json(conn, 404, %{error: "not_found"})
  end

  defp send_json(conn, status, payload) do
    body = payload |> normalize_json() |> Jason.encode!()

    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, body)
  end

  defp keyword_params(params, allowed_keys) do
    Enum.reduce(allowed_keys, [], fn key, acc ->
      string_key = Atom.to_string(key)

      case Map.get(params, string_key) do
        nil -> acc
        value when key in [:limit, :since_minutes] -> [{key, String.to_integer(value)} | acc]
        value -> [{key, normalize_param_value(key, value)} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_param_value(:status, value), do: String.to_existing_atom(value)
  defp normalize_param_value(:state, value), do: String.to_existing_atom(value)
  defp normalize_param_value(_key, value), do: value

  defp normalize_json(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp normalize_json(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> normalize_json()
  end

  defp normalize_json(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), normalize_json(value)} end)
    |> Map.new()
  end

  defp normalize_json(list) when is_list(list), do: Enum.map(list, &normalize_json/1)
  defp normalize_json(value) when is_boolean(value) or is_nil(value), do: value
  defp normalize_json(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_json(value), do: value
end
