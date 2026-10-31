defmodule FirestormWeb.Web.FeatureCase do
  use ExUnit.CaseTemplate

  defmodule Helpers do
    use Wallaby.DSL

    def log_in_as(session, user) do
      session
      |> visit("/")
      |> Browser.set_cookie("current_user", to_string(user.id))
    end
  end

  using do
    quote do
      @moduletag :feature
      use Wallaby.DSL

      alias FirestormWeb.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query

      import FirestormWeb.Web.Router.Helpers
      import FirestormWeb.Web.FeatureCase.Helpers

      alias FirestormWeb.Forums.{
        User,
        Category,
        Thread,
        Post
      }
    end
  end

  setup tags do
    pid = FirestormWeb.DataCase.setup_sandbox(tags)
    metadata = Phoenix.Ecto.SQL.Sandbox.metadata_for(FirestormWeb.Repo, pid)
    {:ok, session} = Wallaby.start_session(metadata: metadata)
    {:ok, session: session}
  end
end
