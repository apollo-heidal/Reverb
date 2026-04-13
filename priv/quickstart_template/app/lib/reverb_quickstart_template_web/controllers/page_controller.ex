defmodule ReverbQuickstartTemplateWeb.PageController do
  use ReverbQuickstartTemplateWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
