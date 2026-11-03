defmodule Firefly.Upgrades do
  @moduledoc """
  The Upgrades context: which version is running, whether a newer one is
  out, and what an upgrade involves (as Discourse's version check and
  upgrade page, without upgrading itself: a container doesn't rewrite
  itself, admins follow the steps at `/staff/upgrade`).

  The running version is the app's (`mix.exs`), with the git commit it
  was built from when the build said (`FIREFLY_GIT_SHA`, a Docker build
  argument).

  Once a day (once across nodes, from the scheduler), unless the
  `version_check` setting is off, the latest release of the configured
  GitHub repository (`FIREFLY_UPDATE_REPO`, default `tznc/firefly`) is
  fetched from the GitHub API, through the same server-side request
  forgery guard as webhooks (`Firefly.Plugins.HTTP`), sending the last
  answer's `ETag` so an unchanged release costs nothing (`304`). What it
  found is kept in `version_checks`. A newer release shows on the
  dashboard and the upgrade page, with its notes (Markdown, sanitized),
  and, with the `version_check_notify` setting, notifies admins once per
  release.

  `pending_migrations/0` lists the database migrations of the running
  code that haven't run.
  """

  use Boundary, top_level?: true, check: [out: false], exports: []

  import Ecto.Query

  alias Firefly.{JobRuns, Notifications, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Plugins.HTTP
  alias Firefly.Rendering.Markdown

  @id 1

  ## The running version

  @doc "The running version, e.g. `\"0.10.0\"`."
  def current_version, do: to_string(Application.spec(:firefly, :vsn))

  @doc "The git commit the running code was built from, or nil."
  def git_sha, do: config()[:git_sha]

  @doc "The GitHub repository releases are checked in (`owner/name`)."
  def repo, do: config()[:repo] || "tznc/firefly"

  defp api_url, do: config()[:api_url] || "https://api.github.com"

  defp config, do: Application.get_env(:firefly, __MODULE__, [])

  ## Checking

  @doc """
  The last check's findings: `%{current, git_sha, latest, name, notes_html,
  url, published_at, checked_at, error, update?}` (`latest` nil before the
  first check, or when the repository has no release).
  """
  def status do
    row = row()

    %{
      current: current_version(),
      git_sha: git_sha(),
      latest: row[:latest_version],
      name: row[:release_name],
      notes_html: Markdown.render(row[:release_notes]),
      url: row[:release_url],
      published_at: row[:published_at],
      checked_at: row[:checked_at],
      error: row[:error],
      update?: newer?(row[:latest_version], current_version())
    }
  end

  @doc "Whether a newer release than the running version is out (from the last check)."
  def update_available?, do: newer?(row()[:latest_version], current_version())

  @doc """
  Whether the release tag `latest` (`v1.2.3` or `1.2.3`) is newer than
  `current`. Tags that aren't versions never are.
  """
  def newer?(nil, _current), do: false

  def newer?(latest, current) do
    with {:ok, latest} <- Version.parse(String.trim_leading(latest, "v")),
         {:ok, current} <- Version.parse(current) do
      Version.compare(latest, current) == :gt
    else
      _ -> false
    end
  end

  defp row do
    Repo.one(
      from(v in "version_checks",
        where: v.id == @id,
        select: %{
          etag: v.etag,
          latest_version: v.latest_version,
          release_name: v.release_name,
          release_notes: v.release_notes,
          release_url: v.release_url,
          published_at: v.published_at,
          checked_at: v.checked_at,
          error: v.error,
          notified_version: v.notified_version
        }
      )
    ) || %{}
  end

  @doc """
  Fetches the latest release now: `{:ok, status}` (see `status/0`) or
  `{:error, message}` (also kept, to show).
  """
  def check do
    url = "#{api_url()}/repos/#{repo()}/releases/latest"
    etag = row()[:etag]

    headers = %{
      "Accept" => "application/vnd.github+json",
      "User-Agent" => "Firefly/#{current_version()} (+https://github.com/#{repo()})",
      "X-GitHub-Api-Version" => "2022-11-28"
    }

    headers = if etag, do: Map.put(headers, "If-None-Match", etag), else: headers

    result =
      case HTTP.fetch([URI.parse(url).host], %{"url" => url, "headers" => headers}) do
        {:ok, %{status: 200} = response} -> found(response)
        {:ok, %{status: 304}} -> save(%{error: nil})
        # No release yet.
        {:ok, %{status: 404}} -> save(%{etag: nil, latest_version: nil, error: nil})
        {:ok, %{status: status}} -> failed("GitHub answered #{status}")
        {:error, _kind, message} -> failed(message)
      end

    with :ok <- result, do: {:ok, status()}
  end

  defp found(response) do
    case Jason.decode(response.body) do
      {:ok, %{"tag_name" => tag} = release} when is_binary(tag) ->
        save(%{
          etag: header(response.headers, "etag"),
          latest_version: String.slice(tag, 0, 255),
          release_name: release["name"] && String.slice(release["name"], 0, 255),
          release_notes: release["body"],
          release_url: release["html_url"],
          published_at: published_at(release["published_at"]),
          error: nil
        })

      _other ->
        failed("GitHub's answer wasn't a release")
    end
  end

  defp header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: to_string(value)
    end)
  end

  defp published_at(nil), do: nil

  defp published_at(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      _ -> nil
    end
  end

  defp failed(message) do
    save(%{error: String.slice(message, 0, 1000)})
    {:error, message}
  end

  defp save(fields) do
    fields = Map.merge(fields, %{id: @id, checked_at: DateTime.utc_now(:second)})

    Repo.insert_all("version_checks", [fields],
      on_conflict: {:replace, Map.keys(fields) -- [:id]},
      conflict_target: :id
    )

    :ok
  end

  @doc """
  The daily check (see the moduledoc), then the admins' notification of a
  new release. Run by the scheduler (`Firefly.Moderation.TopicTimers.Scheduler`).
  """
  def run_due do
    if SiteSettings.get("version_check") and JobRuns.claim("version_check", 86_400) do
      with {:ok, %{update?: true} = status} <- check(), do: notify(status)
    end

    :ok
  end

  # Once per release.
  defp notify(status) do
    if SiteSettings.get("version_check_notify") and row()[:notified_version] != status.latest do
      save(%{notified_version: status.latest})

      for admin <- admins() do
        Notifications.notify(admin, %{
          kind: "new_version",
          subject: "Firefly #{status.latest} is out",
          body: "You're running #{status.current}. See what's new and how to upgrade.",
          url: Firefly.Endpoint.url() <> "/staff/upgrade"
        })
      end
    end
  end

  defp admins do
    User
    |> join(:inner, [u], r in assoc(u, :roles))
    |> where([u, r], r.name == "admin" and is_nil(u.deleted_at))
    |> Repo.all()
  end

  ## Upgrading

  @doc """
  The migrations of the running code that haven't run on the database:
  `[{version, name}]`, oldest first.
  """
  def pending_migrations do
    for {:down, version, name} <- Ecto.Migrator.migrations(Repo), do: {version, name}
  end
end
