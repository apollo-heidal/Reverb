defmodule Reverb.Receiver.Listener do
  @moduledoc """
  GenServer that connects to the production BEAM node and subscribes to
  the Reverb PubSub topic. Incoming messages are passed to the triage
  system for processing into tasks.

  Handles node disconnection with automatic reconnect and backoff.
  """

  use GenServer
  require Logger

  alias Reverb.{Topic, Tasks.Triage}

  defstruct [:prod_node, :reconnect_interval_ms, :reconnect_ref, connected: false]

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    config = Application.get_env(:reverb, Reverb.Receiver, [])
    prod_node = Keyword.get(config, :prod_node)
    reconnect_ms = Keyword.get(config, :reconnect_interval_ms, 10_000)

    state = %__MODULE__{
      prod_node: prod_node,
      reconnect_interval_ms: reconnect_ms
    }

    # Subscribe to PubSub (works locally and across connected nodes via :pg)
    Phoenix.PubSub.subscribe(Topic.pubsub_name(), Topic.name())

    # Monitor nodes for disconnect detection
    :net_kernel.monitor_nodes(true)

    # Connect to prod if configured
    if prod_node do
      send(self(), :connect)
    else
      Logger.info("[Reverb.Listener] No prod_node configured, listening on local PubSub only")
    end

    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    state = cancel_reconnect(state)

    case state.prod_node do
      nil ->
        {:noreply, state}

      prod_node ->
        case Node.connect(prod_node) do
          true ->
            Logger.info("[Reverb.Listener] Connected to #{prod_node}")
            {:noreply, %{state | connected: true}}

          false ->
            Logger.warning(
              "[Reverb.Listener] Failed to connect to #{prod_node}, retrying in #{state.reconnect_interval_ms}ms"
            )

            ref = Process.send_after(self(), :connect, state.reconnect_interval_ms)
            {:noreply, %{state | connected: false, reconnect_ref: ref}}

          :ignored ->
            Logger.info("[Reverb.Listener] Already connected to #{prod_node}")
            {:noreply, %{state | connected: true}}
        end
    end
  end

  def handle_info({:nodedown, node}, %{prod_node: prod_node} = state) when node == prod_node do
    Logger.warning("[Reverb.Listener] Lost connection to #{node}, scheduling reconnect")
    ref = Process.send_after(self(), :connect, state.reconnect_interval_ms)
    {:noreply, %{state | connected: false, reconnect_ref: ref}}
  end

  def handle_info({:nodedown, _node}, state) do
    {:noreply, state}
  end

  def handle_info({:nodeup, _node}, state) do
    {:noreply, state}
  end

  # Receive Reverb messages from PubSub
  def handle_info({:reverb_message, message}, state) do
    case Reverb.Message.validate_incoming(message) do
      {:ok, message} ->
        Logger.debug("[Reverb.Listener] Received message: #{String.slice(message.message, 0, 80)}")

        Reverb.Runtime.record_event(:message_received, %{
          kind: message.kind,
          source: message.source,
          severity: message.severity,
          fingerprint: Reverb.Message.fingerprint(message)
        })

        # Triage asynchronously to avoid blocking the listener
        Task.start(fn -> Triage.process(message) end)

      {:error, reason} ->
        Logger.warning("[Reverb.Listener] Rejected inbound message: #{inspect(reason)}")
        Reverb.Runtime.record_event(:message_rejected, %{reason: inspect(reason)})
    end

    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp cancel_reconnect(%{reconnect_ref: nil} = state), do: state

  defp cancel_reconnect(%{reconnect_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | reconnect_ref: nil}
  end
end
