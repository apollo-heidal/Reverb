defmodule Reverb.Operator.RouterTest do
  use Reverb.DataCase, async: false

  import Plug.Test

  alias Reverb.Operator.Router
  alias Reverb.Tasks

  test "serves health and tasks endpoints" do
    {:ok, _task} = Tasks.create_task(%{body: "inspect me", status: :todo})

    health_conn = conn(:get, "/health") |> Router.call([])
    assert health_conn.status == 200
    assert Jason.decode!(health_conn.resp_body)["ok"] == true

    tasks_conn = conn(:get, "/api/tasks") |> Router.call([])
    assert tasks_conn.status == 200
    assert length(Jason.decode!(tasks_conn.resp_body)["tasks"]) >= 1
  end

  test "filters tasks by source_kind" do
    {:ok, captain_task} = Tasks.create_task(%{body: "captain", source_kind: "captain"})
    {:ok, _signal_task} = Tasks.create_task(%{body: "signal", source_kind: "signal"})

    tasks_conn = conn(:get, "/api/tasks?source_kind=captain") |> Router.call([])

    assert tasks_conn.status == 200
    assert [task] = Jason.decode!(tasks_conn.resp_body)["tasks"]
    assert task["id"] == captain_task.id
  end
end
