defmodule Reverb.Tasks.Triage do
  @moduledoc """
  Processes incoming Reverb messages into tasks.

  Default implementation:
  - Computes a fingerprint for deduplication
  - If an active task with the same fingerprint exists, increments error_count
  - If new, creates a task with severity inferred from message kind
  - Optionally stores the raw message in the audit log

  ## Custom Triage

  Configure a custom triage module:

      config :reverb, triage_module: MyApp.CustomTriage

  The module must implement `process/1` accepting a `Reverb.Message`.
  """

  require Logger

  alias Reverb.{Message, Repo, Tasks}

  @doc "Processes a Reverb message — creates or updates a task."
  def process(%Message{} = message) do
    triage_module = Application.get_env(:reverb, :triage_module, __MODULE__)

    if triage_module == __MODULE__ do
      do_process(message)
    else
      triage_module.process(message)
    end
  end

  defp do_process(%Message{} = message) do
    fingerprint = Message.fingerprint(message)
    metadata = build_metadata(message)

    # Store raw message if configured
    if store_raw?() do
      store_raw_message(message, fingerprint)
    end

    # Log-derived signals deduplicate by fingerprint, but captain requests should
    # always become distinct queued tasks.
    attrs = %{
      body: message.message,
      category: to_string(message.kind),
      source_id: if(message.node, do: to_string(message.node)),
      source_kind: metadata["source_kind"] || "signal",
      subject: metadata["subject"],
      priority: metadata["priority"] || priority_for(message.severity),
      severity: message.severity,
      metadata: metadata
    }

    result =
      if attrs.source_kind == "captain" do
        Tasks.create_task(Map.put(attrs, :fingerprint, fingerprint))
      else
        Tasks.upsert_by_fingerprint(fingerprint, attrs)
      end

    case result do
      {:ok, task} ->
        Logger.debug("[Reverb.Triage] Task #{task.id} (fingerprint: #{fingerprint})")

        Reverb.Runtime.record_event(:task_triaged, %{
          task_id: task.id,
          fingerprint: fingerprint,
          category: task.category,
          severity: task.severity
        })

        {:ok, task}

      {:error, reason} ->
        Logger.warning("[Reverb.Triage] Failed to create task: #{inspect(reason)}")

        Reverb.Runtime.record_event(:triage_failed, %{
          fingerprint: fingerprint,
          reason: inspect(reason)
        })

        {:error, reason}
    end
  end

  defp store_raw_message(message, fingerprint) do
    attrs = %{
      id: Ecto.UUID.bingenerate(),
      kind: to_string(message.kind),
      message: message.message,
      source: message.source,
      stacktrace: message.stacktrace,
      metadata: message.metadata,
      severity: to_string(message.severity),
      node: if(message.node, do: to_string(message.node)),
      fingerprint: fingerprint,
      inserted_at: DateTime.utc_now()
    }

    Repo.insert_all("reverb_messages", [attrs], on_conflict: :nothing)
  rescue
    error ->
      Logger.warning("[Reverb.Triage] Failed to store raw message: #{inspect(error)}")
  end

  defp build_metadata(%Message{} = msg) do
    base =
      (msg.metadata || %{})
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    base
    |> Map.put("source", msg.source)
    |> Map.put("node", if(msg.node, do: to_string(msg.node)))
    |> Map.put("timestamp", if(msg.timestamp, do: DateTime.to_iso8601(msg.timestamp)))
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp store_raw? do
    Application.get_env(:reverb, Reverb.Receiver, [])
    |> Keyword.get(:store_raw_messages, true)
  end

  defp priority_for(:critical), do: 0
  defp priority_for(:high), do: 25
  defp priority_for(:medium), do: 50
  defp priority_for(:low), do: 75
end
