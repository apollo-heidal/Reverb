defmodule Reverb.ProdControlTest do
  use ExUnit.Case, async: true

  alias Reverb.ProdControl

  test "plans migrate and restart for app-affecting files" do
    plan =
      ProdControl.plan([
        "lib/my_app_web/controllers/page_controller.ex",
        "priv/repo/migrations/20260412000000_add_widgets.exs"
      ])

    assert plan.migrate?
    assert plan.restart?
  end

  test "does not require prod apply for unrelated files" do
    plan = ProdControl.plan(["README.md"])

    refute plan.migrate?
    refute plan.restart?
  end
end
