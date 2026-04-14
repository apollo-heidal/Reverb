defmodule ReverbQuickstartTemplate.Captain do
  @moduledoc false

  @operator_default "http://reverb:4010"
  @opencode_default "http://localhost:4096"

  def project_name do
    System.get_env("REVERB_PROJECT_NAME") || "Reverb Quickstart"
  end

  def admin_email do
    System.get_env("INITIAL_ADMIN_EMAIL")
  end

  def admin?(nil), do: false

  def admin?(%{email: email}) do
    admin_email = admin_email() |> normalize_email()
    user_email = normalize_email(email)

    admin_email != nil and user_email != nil and user_email == admin_email
  end

  def admin?(_user), do: false

  def submit(prompt) when is_binary(prompt) do
    prompt = String.trim(prompt)

    cond do
      prompt == "" ->
        {:error, :blank}

      true ->
        payload = %{
          body: prompt,
          metadata: %{
            source_kind: "captain",
            ui_source: "captain",
            subject: summarize(prompt)
          }
        }

        case Jason.encode(payload) do
          {:ok, body} ->
            url = operator_url() <> "/api/tasks/manual"
            :inets.start()

            headers = [{~c"content-type", ~c"application/json"}]
            request = {String.to_charlist(url), headers, ~c"application/json", body}

            case :httpc.request(:post, request, [], body_format: :binary) do
              {:ok, {{_, status, _}, _headers, _body}} when status in [200, 201] -> :ok
              {:ok, {{_, status, _}, _headers, _body}} -> {:error, "Reverb operator returned HTTP #{status}."}
              {:error, reason} -> {:error, "Could not reach Reverb (#{inspect(reason)})."}
            end

          {:error, _} ->
            {:error, "Could not encode the captain request."}
        end
    end
  end

  def opencode_url do
    System.get_env("QUICKSTART_OPENCODE_URL") || @opencode_default
  end

  def list_tasks do
    url = operator_url() <> "/api/tasks?source_kind=captain&limit=25"
    :inets.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        case Jason.decode(body) do
          {:ok, %{"tasks" => tasks}} when is_list(tasks) -> {:ok, tasks}
          {:ok, _} -> {:error, "Unexpected task payload from Reverb."}
          {:error, _} -> {:error, "Reverb returned invalid JSON."}
        end

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, "Reverb operator returned HTTP #{status}."}

      {:error, reason} ->
        {:error, "Could not reach Reverb (#{inspect(reason)})."}
    end
  end

  @doc """
  Returns `{:ok, %{"claude" => status, ...}}` from the Reverb operator. Status
  values are strings like `"authed"`, `"missing"`, or `"unknown"`.
  """
  def auth_status do
    case get_json("/api/agent/auth/status") do
      {:ok, %{"providers" => providers}} when is_map(providers) -> {:ok, providers}
      {:ok, _} -> {:error, "Unexpected auth payload from Reverb."}
      {:error, _} = err -> err
    end
  end

  @doc """
  Returns `true` if at least one provider is authed. On RPC failure, returns
  `false` (fail-closed so Captain routes the user to the providers page).
  """
  def any_provider_authed? do
    case auth_status() do
      {:ok, providers} ->
        Enum.any?(providers, fn {_k, v} -> v in ["authed", :authed] end)

      {:error, _} ->
        false
    end
  end

  @doc "Starts a Claude auth session. Returns `{:ok, %{\"handle\" => _, \"url\" => _}}`."
  def claude_auth_start do
    post_json("/api/agent/auth/claude/start", %{})
  end

  @doc "Completes a Claude auth session by submitting the pasted OAuth code."
  def claude_auth_complete(handle, code) do
    post_json("/api/agent/auth/claude/complete", %{handle: handle, code: code})
  end

  @doc "Cancels an in-flight Claude auth session."
  def claude_auth_cancel(handle) do
    post_json("/api/agent/auth/claude/cancel", %{handle: handle})
  end

  defp get_json(path) do
    url = operator_url() <> path
    :inets.start()

    case :httpc.request(:get, {String.to_charlist(url), []}, [], body_format: :binary) do
      {:ok, {{_, status, _}, _headers, body}} when status in 200..299 ->
        Jason.decode(body)

      {:ok, {{_, status, _}, _headers, _body}} ->
        {:error, "Reverb operator returned HTTP #{status}."}

      {:error, reason} ->
        {:error, "Could not reach Reverb (#{inspect(reason)})."}
    end
  end

  defp post_json(path, payload) do
    url = operator_url() <> path
    :inets.start()

    case Jason.encode(payload) do
      {:ok, body} ->
        headers = [{~c"content-type", ~c"application/json"}]
        request = {String.to_charlist(url), headers, ~c"application/json", body}

        case :httpc.request(:post, request, [], body_format: :binary) do
          {:ok, {{_, status, _}, _headers, resp}} when status in 200..299 ->
            case Jason.decode(resp) do
              {:ok, decoded} -> {:ok, decoded}
              {:error, _} -> {:ok, %{}}
            end

          {:ok, {{_, status, _}, _headers, resp}} ->
            {:error, decode_error(resp, status)}

          {:error, reason} ->
            {:error, "Could not reach Reverb (#{inspect(reason)})."}
        end

      {:error, _} ->
        {:error, "Could not encode the request."}
    end
  end

  defp decode_error(body, status) do
    case Jason.decode(body) do
      {:ok, %{"error" => message}} when is_binary(message) -> message
      _ -> "Reverb operator returned HTTP #{status}."
    end
  end

  defp summarize(prompt) do
    prompt
    |> String.split(~r/ +/, trim: true)
    |> Enum.take(12)
    |> Enum.join(" ")
    |> String.slice(0, 120)
  end

  defp operator_url do
    System.get_env("REVERB_OPERATOR_URL") || @operator_default
  end

  defp normalize_email(nil), do: nil

  defp normalize_email(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end
end
