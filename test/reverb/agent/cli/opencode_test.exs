defmodule Reverb.Agent.CLI.OpenCodeTest do
  use ExUnit.Case, async: true

  alias Reverb.Agent.CLI

  @capture_script Path.expand("test/support/fixtures/opencode_ndjson.sh")

  test "runs opencode adapter and extracts assistant output" do
    assert {:ok, result} =
             CLI.run("implement the feature",
               adapter: :opencode,
               command: @capture_script,
               args: [],
               model: "gpt-5.4"
             )

    assert result.provider == :opencode
    assert result.output == "implemented the feature"
    assert result.session_id == "ses_test_123"
    assert result.args == ["implement the feature"]
  end

  test "infers opencode adapter from command basename" do
    assert {:ok, result} =
             CLI.run("ship it",
               command: @capture_script,
               args: []
             )

    assert result.provider == :opencode
  end
end
