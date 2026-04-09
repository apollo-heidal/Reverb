defmodule Reverb.Message do
  @moduledoc """
  Struct representing a message emitted from a production app.

  Messages are broadcast over PubSub and received by the dev-side listener.
  They carry error/warning/manual context that the triage system converts
  into actionable tasks.
  """

  @enforce_keys [:kind, :message]
  defstruct [
    :id,
    :kind,
    :message,
    :source,
    :stacktrace,
    :severity,
    :node,
    :timestamp,
    metadata: %{},
    version: 1
  ]

  @type kind :: :error | :warning | :manual | :telemetry
  @type severity :: :critical | :high | :medium | :low

  @type t :: %__MODULE__{
          id: String.t() | nil,
          kind: kind(),
          message: String.t(),
          source: String.t() | nil,
          stacktrace: String.t() | nil,
          metadata: map(),
          severity: severity(),
          node: atom() | nil,
          timestamp: DateTime.t() | nil,
          version: pos_integer()
        }

  @max_message_length 16_000
  @max_source_length 255
  @max_stacktrace_length 8_000
  @max_metadata_entries 50
  @max_metadata_depth 3
  @max_metadata_list_length 20
  @max_metadata_string_length 1_024

  @doc "Builds a new message with auto-generated id, timestamp, and node."
  def new(kind, message, opts \\ []) when kind in [:error, :warning, :manual, :telemetry] do
    %__MODULE__{
      id: generate_id(),
      kind: kind,
      message: to_string(message),
      source: Keyword.get(opts, :source),
      stacktrace: Keyword.get(opts, :stacktrace),
      metadata: Keyword.get(opts, :metadata, %{}),
      severity: Keyword.get(opts, :severity) || infer_severity(kind),
      node: node(),
      timestamp: DateTime.utc_now()
    }
  end

  @doc "Computes a fingerprint for deduplication."
  def fingerprint(%__MODULE__{} = msg) do
    data = "#{msg.kind}:#{msg.source}:#{normalize_message(msg.message)}"
    :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) |> binary_part(0, 16)
  end

  @doc "Validates and size-caps an incoming message from the receiver boundary."
  def validate_incoming(%__MODULE__{} = message) do
    with true <- message.kind in [:error, :warning, :manual, :telemetry] || {:error, :invalid_kind},
         true <- message.severity in [:critical, :high, :medium, :low] || {:error, :invalid_severity},
         {:ok, metadata} <- sanitize_metadata(message.metadata || %{}, 0) do
      {:ok,
       %{
         message
         | message: cap_string(message.message, @max_message_length),
           source: cap_optional_string(message.source, @max_source_length),
           stacktrace: cap_optional_string(message.stacktrace, @max_stacktrace_length),
           metadata: metadata
       }}
    else
      false -> {:error, :invalid_message}
      {:error, _} = error -> error
    end
  end

  def validate_incoming(_message), do: {:error, :invalid_message}

  defp generate_id do
    <<u0::48, _::4, u1::12, _::2, u2::62>> = :crypto.strong_rand_bytes(16)
    <<u0::48, 4::4, u1::12, 2::2, u2::62>> |> Ecto.UUID.load!()
  end

  defp infer_severity(:error), do: :high
  defp infer_severity(:warning), do: :medium
  defp infer_severity(:manual), do: :medium
  defp infer_severity(:telemetry), do: :medium

  defp normalize_message(msg) when is_binary(msg) do
    # Strip dynamic parts (PIDs, refs, timestamps, hex addresses) for stable fingerprints
    msg
    |> String.replace(~r/#PID<[\d.]+>/, "#PID<...>")
    |> String.replace(~r/#Reference<[\d.]+>/, "#Ref<...>")
    |> String.replace(~r/0x[0-9a-fA-F]+/, "0x...")
    |> String.replace(~r/\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}/, "TIMESTAMP")
  end

  defp sanitize_metadata(_value, depth) when depth >= @max_metadata_depth, do: {:ok, %{"truncated" => true}}

  defp sanitize_metadata(value, depth) when is_map(value) do
    value
    |> Enum.take(@max_metadata_entries)
    |> Enum.reduce_while({:ok, %{}}, fn {key, item}, {:ok, acc} ->
      case sanitize_metadata_value(item, depth + 1) do
        {:ok, sanitized} ->
          sanitized_key = key |> to_string() |> cap_string(128)
          {:cont, {:ok, Map.put(acc, sanitized_key, sanitized)}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp sanitize_metadata_value(value, depth) when is_map(value), do: sanitize_metadata(value, depth)

  defp sanitize_metadata_value(value, depth) when is_list(value) do
    value
    |> Enum.take(@max_metadata_list_length)
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case sanitize_metadata_value(item, depth + 1) do
        {:ok, sanitized} -> {:cont, {:ok, [sanitized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, sanitized} -> {:ok, Enum.reverse(sanitized)}
      {:error, _} = error -> error
    end
  end

  defp sanitize_metadata_value(value, _depth) when is_binary(value) do
    {:ok, cap_string(value, @max_metadata_string_length)}
  end

  defp sanitize_metadata_value(value, _depth)
       when is_integer(value) or is_float(value) or is_boolean(value) or is_nil(value) do
    {:ok, value}
  end

  defp sanitize_metadata_value(value, _depth) when is_atom(value) do
    {:ok, value |> Atom.to_string() |> cap_string(@max_metadata_string_length)}
  end

  defp sanitize_metadata_value(value, _depth) do
    {:ok, value |> inspect(limit: 20, printable_limit: 200) |> cap_string(@max_metadata_string_length)}
  end

  defp cap_optional_string(nil, _max), do: nil
  defp cap_optional_string(value, max), do: value |> to_string() |> cap_string(max)

  defp cap_string(value, max) when is_binary(value) do
    String.slice(value, 0, max)
  end
end
