defmodule Reverb.Quickstart.Template do
  @moduledoc false

  alias Reverb.Quickstart.Config
  alias Reverb.Quickstart.Render

  @binary_extensions MapSet.new([".ico", ".png", ".jpg", ".jpeg", ".gif", ".woff", ".woff2", ".ttf", ".eot"])

  def render!(%Config{} = config) do
    placeholders = Config.placeholders(config)
    template_root = Application.app_dir(:reverb, "priv/quickstart_template")

    create_target!(config.target)
    copy_tree!(Path.join(template_root, "project"), config.target, placeholders)
    copy_tree!(Path.join(template_root, "app"), Path.join(config.target, "app"), placeholders)
  end

  defp create_target!(target) do
    case File.ls(target) do
      {:ok, []} -> :ok
      {:ok, _entries} -> raise ArgumentError, "target directory already exists and is not empty: #{target}"
      {:error, :enoent} -> File.mkdir_p!(target)
      {:error, reason} -> raise ArgumentError, "could not access target directory #{target}: #{inspect(reason)}"
    end
  end

  defp copy_tree!(source_root, destination_root, placeholders) do
    File.mkdir_p!(destination_root)

    source_root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.each(fn entry ->
      copy_entry!(Path.join(source_root, entry), Path.join(destination_root, render_path(entry, placeholders)), placeholders)
    end)
  end

  defp copy_entry!(source, destination, placeholders) do
    case File.stat!(source) do
      %{type: :directory} ->
        File.mkdir_p!(destination)

        source
        |> File.ls!()
        |> Enum.sort()
        |> Enum.each(fn entry ->
          copy_entry!(Path.join(source, entry), Path.join(destination, render_path(entry, placeholders)), placeholders)
        end)

      %{type: :regular} ->
        source
        |> File.read!()
        |> maybe_render(source, placeholders)
        |> then(&File.write!(destination, &1))
    end
  end

  defp maybe_render(contents, source, placeholders) do
    if binary_file?(source) do
      contents
    else
      Render.render(contents, placeholders)
    end
  end

  defp binary_file?(path) do
    path
    |> Path.extname()
    |> then(&MapSet.member?(@binary_extensions, &1))
  end

  defp render_path(path, placeholders), do: Render.render(path, placeholders)
end
