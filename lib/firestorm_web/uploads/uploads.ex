defmodule FirestormWeb.Uploads do
  @moduledoc """
  File uploads: attachments in posts and private messages, and avatars.

  A file goes through the server (the composer's LiveView upload, or
  `POST /api/v1/uploads`): its type is checked from its content and images
  are cleaned and resized (see `FirestormWeb.Uploads.Processor`), then it's
  stored by the configured backend (see `FirestormWeb.Uploads.Storage`)
  under its sha256. The same content uploaded again is stored once: a
  member re-uploading a file they haven't used yet gets the same upload
  back, and quotas count each distinct file once.

  Limits are site settings: the largest file (`max_upload_kb`), each
  member's total (`upload_quota_mb`, 0: none) and the longest side of an
  image (`max_image_dimension`), on top of the upload rate limit.

  A new upload is attached to nothing; saving a post or message whose body
  links it (`/uploads/<token>/...`) attaches it there (see `attach/3`), and
  from then on it's served to whoever may read that post or message (see
  `readable?/2`). Uploads still unattached after the `orphan_upload_hours`
  setting are removed by `run_due/0`, unless a draft of their uploader's
  links them.
  """

  import Ecto.Query
  require Logger

  alias FirestormWeb.{Forums, Messages, RateLimit, Repo, SiteSettings, StaffLog}
  alias FirestormWeb.Forums.{Draft, Message, Post, User}
  alias FirestormWeb.Uploads.{Processor, Storage, Upload}

  @token_pattern ~r"/uploads/([A-Za-z0-9_-]{22})/"

  @doc "The largest file accepted, in bytes (the `max_upload_kb` setting)."
  def max_size, do: SiteSettings.get("max_upload_kb") * 1024

  @doc "File extensions the composer's picker offers."
  def accept, do: ~w(.png .jpg .jpeg .gif .webp .pdf .txt)

  @doc """
  Stores the file at `path` (named `filename` by its uploader) as `user`'s.
  `avatar: true` makes it the square avatar variant, attached to the user.
  Returns `{:ok, upload}`, `{:error, :rate_limited}` or `{:error, message}`.
  """
  def create(%User{} = user, path, filename, opts \\ []) do
    filename = safe_filename(filename)

    with :ok <- RateLimit.check_upload(user),
         {:ok, data} <- read(path),
         {:ok, content_type} <- Processor.detect(data, filename) do
      sha256 = Base.encode16(:crypto.hash(:sha256, data), case: :lower)
      avatar? = Keyword.get(opts, :avatar, false)

      if avatar? and not String.starts_with?(content_type, "image/"),
        do: {:error, "An avatar must be an image."},
        else: store(user, data, filename, content_type, sha256, avatar?)
    end
  end

  defp read(path) do
    case File.stat(path) do
      {:ok, %{size: 0}} -> {:error, "That file is empty."}
      {:ok, %{size: size}} -> if size > max_size(), do: too_large(), else: File.read(path)
      {:error, _reason} -> {:error, "The upload failed. Please try again."}
    end
  end

  defp too_large, do: {:error, "That file is too large (#{div(max_size(), 1024)} KB max)."}

  # Under a lock on the content's hash, so a file being removed (see
  # `remove/1`) can't vanish under an upload that reuses it.
  defp store(user, data, filename, content_type, sha256, avatar?) do
    Repo.transact(fn ->
      lock(sha256)

      with nil <- reusable(user, sha256, avatar?),
           {:ok, stored} <- stored(data, content_type, sha256, avatar?),
           :ok <- check_quota(user, sha256, stored.size) do
        %Upload{
          token: token(),
          user_id: user.id,
          filename: filename,
          content_type: content_type,
          sha256: sha256,
          attached_to: if(avatar?, do: "avatar"),
          attached_at: if(avatar?, do: DateTime.utc_now(:second))
        }
        |> Map.merge(stored)
        |> Repo.insert()
      else
        %Upload{} = upload -> {:ok, upload}
        {:error, message} -> {:error, message}
      end
    end)
  end

  defp lock(sha256), do: Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [sha256])

  # The uploader's own unused copy of the same file, to hand back again.
  defp reusable(_user, _sha256, true = _avatar?), do: nil

  defp reusable(user, sha256, false) do
    Upload
    |> where([u], u.user_id == ^user.id and u.sha256 == ^sha256 and is_nil(u.attached_to))
    |> limit(1)
    |> Repo.one()
  end

  # The stored file's details: from another upload of the same content
  # (nothing to process or store), or processed and stored now.
  defp stored(data, content_type, sha256, avatar?) do
    case Repo.one(limit(same_file(sha256, avatar?), 1)) do
      %Upload{} = existing ->
        {:ok, Map.take(existing, [:content_type, :size, :width, :height, :thumbnail])}

      nil ->
        process_and_put(data, content_type, sha256, avatar?)
    end
  end

  defp process_and_put(data, content_type, sha256, avatar?) do
    opts = [avatar: avatar?, max_dimension: SiteSettings.get("max_image_dimension")]

    upload = %Upload{
      sha256: sha256,
      content_type: content_type,
      attached_to: avatar_kind(avatar?)
    }

    with {:ok, processed} <- Processor.process(data, content_type, opts),
         :ok <- put(key(upload), processed.data, content_type),
         :ok <- put_thumbnail(upload, processed.thumbnail) do
      {:ok,
       %{
         content_type: content_type,
         size: byte_size(processed.data),
         width: processed.width,
         height: processed.height,
         thumbnail: processed.thumbnail != nil
       }}
    end
  end

  defp put_thumbnail(_upload, nil), do: :ok

  defp put_thumbnail(upload, thumbnail),
    do: put(thumbnail_key(upload), thumbnail, upload.content_type)

  defp put(key, data, content_type) do
    case Storage.put(key, data, content_type) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Storing upload #{key} failed: #{inspect(reason)}")
        {:error, "The upload couldn't be saved. Please try again."}
    end
  end

  defp avatar_kind(true), do: "avatar"
  defp avatar_kind(false), do: nil

  # Uploads sharing a stored file: the same content and variant (avatars
  # are stored cropped, apart from the rest).
  defp same_file(sha256, true = _avatar?),
    do: where(Upload, [u], u.sha256 == ^sha256 and u.attached_to == "avatar")

  defp same_file(sha256, false),
    do: where(Upload, [u], u.sha256 == ^sha256 and coalesce(u.attached_to, "") != "avatar")

  defp check_quota(user, sha256, size) do
    quota = SiteSettings.get("upload_quota_mb") * 1024 * 1024

    cond do
      quota == 0 -> :ok
      Repo.exists?(where(Upload, [u], u.user_id == ^user.id and u.sha256 == ^sha256)) -> :ok
      quota_used(user) + size <= quota -> :ok
      true -> {:error, "You've used your upload space. Remove some attachments first."}
    end
  end

  @doc "How many bytes of uploads `user` has, each distinct file counted once."
  def quota_used(%User{id: user_id}) do
    Upload
    |> where([u], u.user_id == ^user_id)
    |> distinct([u], u.sha256)
    |> select([u], %{size: u.size})
    |> subquery()
    |> select([s], type(coalesce(sum(s.size), 0), :integer))
    |> Repo.one()
  end

  defp token, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  @doc false
  def safe_filename(filename) do
    filename
    |> to_string()
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
    |> String.slice(0, 100)
    |> case do
      name when name in ["", ".", ".."] -> "file"
      name -> name
    end
  end

  ## Where uploads are stored and served

  @doc "The stored file's key in the storage backend."
  def key(%Upload{} = upload), do: blob_key(variant(upload), upload)

  @doc "The thumbnail's key in the storage backend."
  def thumbnail_key(%Upload{} = upload), do: blob_key("thumb", upload)

  defp variant(%Upload{attached_to: "avatar"}), do: "avatar"
  defp variant(%Upload{}), do: "original"

  defp blob_key(prefix, %Upload{sha256: sha256, content_type: type}),
    do: "#{prefix}/#{String.slice(sha256, 0, 2)}/#{sha256}#{Processor.extension(type)}"

  defp keys(%Upload{thumbnail: true} = upload), do: [key(upload), thumbnail_key(upload)]
  defp keys(upload), do: [key(upload)]

  @doc "The upload's URL."
  def url(%Upload{token: token, filename: filename}), do: "/uploads/#{token}/#{filename}"

  @doc "The thumbnail's URL (the file's own, for those without one)."
  def thumbnail_url(%Upload{thumbnail: true, token: token, filename: filename}),
    do: "/uploads/#{token}/thumb/#{filename}"

  def thumbnail_url(%Upload{} = upload), do: url(upload)

  @doc """
  The markdown that shows the upload in a post: an image (its thumbnail,
  linking to the full size, when it has one) or a link to download it.
  """
  def markdown(%Upload{} = upload) do
    cond do
      not Upload.image?(upload) -> "[#{upload.filename}](#{url(upload)})"
      upload.thumbnail -> "[![#{upload.filename}](#{thumbnail_url(upload)})](#{url(upload)})"
      true -> "![#{upload.filename}](#{url(upload)})"
    end
  end

  @doc "The upload with that token, or nil."
  def get_by_token(token) when is_binary(token), do: Repo.get_by(Upload, token: token)

  @doc """
  Whether `viewer` (nil: a visitor) may fetch the upload: what it's
  attached to decides (see the module doc). Staff may fetch any.
  """
  def readable?(%Upload{} = upload, viewer) do
    cond do
      upload.attached_to == "avatar" -> true
      viewer && Forums.admin?(viewer) -> true
      true -> attachment_readable?(upload, viewer)
    end
  end

  defp attachment_readable?(%Upload{attached_to: "post", post_id: post_id}, viewer)
       when is_integer(post_id) do
    case Repo.one(from(p in Post, where: p.id == ^post_id, preload: :thread)) do
      nil ->
        false

      post ->
        Post.readable_by?(post, viewer) and
          Bodyguard.permit?(Forums, :view_thread, viewer, post.thread)
    end
  end

  defp attachment_readable?(%Upload{attached_to: "message", message_id: id}, viewer)
       when is_integer(id) do
    case Repo.one(from(m in Message, where: m.id == ^id, preload: :conversation)) do
      nil -> false
      message -> Messages.participant?(message.conversation, viewer)
    end
  end

  defp attachment_readable?(%Upload{attached_to: nil, user_id: owner_id}, %User{id: owner_id}),
    do: true

  defp attachment_readable?(_upload, _viewer), do: false

  ## Attaching

  @doc "The upload tokens `body` links to."
  def tokens(body) when is_binary(body),
    do: @token_pattern |> Regex.scan(body) |> Enum.map(&Enum.at(&1, 1)) |> Enum.uniq()

  def tokens(_body), do: []

  @doc """
  Attaches the uploads `body` links to that `author` uploaded and hasn't
  used yet to `target` (a post or message). An upload already attached
  elsewhere stays there (and keeps that place's readers).
  """
  def attach(body, %User{id: author_id}, target) do
    case tokens(body) do
      [] ->
        :ok

      tokens ->
        {kind, field} = target_field(target)

        Upload
        |> where([u], u.token in ^tokens and u.user_id == ^author_id and is_nil(u.attached_to))
        |> Repo.update_all(
          set: [
            {:attached_to, kind},
            {field, target.id},
            {:attached_at, DateTime.utc_now(:second)},
            {:updated_at, NaiveDateTime.utc_now()}
          ]
        )

        :ok
    end
  end

  defp target_field(%Post{}), do: {"post", :post_id}
  defp target_field(%Message{}), do: {"message", :message_id}

  ## Avatars

  @doc "Makes the image at `path` `user`'s avatar, replacing any previous one."
  def set_avatar(%User{} = user, path, filename) do
    with {:ok, upload} <- create(user, path, filename, avatar: true) do
      previous = user.avatar_upload_id

      {:ok, user} =
        user |> Ecto.Changeset.change(avatar_upload_id: upload.id) |> Repo.update()

      if previous && previous != upload.id, do: remove_by_id(previous)
      {:ok, user}
    end
  end

  @doc "Goes back to the generated avatar."
  def remove_avatar(%User{avatar_upload_id: nil} = user), do: {:ok, user}

  def remove_avatar(%User{avatar_upload_id: id} = user) do
    {:ok, user} = user |> Ecto.Changeset.change(avatar_upload_id: nil) |> Repo.update()
    remove_by_id(id)
    {:ok, user}
  end

  @doc "The avatar upload with that id (a string from a URL), or nil."
  def get_avatar(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get_by(Upload, id: id, attached_to: "avatar")
      _invalid -> nil
    end
  end

  ## Removing

  defp remove_by_id(id) do
    case Repo.get(Upload, id) do
      nil -> :ok
      upload -> remove(upload)
    end
  end

  # Deletes the row, and the stored file once no other upload shares it.
  defp remove(%Upload{} = upload) do
    {:ok, delete_file?} =
      Repo.transact(fn ->
        lock(upload.sha256)
        Repo.delete!(upload, allow_stale: true)
        {:ok, not Repo.exists?(same_file(upload.sha256, upload.attached_to == "avatar"))}
      end)

    if delete_file?, do: Enum.each(keys(upload), &Storage.delete/1)
    :ok
  end

  @doc """
  Removes uploads attached to nothing for longer than the
  `orphan_upload_hours` setting (as of `now`), except those a draft of
  their uploader links. Returns how many went.
  """
  def run_due(now \\ DateTime.utc_now()) do
    cutoff =
      now
      |> DateTime.add(-SiteSettings.get("orphan_upload_hours"), :hour)
      |> DateTime.to_naive()

    query =
      from(u in Upload,
        as: :upload,
        where: is_nil(u.attached_to) and u.inserted_at < ^cutoff,
        where:
          not exists(
            from(d in Draft,
              where: d.user_id == parent_as(:upload).user_id,
              where: fragment("strpos(?, ?) > 0", d.body, parent_as(:upload).token)
            )
          )
      )

    orphans = Repo.all(query)
    Enum.each(orphans, &remove/1)
    length(orphans)
  end

  ## Staff

  @doc "A page of uploads, newest first, with their uploaders."
  def list(page) do
    Upload
    |> order_by(desc: :id)
    |> preload(:user)
    |> Repo.paginate(page: page, page_size: 50)
  end

  @doc """
  Deletes an upload as `admin` (e.g. content that mustn't be hosted),
  recorded in the staff log. Posts linking it show a broken link.
  """
  def delete(%Upload{} = upload, %User{} = admin) do
    upload = Repo.preload(upload, :user)

    Repo.transact(fn ->
      StaffLog.record(admin, "upload.delete", {"upload", upload.id}, %{
        filename: upload.filename,
        uploader: upload.user && upload.user.username,
        attached_to: upload.attached_to,
        post_id: upload.post_id
      })

      {:ok, upload}
    end)

    if upload.attached_to == "avatar" do
      User
      |> where([u], u.avatar_upload_id == ^upload.id)
      |> Repo.update_all(set: [avatar_upload_id: nil])
    end

    remove(upload)
  end

  ## Account data

  @doc "`user`'s uploads, for the account export."
  def export(%User{id: user_id}) do
    Upload
    |> where([u], u.user_id == ^user_id)
    |> order_by(asc: :id)
    |> Repo.all()
    |> Enum.map(fn upload ->
      upload
      |> Map.take([
        :filename,
        :content_type,
        :size,
        :sha256,
        :width,
        :height,
        :attached_to,
        :post_id,
        :message_id,
        :inserted_at
      ])
      |> Map.put(:url, url(upload))
    end)
  end

  @doc """
  For account deletion: removes `user`'s avatar and the uploads they never
  used. Those in posts and messages stay with them, as the posts and
  messages do (with the anonymized author).
  """
  def delete_account_uploads(%User{id: user_id}) do
    Upload
    |> where([u], u.user_id == ^user_id)
    |> where([u], is_nil(u.attached_to) or u.attached_to == "avatar")
    |> Repo.all()
    |> Enum.each(&remove/1)
  end
end
