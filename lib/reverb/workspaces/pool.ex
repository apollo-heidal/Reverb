defmodule Reverb.Workspaces.Pool do
  @moduledoc """
  Managed pool of task workspaces.

  Each checked-out slot maps to one branch/worktree owned by the coordinator.
  """

  use GenServer
  require Logger

  alias Reverb.Workspaces.{PathSafety, Slot}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def checkout(task, opts \\ []) do
    GenServer.call(__MODULE__, {:checkout, task, opts}, 30_000)
  end

  def checkin(slot_id) do
    GenServer.call(__MODULE__, {:checkin, slot_id}, 30_000)
  end

  def checkin_by_path(path) when is_binary(path) do
    GenServer.call(__MODULE__, {:checkin_by_path, path}, 30_000)
  end

  def reclaim_checked_out do
    GenServer.call(__MODULE__, :reclaim_checked_out, 30_000)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(_opts) do
    root = workspace_root()
    File.mkdir_p(root)

    state = %{
      root: root,
      next_id: 0,
      slots: %{}
    }

    if Application.get_env(:reverb, Reverb.Workspaces, [])
       |> Keyword.get(:reclaim_on_boot, true) do
      send(self(), :reclaim)
    end

    {:ok, state}
  end

  @impl true
  def handle_call({:checkout, task, opts}, _from, state) do
    branch = Keyword.get(opts, :branch) || Reverb.Git.task_branch(task)
    path = Path.join(state.root, branch)

    with {:ok, path} <- PathSafety.validate(path, state.root),
         {:ok, info} <- Reverb.Git.prepare_workspace(task, branch: branch, path: path) do
      slot = %Slot{
        id: state.next_id,
        path: info.path,
        branch: info.branch,
        task_id: task.id,
        status: :checked_out
      }

      Reverb.Runtime.record_event(:workspace_checked_out, %{
        task_id: task.id,
        branch: slot.branch,
        path: slot.path
      })

      {:reply, {:ok, slot},
       %{state | next_id: state.next_id + 1, slots: Map.put(state.slots, slot.id, slot)}}
    else
      {:error, reason} ->
        Logger.warning("[Reverb.Workspaces] checkout failed: #{inspect(reason)}")
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:checkin, slot_id}, _from, state) do
    {reply, new_state} = do_checkin(slot_id, state)
    {:reply, reply, new_state}
  end

  def handle_call({:checkin_by_path, path}, _from, state) do
    case Enum.find(state.slots, fn {_id, slot} -> slot.path == path end) do
      {slot_id, _slot} ->
        {reply, new_state} = do_checkin(slot_id, state)
        {:reply, reply, new_state}

      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply, %{root: state.root, count: map_size(state.slots), slots: Map.values(state.slots)},
     state}
  end

  def handle_call(:reclaim_checked_out, _from, state) do
    Enum.each(state.slots, fn {_id, slot} -> Reverb.Git.cleanup_workspace(slot.path) end)
    {:reply, %{reclaimed: map_size(state.slots)}, %{state | slots: %{}}}
  end

  @impl true
  def handle_info(:reclaim, state) do
    with {:ok, entries} <- File.ls(state.root) do
      Enum.each(entries, fn entry ->
        path = Path.join(state.root, entry)
        _ = Reverb.Git.cleanup_workspace(path)
      end)
    end

    _ = Reverb.Git.prune_worktrees()

    {:noreply, state}
  end

  defp workspace_root do
    Application.get_env(:reverb, Reverb.Workspaces, [])
    |> Keyword.get(:root, "/tmp/reverb/workspaces")
  end

  defp do_checkin(slot_id, state) do
    case Map.pop(state.slots, slot_id) do
      {nil, _slots} ->
        {{:error, :not_found}, state}

      {%Slot{} = slot, slots} ->
        _ = Reverb.Git.cleanup_workspace(slot.path)

        Reverb.Runtime.record_event(:workspace_checked_in, %{
          task_id: slot.task_id,
          branch: slot.branch,
          path: slot.path
        })

        {:ok, %{state | slots: slots}}
    end
  end
end
