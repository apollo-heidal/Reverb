defmodule Reverb.Quickstart.Config do
  @moduledoc false

  @enforce_keys [
    :project_name,
    :project_slug,
    :target,
    :workspace_root_host_path,
    :app_name,
    :app_module,
    :app_web_module,
    :topic_hash,
    :reverb_pubsub_name,
    :reverb_control_module,
    :reverb_erlang_cookie,
    :initial_admin_email,
    :initial_admin_password,
    :secret_key_base,
    :token_signing_secret,
    :app_port,
    :opencode_port,
    :bind_mount_suffix,
    :reverb_image,
    :quickstart_prod_image
  ]

  defstruct @enforce_keys

  def build!(opts) do
    target = opts[:target] |> to_string() |> Path.expand()
    project_slug = Path.basename(target)

    app_name =
      opts[:app_name]
      |> blank_to_nil()
      |> Kernel.||(default_app_name(project_slug))

    app_module =
      opts[:module]
      |> blank_to_nil()
      |> Kernel.||(Macro.camelize(app_name))

    %__MODULE__{
      project_name: opts[:project_name] |> blank_to_nil() |> Kernel.||(humanize(project_slug)),
      project_slug: project_slug,
      target: target,
      workspace_root_host_path:
        opts[:workspace_root_host_path]
        |> blank_to_nil()
        |> Kernel.||(Path.dirname(target)),
      app_name: app_name,
      app_module: app_module,
      app_web_module: app_module <> "Web",
      topic_hash: opts[:topic_hash] |> blank_to_nil() |> Kernel.||(default_topic_hash(project_slug)),
      reverb_pubsub_name: app_module <> ".PubSub",
      reverb_control_module: app_module <> ".Reverb.Control",
      reverb_erlang_cookie: fetch_required!(opts, :reverb_erlang_cookie),
      initial_admin_email: fetch_required!(opts, :initial_admin_email),
      initial_admin_password: fetch_required!(opts, :initial_admin_password),
      secret_key_base: fetch_required!(opts, :secret_key_base),
      token_signing_secret: fetch_required!(opts, :token_signing_secret),
      app_port: fetch_required!(opts, :app_port),
      opencode_port: fetch_required!(opts, :opencode_port),
      bind_mount_suffix: Keyword.get(opts, :bind_mount_suffix, "") |> to_string(),
      reverb_image: fetch_required!(opts, :reverb_image),
      quickstart_prod_image: fetch_required!(opts, :quickstart_prod_image)
    }
  end

  def placeholders(%__MODULE__{} = config) do
    [
      {"ReverbQuickstartTemplateWeb", config.app_web_module},
      {"ReverbQuickstartTemplate", config.app_module},
      {"reverb_quickstart_template_web", config.app_name <> "_web"},
      {"reverb_quickstart_template", config.app_name},
      {"__PROJECT_NAME__", config.project_name},
      {"__QUICKSTART_APP_SLUG__", config.project_slug},
      {"__APP_NAME__", config.app_name},
      {"__APP_MODULE__", config.app_module},
      {"__REVERB_TOPIC_HASH__", config.topic_hash},
      {"__REVERB_PUBSUB_NAME__", config.reverb_pubsub_name},
      {"__REVERB_CONTROL_MODULE__", config.reverb_control_module},
      {"__REVERB_ERLANG_COOKIE__", config.reverb_erlang_cookie},
      {"__INITIAL_ADMIN_EMAIL__", config.initial_admin_email},
      {"__INITIAL_ADMIN_PASSWORD__", config.initial_admin_password},
      {"__SECRET_KEY_BASE__", config.secret_key_base},
      {"__TOKEN_SIGNING_SECRET__", config.token_signing_secret},
      {"__APP_PORT__", config.app_port},
      {"__OPENCODE_PORT__", config.opencode_port},
      {"__WORKSPACE_ROOT_HOST_PATH__", config.workspace_root_host_path},
      {"__BIND_MOUNT_SUFFIX__", config.bind_mount_suffix},
      {"__REVERB_IMAGE__", config.reverb_image},
      {"__QUICKSTART_PROD_IMAGE__", config.quickstart_prod_image}
    ]
  end

  defp fetch_required!(opts, key) do
    opts
    |> Keyword.get(key)
    |> blank_to_nil()
    |> case do
      nil -> raise ArgumentError, "missing required option --#{key |> to_string() |> String.replace("_", "-")}" 
      value -> to_string(value)
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp default_app_name(project_slug) do
    app_name = String.replace(project_slug, "-", "_")

    case app_name do
      <<first, _rest::binary>> when first in ?0..?9 -> "app_" <> app_name
      _ -> app_name
    end
  end

  defp default_topic_hash(project_slug) do
    "captain-#{project_slug}-#{System.os_time(:second)}"
  end

  defp humanize(project_slug) do
    project_slug
    |> String.split("-", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
