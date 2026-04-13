defmodule ReverbQuickstartTemplate.Secrets do
  use AshAuthentication.Secret

  def secret_for(
        [:authentication, :tokens, :signing_secret],
        ReverbQuickstartTemplate.Accounts.User,
        _opts,
        _context
      ) do
    Application.fetch_env(:reverb_quickstart_template, :token_signing_secret)
  end
end
