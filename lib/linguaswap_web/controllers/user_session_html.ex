defmodule LinguaswapWeb.UserSessionHTML do
  use LinguaswapWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:linguaswap, Linguaswap.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
