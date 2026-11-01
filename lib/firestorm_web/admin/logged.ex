defmodule FirestormWeb.Admin.Logged do
  @moduledoc """
  Records edits made in the Kaffy admin in the staff log. A Kaffy admin
  module that does `use FirestormWeb.Admin.Logged, as: "thread"` gets Kaffy's
  `after_insert/2`, `before_update/2` and `after_delete/2` callbacks, which
  Kaffy runs inside the same transaction as the change: an update records
  each changed field's before/after values, creates and deletes record the
  row's fields. Granting or revoking a role (`as: "role_membership"`) is
  recorded as `role.grant`/`role.revoke` on the user.
  """

  alias FirestormWeb.{Repo, StaffLog}
  alias FirestormWeb.Forums.RoleMembership

  defmacro __using__(as: type) do
    quote do
      @doc false
      def after_insert(conn, entry), do: unquote(__MODULE__).inserted(conn, unquote(type), entry)

      @doc false
      def before_update(conn, changeset),
        do: unquote(__MODULE__).updating(conn, unquote(type), changeset)

      @doc false
      def after_delete(conn, entry), do: unquote(__MODULE__).deleted(conn, unquote(type), entry)
    end
  end

  @doc false
  def inserted(conn, type, entry) do
    record(conn, entry, "admin.create", type)
    {:ok, entry}
  end

  @doc false
  def updating(conn, type, changeset) do
    if changeset.changes != %{},
      do:
        StaffLog.record(
          conn.assigns.current_user,
          "admin.update",
          {type, changeset.data.id},
          StaffLog.changes(changeset)
        )

    {:ok, changeset}
  end

  @doc false
  def deleted(conn, type, entry) do
    record(conn, entry, "admin.delete", type)
    {:ok, entry}
  end

  defp record(conn, %RoleMembership{} = membership, action, _type) do
    %{user: user, role: role} = Repo.preload(membership, [:user, :role])
    action = if action == "admin.create", do: "role.grant", else: "role.revoke"

    StaffLog.record(conn.assigns.current_user, action, user, %{
      role: role.name,
      username: user.username
    })
  end

  defp record(conn, entry, action, type) do
    StaffLog.record(conn.assigns.current_user, action, {type, entry.id}, fields(entry))
  end

  # The row's own fields (no associations or secrets), to show a deleted row.
  defp fields(%schema{} = entry) do
    (schema.__schema__(:fields) -- [:id, :password_hash, :api_token])
    |> Map.new(&{&1, StaffLog.json_safe(Map.get(entry, &1))})
  end
end
