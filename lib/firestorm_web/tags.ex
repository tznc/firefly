defmodule FirestormWeb.Tags do
  @moduledoc """
  Tag groups and synonyms, managed by admins at `/staff/tags` (the
  `:manage_tags` policy). Every change goes to the staff log.

    * A group (`FirestormWeb.Forums.TagGroup`) names a set of tags (a tag
      is in at most one). It can be staff-only (only admins may apply its
      tags) and one-per-thread (a thread takes at most one of them). Both
      rules are enforced wherever tags are set (see `Forums.update_thread/3`).
      The tag picker lists tags by group.
    * A synonym stands for a canonical tag: applying it applies the
      canonical one, its page redirects there and search treats them as
      one. Making a tag a synonym moves its threads and its watchers over to
      the canonical tag, so nothing is ever tagged with a synonym.
  """

  import Ecto.Query

  alias FirestormWeb.{Forums, Repo, StaffLog}
  alias FirestormWeb.Forums.{Tag, TagGroup, TagWatch, User}

  @doc "Every group, by name, with its tags."
  def list_groups do
    TagGroup
    |> order_by(:name)
    |> preload(:tags)
    |> Repo.all()
  end

  def get_group!(id), do: TagGroup |> preload(:tags) |> Repo.get!(id)

  def change_group(group \\ %TagGroup{}, attrs \\ %{}), do: TagGroup.changeset(group, attrs)

  @doc """
  Creates a group as `actor`. A `"tags"` attribute (comma- or
  space-separated names) puts those tags in it; see `update_group/3`.
  """
  def create_group(attrs, %User{} = actor), do: save_group(%TagGroup{tags: []}, attrs, actor)

  @doc """
  Updates a group as `actor`. A `"tags"` attribute sets its tags: missing
  ones are created, tags in another group move here, tags left out leave
  the group. Synonyms can't be in a group (their canonical tag is).
  """
  def update_group(%TagGroup{} = group, attrs, %User{} = actor),
    do: save_group(Repo.preload(group, :tags), attrs, actor)

  defp save_group(group, attrs, actor) do
    changeset = TagGroup.changeset(group, attrs)
    names = Tag.parse(attrs["tags"] || attrs[:tags])
    invalid = Enum.reject(names, &Tag.valid_name?/1)

    synonyms =
      Repo.all(
        from(t in Tag, where: t.name in ^names and not is_nil(t.synonym_of_id), select: t.name)
      )

    cond do
      invalid != [] ->
        {:error,
         Ecto.Changeset.add_error(changeset, :tags, "#{Enum.join(invalid, ", ")}: invalid")}

      synonyms != [] ->
        {:error,
         Ecto.Changeset.add_error(
           changeset,
           :tags,
           "#{Enum.join(synonyms, ", ")}: a synonym can't be in a group"
         )}

      true ->
        Repo.transact(fn -> write_group(group, changeset, names, actor) end)
    end
  end

  defp write_group(group, changeset, names, actor) do
    details = StaffLog.changes(changeset)

    with {:ok, saved} <- Repo.insert_or_update(changeset) do
      ids = Enum.map(Forums.ensure_tags(names), & &1.id)

      Repo.update_all(where(Tag, [t], t.group_id == ^saved.id and t.id not in ^ids),
        set: [group_id: nil]
      )

      Repo.update_all(where(Tag, [t], t.id in ^ids), set: [group_id: saved.id])

      before = group.tags |> Enum.map(& &1.name) |> Enum.sort() |> Enum.join(", ")
      now = names |> Enum.sort() |> Enum.join(", ")

      details =
        if before == now,
          do: details,
          else: Map.put(details, :tags, %{before: before, after: now})

      cond do
        is_nil(group.id) ->
          StaffLog.record(actor, "tag_group.create", saved, Map.put(details, :name, saved.name))

        details != %{} ->
          StaffLog.record(
            actor,
            "tag_group.update",
            saved,
            Map.put_new(details, :name, saved.name)
          )

        true ->
          nil
      end

      {:ok, Repo.preload(saved, :tags, force: true)}
    end
  end

  @doc "Deletes a group as `actor`. Its tags stay, in no group."
  def delete_group(%TagGroup{} = group, %User{} = actor) do
    Repo.transact(fn ->
      with {:ok, deleted} <- Repo.delete(group) do
        StaffLog.record(actor, "tag_group.delete", deleted, %{name: deleted.name})
        {:ok, deleted}
      end
    end)
  end

  @doc "Every synonym, by name, with its canonical tag."
  def list_synonyms do
    Tag
    |> where([t], not is_nil(t.synonym_of_id))
    |> order_by(:name)
    |> preload(:synonym_of)
    |> Repo.all()
  end

  @doc """
  Makes the tag named `name` a synonym of the tag named `canonical_name`, as
  `actor`. Either is created if missing. The synonym's threads get the
  canonical tag instead, its watchers' levels move over (unless they set one
  on the canonical tag), and its own synonyms become the canonical tag's.
  """
  def make_synonym(name, canonical_name, %User{} = actor) do
    name = String.downcase(String.trim(name || ""))
    canonical_name = String.downcase(String.trim(canonical_name || ""))

    cond do
      not Tag.valid_name?(name) or not Tag.valid_name?(canonical_name) -> {:error, :invalid}
      name == canonical_name -> {:error, :same_tag}
      true -> Repo.transact(fn -> write_synonym(name, canonical_name, actor) end)
    end
  end

  defp write_synonym(name, canonical_name, actor) do
    [tag, canonical] =
      [name, canonical_name]
      |> Forums.ensure_tags()
      |> Enum.map(fn %Tag{id: id} ->
        Repo.one!(from(t in Tag, where: t.id == ^id, lock: "FOR UPDATE"))
      end)

    if canonical.synonym_of_id do
      {:error, :canonical_is_synonym}
    else
      threads = retag(tag, canonical)
      move_watches(tag, canonical)
      Repo.update_all(where(Tag, synonym_of_id: ^tag.id), set: [synonym_of_id: canonical.id])

      synonym =
        tag
        |> Ecto.Changeset.change(synonym_of_id: canonical.id, group_id: nil)
        |> Repo.update!()

      StaffLog.record(actor, "tag.synonym", synonym, %{
        name: synonym.name,
        synonym_of: canonical.name,
        threads: threads
      })

      {:ok, synonym}
    end
  end

  # Moves the tag's threads to `canonical` (once each). Returns how many.
  defp retag(tag, canonical) do
    thread_ids =
      Repo.all(
        from(tt in "forums_threads_tags", where: tt.tag_id == ^tag.id, select: tt.thread_id)
      )

    Repo.insert_all(
      "forums_threads_tags",
      Enum.map(thread_ids, &%{thread_id: &1, tag_id: canonical.id}),
      on_conflict: :nothing
    )

    Repo.delete_all(from(tt in "forums_threads_tags", where: tt.tag_id == ^tag.id))
    length(thread_ids)
  end

  defp move_watches(tag, canonical) do
    taken = from(w in TagWatch, where: w.assoc_id == ^canonical.id, select: w.user_id)

    Repo.update_all(
      from(w in TagWatch, where: w.assoc_id == ^tag.id and w.user_id not in subquery(taken)),
      set: [assoc_id: canonical.id]
    )

    Repo.delete_all(from(w in TagWatch, where: w.assoc_id == ^tag.id))
  end

  @doc """
  Makes a synonym a tag of its own again, as `actor`. Threads stay with the
  canonical tag.
  """
  def remove_synonym(%Tag{} = tag, %User{} = actor) do
    tag = Repo.preload(tag, :synonym_of)

    Repo.transact(fn ->
      with {:ok, updated} <- tag |> Ecto.Changeset.change(synonym_of_id: nil) |> Repo.update() do
        StaffLog.record(actor, "tag.unsynonym", updated, %{
          name: tag.name,
          synonym_of: tag.synonym_of && tag.synonym_of.name
        })

        {:ok, updated}
      end
    end)
  end

  @doc """
  The tags the thread forms offer, by group: `{group, tags}` pairs, groups
  by name, then `{nil, tags}` for the most used tags in no group. Staff-only
  groups are left out for members. Synonyms are never offered.
  """
  def picker(viewer) do
    staff? = not is_nil(viewer) and Forums.admin?(viewer)
    canonical = from(t in Tag, where: is_nil(t.synonym_of_id), order_by: :name)

    groups =
      TagGroup
      |> then(&if(staff?, do: &1, else: where(&1, [g], not g.staff_only)))
      |> order_by(:name)
      |> preload(tags: ^canonical)
      |> Repo.all()
      |> Enum.reject(&(&1.tags == []))
      |> Enum.map(&{&1, &1.tags})

    ungrouped =
      viewer
      |> Forums.list_tags()
      |> Enum.filter(&(is_nil(&1.group_id) and is_nil(&1.synonym_of_id)))
      |> Enum.take(20)

    if ungrouped == [], do: groups, else: groups ++ [{nil, ungrouped}]
  end

  @doc """
  The canonical name for a tag name (a synonym's canonical tag's; any other
  name as it is, downcased).
  """
  def canonical_name(name) do
    name = String.downcase(name)

    Repo.one(
      from(t in Tag,
        left_join: c in assoc(t, :synonym_of),
        where: t.name == ^name,
        select: coalesce(c.name, t.name)
      )
    ) || name
  end

  def message(:invalid), do: "Use lowercase letters, digits and dashes (30 at most)."
  def message(:same_tag), do: "A tag can't be a synonym of itself."
  def message(:canonical_is_synonym), do: "That tag is itself a synonym: use its canonical tag."
end
