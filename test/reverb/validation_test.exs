defmodule Reverb.ValidationTest do
  use ExUnit.Case, async: true

  alias Reverb.Validation

  setup do
    original = Application.get_env(:reverb, Reverb.Validation, [])

    on_exit(fn ->
      Application.put_env(:reverb, Reverb.Validation, original)
    end)

    :ok
  end

  test "succeeds when no commands are configured" do
    assert {:ok, ""} = Validation.run("/tmp", commands: [])
  end

  test "returns combined output on failure" do
    Application.put_env(:reverb, Reverb.Validation,
      allowlist_prefixes: ["printf"],
      allow_control_operators: true
    )

    assert {:error, %{exit_code: 7, combined_output: output}} =
              Validation.run("/tmp", commands: ["printf ok", "printf nope && exit 7"])

    assert output =~ "$ printf ok"
    assert output =~ "$ printf nope && exit 7"
  end

  test "rejects commands outside the allowlist" do
    assert {:error, %{error: :validation_command_rejected, command: "printf nope"}} =
             Validation.run("/tmp", commands: ["printf nope"])
  end

  test "rejects control operators by default" do
    Application.put_env(:reverb, Reverb.Validation, allowlist_prefixes: ["mix test"])

    assert {:error, %{error: :validation_command_rejected, reason: reason}} =
             Validation.run("/tmp", commands: ["mix test && rm -rf /tmp/nope"])

    assert reason =~ "control operators"
  end
end
