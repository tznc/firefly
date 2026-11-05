defmodule FireflyWeb.Admin.Logged do
  @moduledoc """
  What every resource of the database admin shares. A Kaffy admin module
  that does `use FireflyWeb.Admin.Logged, as: "thread"` gets:

    * changesets that take only the fields its `form_fields/1` lets admins
      edit (through the schema's own `changeset/2` where it has one, so
      its basic checks still apply), whatever else a form posts;
    * Kaffy's `after_insert/2`, `before_update/2` and `after_delete/2`
      callbacks, which Kaffy runs inside the same transaction as the
      change, recording it in the staff log: an update records each
      changed field's before/after values, creates and deletes record the
      row's fields (no secrets or email addresses). Granting or revoking
      a role (`as: "role_membership"`) is recorded as
      `role.grant`/`role.revoke` on the user; memberships can't be edited
      in place.
  """

  alias Firefly.Moderation.StaffLog
  alias Firefly.Groups.RoleMembership

  defmacro __using__(as: type) do
    quote do
      @doc false
      def create_changeset(entry, attrs),
        do: unquote(__MODULE__).changeset(__MODULE__, entry, attrs)

      @doc false
      def update_changeset(entry, attrs),
        do: unquote(__MODULE__).changeset(__MODULE__, entry, attrs)

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
  def changeset(admin, %schema{} = entry, attrs) do
    editable =
      for {field, options} <- admin.form_fields(schema),
          (options || %{})[:update] != :readonly or is_nil(entry.id),
          do: to_string(field)

    attrs = Map.take(attrs, editable)

    if function_exported?(schema, :changeset, 2),
      do: schema.changeset(entry, attrs),
      else: Firefly.Changeset.cast(entry, attrs, Enum.map(editable, &String.to_existing_atom/1))
  end

  @doc false
  def inserted(conn, type, entry) do
    record(conn, entry, "admin.create", type)
    {:ok, entry}
  end

  @doc false
  # Role memberships are read-only once made (see `RoleMembershipAdmin`):
  # moving one to another user or role would be an unlogged grant.
  def updating(_conn, "role_membership", %Ecto.Changeset{changes: changes} = changeset)
      when changes != %{},
      do:
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :user_id,
           "can't be changed: delete the membership and add a new one"
         )}

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
    %{user: user, role: role} = Firefly.Repo.preload(membership, [:user, :role])
    action = if action == "admin.create", do: "role.grant", else: "role.revoke"

    StaffLog.record(conn.assigns.current_user, action, user, %{
      role: role.name,
      username: user.username
    })
  end

  defp record(conn, entry, action, type) do
    StaffLog.record(conn.assigns.current_user, action, {type, entry.id}, fields(entry))
  end

  # The row's own fields (no associations, secrets or contact details), to
  # show a deleted row.
  defp fields(%schema{} = entry) do
    (schema.__schema__(:fields) --
       [:id, :password_hash, :email | schema.__schema__(:redact_fields)])
    |> Map.new(&{&1, StaffLog.json_safe(Map.get(entry, &1))})
  end
end
