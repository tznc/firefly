defmodule Firefly.FakeAkismet do
  @moduledoc """
  A fake Akismet for tests: a local HTTP server (Bandit) speaking its API.
  `comment-check` calls content with "viagra" in it spam (Akismet's own
  test trigger is an author named `viagra-test-123`, which works too);
  `submit-spam`, `submit-ham` and `verify-key` (key `"good-key"`) answer
  as Akismet does. Every request is sent to the test process as
  `{:akismet, call, params}`.

  `setup/1` starts it and turns checks on, pointed at it.
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  import Plug.Conn

  alias Firefly.Repo
  alias Firefly.SiteSettings.SiteSetting

  @behaviour Plug

  @doc """
  Starts the fake (stopped with the test), points Akismet at it and turns
  checks on, with `settings` on top. `answer` (a function of the call and
  its params) can replace the fake's answers.
  """
  def setup(settings \\ %{}, answer \\ nil) do
    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: {__MODULE__, {answer, self()}}, ip: :loopback, port: 0, startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    original = Application.get_env(:firefly, Firefly.Moderation.Akismet, [])

    Application.put_env(
      :firefly,
      Firefly.Moderation.Akismet,
      Keyword.put(original, :base_url, "http://127.0.0.1:#{port}/1.1")
    )

    ExUnit.Callbacks.on_exit(fn ->
      Application.put_env(:firefly, Firefly.Moderation.Akismet, original)
    end)

    %{"akismet_enabled" => "true", "akismet_api_key" => "good-key"}
    |> Map.merge(settings)
    |> Enum.each(fn
      {"akismet_api_key", key} ->
        Repo.insert!(%SiteSetting{key: "akismet_api_key", value: "", secret_value: key},
          on_conflict: [set: [secret_value: key]],
          conflict_target: :key
        )

      {key, value} ->
        Repo.insert!(%SiteSetting{key: key, value: value},
          on_conflict: [set: [value: value]],
          conflict_target: :key
        )
    end)

    Firefly.SiteSettings.clear_cache()
  end

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, {answer, test}) do
    "/1.1/" <> call = conn.request_path
    {:ok, body, conn} = read_body(conn)
    params = URI.decode_query(body)
    send(test, {:akismet, call, params})

    body = if answer, do: answer.(call, params), else: answer(call, params)
    conn |> put_resp_content_type("text/plain") |> send_resp(200, body)
  end

  defp answer("comment-check", params) do
    spam? =
      String.contains?(String.downcase(params["comment_content"] || ""), "viagra") or
        params["comment_author"] == "viagra-test-123"

    to_string(spam?)
  end

  defp answer("verify-key", %{"api_key" => "good-key"}), do: "valid"
  defp answer("verify-key", _params), do: "invalid"
  defp answer(_submit, _params), do: "Thanks for making the web a better place."
end
