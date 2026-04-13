defmodule ReverbQuickstartTemplate.Accounts do
  use Ash.Domain,
    otp_app: :reverb_quickstart_template

  resources do
    resource ReverbQuickstartTemplate.Accounts.Token
    resource ReverbQuickstartTemplate.Accounts.User
  end
end
