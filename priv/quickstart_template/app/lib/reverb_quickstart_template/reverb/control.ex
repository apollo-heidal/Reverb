defmodule ReverbQuickstartTemplate.Reverb.Control do
  @moduledoc false
  @app :reverb_quickstart_template

  def status do
    %{
      app: @app,
      node: Node.self(),
      yolo_mode: Application.get_env(:reverb, :yolo_mode, false),
      time: DateTime.utc_now()
    }
  end

  def migrate do
    if Application.get_env(:reverb, :yolo_mode, false) do
      ReverbQuickstartTemplate.Release.migrate()
      :ok
    else
      {:error, :disabled}
    end
  end

  def restart_app do
    if Application.get_env(:reverb, :yolo_mode, false) do
      spawn(fn ->
        Process.sleep(250)
        System.stop(0)
      end)

      :ok
    else
      {:error, :disabled}
    end
  end
end
