defmodule Reverb.Quickstart.Render do
  @moduledoc false

  def render(value, placeholders) do
    Enum.reduce(placeholders, value, fn {needle, replacement}, acc ->
      String.replace(acc, needle, replacement)
    end)
  end
end
