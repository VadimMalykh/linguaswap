defmodule LinguaswapWeb.PageController do
  use LinguaswapWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
