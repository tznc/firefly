defmodule FirestormWeb.RateLimit do
  @moduledoc """
  Rate limits (Hammer, in-memory ETS buckets per node).

  Limits are `{max_hits, window_ms}` tuples from
  `config :firestorm_web, FirestormWeb.RateLimit, limits: [...]`:

    * `:login` - password login/registration attempts per username
    * `:login_ip` - password login/registration attempts per client IP
    * `:register` - account registrations per client IP
    * `:post` - new threads and posts per user (web, API and email). Its
      count per minute is the `posts_per_minute` site setting, which
      defaults to the configured count.
    * `:email` - account emails (confirmation, password reset) per user
    * `:password_reset` - password reset requests per client IP
    * `:upload` - upload signatures per user
    * `:like` - likes and unlikes per user
    * `:message` - new private conversations per user
    * `:export` - account data exports per user
  """
  use Hammer, backend: :ets

  @defaults [
    login: {10, :timer.minutes(5)},
    login_ip: {100, :timer.minutes(5)},
    register: {5, :timer.hours(1)},
    post: {10, :timer.minutes(1)},
    upload: {30, :timer.hours(1)},
    like: {30, :timer.minutes(5)},
    message: {10, :timer.hours(1)},
    export: {3, :timer.hours(1)},
    email: {3, :timer.hours(1)},
    password_reset: {10, :timer.hours(1)}
  ]

  @doc "Checks the `bucket` limit for `key`: `:ok` or `{:error, :rate_limited}`."
  def check(bucket, key) do
    {limit, scale} = limit(bucket)

    case hit("#{bucket}:#{key}", scale, limit) do
      {:allow, _count} -> :ok
      {:deny, _retry_after} -> {:error, :rate_limited}
    end
  end

  def check_login(username, remote_ip) do
    with :ok <- check(:login_ip, format_ip(remote_ip)) do
      check(:login, String.downcase(username || ""))
    end
  end

  def check_register(remote_ip), do: check(:register, format_ip(remote_ip))

  def check_post(%{id: user_id}), do: check(:post, user_id)
  def check_password_reset(remote_ip), do: check(:password_reset, format_ip(remote_ip))
  def check_email(%{id: user_id}), do: check(:email, user_id)
  def check_upload(%{id: user_id}), do: check(:upload, user_id)
  def check_like(%{id: user_id}), do: check(:like, user_id)
  def check_message(%{id: user_id}), do: check(:message, user_id)
  def check_export(%{id: user_id}), do: check(:export, user_id)

  @doc "The message shown when a limit is hit."
  def message, do: "You're doing that too often. Please wait a moment and try again."

  @doc "The configured number of hits allowed per window for `bucket`."
  def configured_limit(bucket), do: bucket |> configured() |> elem(0)

  @doc """
  The `{hits, window_ms}` in force for `bucket`. For `:post`, that's the
  `posts_per_minute` site setting once an admin sets it; until then the
  configured limit with its own window.
  """
  def limit(:post) do
    if FirestormWeb.SiteSettings.customized?("posts_per_minute"),
      do: {FirestormWeb.SiteSettings.get("posts_per_minute"), :timer.minutes(1)},
      else: configured(:post)
  end

  def limit(bucket), do: configured(bucket)

  defp configured(bucket) do
    configured = Application.get_env(:firestorm_web, __MODULE__, [])[:limits] || []
    Keyword.get(configured, bucket) || Keyword.fetch!(@defaults, bucket)
  end

  defp format_ip(ip) when is_tuple(ip), do: ip |> :inet.ntoa() |> to_string()
  defp format_ip(ip), do: to_string(ip)
end
