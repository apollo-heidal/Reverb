defmodule Reverb.Agent.CLI.ClaudeTest do
  use ExUnit.Case, async: true

  alias Reverb.Agent.CLI

  @capture_script Path.expand("test/support/fixtures/claude_stream.sh")

  test "runs claude adapter and extracts result output" do
    assert {:ok, result} =
             CLI.run("implement the feature",
               adapter: :claude,
               command: @capture_script,
               args: [],
               model: "claude-sonnet-4-6"
             )

    assert result.provider == :claude
    assert result.output == "done"
    assert result.session_id == "ses_claude_test_1"
    assert List.last(result.args) == "implement the feature"
  end

  test "infers claude adapter from command basename" do
    assert {:ok, result} =
             CLI.run("ship it",
               command: @capture_script,
               args: []
             )

    assert result.provider == :claude
  end

  test "returns command_not_found when binary missing" do
    assert {:error, {:command_not_found, "claude-does-not-exist-xyz"}} =
             CLI.run("anything",
               adapter: :claude,
               command: "claude-does-not-exist-xyz",
               args: []
             )
  end

  test "extracts assistant text when result event is absent" do
    script = Path.expand("test/support/fixtures/claude_assistant_only.sh")

    File.write!(
      script,
      """
      #!/usr/bin/env bash
      set -euo pipefail
      printf '{"type":"system","subtype":"init","session_id":"ses_assistant_only"}\\n'
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello there"}]}}\\n'
      """
    )

    File.chmod!(script, 0o755)

    on_exit(fn -> File.rm_rf!(script) end)

    assert {:ok, result} =
             CLI.run("any",
               adapter: :claude,
               command: script,
               args: []
             )

    assert result.output == "hello there"
    assert result.session_id == "ses_assistant_only"
  end
end
