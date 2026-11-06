defmodule Firefly.Uploads do
  @moduledoc """
  File uploads: attachments in posts, private messages and chat messages,
  avatars and custom emoji.

  A file goes through the server (the composer's LiveView upload, or
  `POST /api/v1/uploads`): its type is checked from its content (and must
  agree with its name and claimed type), images are cleaned and resized and
  SVGs made PNGs (see `Firefly.Uploads.Processor`), then it's stored by the
  configured backend (see `Firefly.Uploads.Storage`) under its sha256. The same content uploaded again is stored once: a
  member re-uploading a file they haven't used yet gets the same upload
  back, and quotas count each distinct file once.

  Limits are site settings: the largest file (`max_upload_kb`), each
  member's total (`upload_quota_mb`, 0: none) and the longest side of an
  image (`max_image_dimension`), on top of the upload rate limit.

  A new upload is attached to nothing; saving a post, message or chat
  message whose body links it (`/uploads/<token>/...`) attaches it there
  (see `attach/3`), and from then on it's served to whoever may read that (see
  `readable?/2`). Uploads still unattached after the `orphan_upload_hours`
  setting are removed by `run_due/0`, unless a draft of their uploader's
  links them.

  With ClamAV configured (see `Firefly.Uploads.Scanner`), a new file is
  `pending` and served to no one until it's scanned: clean, it's served as
  usual; infected, every upload of it is `quarantined` (never served, in the
  staff log) and the same file is refused from then on.
  """

  use Boundary,
    top_level?: true,
    check: [out: false],
    exports: [Upload, Processor, Storage, Storage.Local, AWS.SigV4]

  import Ecto.Query
  require Logger

  alias Firefly.{Accounts, Chat, Discussion, Jobs, Messaging, RateLimit, Repo, SiteSettings}
  alias Firefly.Moderation.StaffLog
  alias Firefly.Accounts.User
  alias Firefly.Discussion.{Draft, Post}
  alias Firefly.Messaging.Message
  alias Firefly.Uploads.{Processor, ScanWorker, Scanner, Storage, Upload}

  # Uploads stored processed their own way, attached as soon as they're made
  # (`site`: an image a site setting uses, such as the logo; `theme`: an
  # image or font a theme uses, see Firefly.Themes).
  @variants ~w(avatar background emoji preview site theme)
  @token_pattern ~r"/uploads/([A-Za-z0-9_-]{22})/"

  @doc "The largest file accepted, in bytes (the `max_upload_kb` setting)."
  def max_size, do: SiteSettings.get("max_upload_kb") * 1024

  @doc "File extensions the composer's picker offers (the `authorized_extensions` setting)."
  def accept do
    Enum.flat_map(SiteSettings.get("authorized_extensions"), fn
      "jpg" -> [".jpg", ".jpeg"]
      extension -> ["." <> extension]
    end)
  end

  @doc """
  Stores the file at `path` (named `filename` by its uploader) as `user`'s.
  `variant: "avatar"` makes it the square avatar variant, attached to the
  user; `variant: "emoji"` a custom emoji (see `Firefly.Rendering.Emoji`).
  `claimed_type:` is the type the browser or client sent, which must agree
  with the content.
  Returns `{:ok, upload}`, `{:error, :rate_limited}` or `{:error, message}`.
  """
  def create(%User{} = user, path, filename, opts \\ []) do
    with :ok <- RateLimit.check_upload(user),
         {:ok, data} <- read(path),
         do: create_from_data(user, data, filename, opts)
  end

  @doc """
  Stores `data` as the site's own upload, with no uploader (a link
  preview's image, `variant: "preview"`): no rate limit or quota applies.
  """
  def create_for_site(data, filename, opts), do: create_from_data(nil, data, filename, opts)

  @doc """
  Stores `data` (named `filename`) as `user`'s upload, for an importer (see
  `Firefly.Import`): the original site already accepted it, so no rate
  limit, size limit or quota applies. `variant:` as for `create/4`.
  """
  def import(%User{} = user, data, filename, opts \\ []),
    do: create_from_data(user, data, filename, Keyword.put(opts, :quota, false))

  defp create_from_data(user, data, filename, opts) do
    filename = safe_filename(filename)

    with {:ok, content_type} <- Processor.detect(data, filename, opts[:claimed_type]),
         :ok <- authorized(content_type, opts),
         sha256 = Base.encode16(:crypto.hash(:sha256, data), case: :lower),
         {:ok, data, content_type, filename} <- rasterize(data, content_type, filename) do
      variant = opts[:variant]

      if variant != nil and not String.starts_with?(content_type, "image/") and
           not (variant == "theme" and String.starts_with?(content_type, "font/")),
         do: {:error, "An #{variant} must be an image."},
         else: store(user, data, filename, content_type, sha256, opts)
    end
  end

  # Members' attachments must be of a type the `authorized_extensions`
  # setting allows; images the site processes itself (avatars, emoji...)
  # and imported files are checked for what they are only.
  defp authorized(content_type, opts) do
    if opts[:variant] != nil or opts[:quota] == false or
         String.trim_leading(Processor.extension(content_type), ".") in SiteSettings.get(
           "authorized_extensions"
         ),
       do: :ok,
       else: {:error, "That file type isn't allowed here."}
  end

  # An SVG becomes a PNG (see Processor.rasterize_svg/1), named so; the
  # upload keeps the SVG's sha256, so the same SVG is processed once.
  defp rasterize(data, "image/svg+xml", filename) do
    with {:ok, png} <- Processor.rasterize_svg(data),
         do: {:ok, png, "image/png", Path.rootname(filename) <> ".png"}
  end

  defp rasterize(data, content_type, filename), do: {:ok, data, content_type, filename}

  # Sobelow: the temporary file of an upload in progress (Plug or LiveView).
  # sobelow_skip ["Traversal.FileModule"]
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
  defp store(user, data, filename, content_type, sha256, opts) do
    variant = opts[:variant]

    Repo.transact(fn ->
      lock(sha256)

      with nil <- reusable(user, sha256, variant),
           {:ok, scan_status} <- scan_status(sha256),
           {:ok, stored} <- stored(data, content_type, sha256, variant),
           :ok <- check_quota(user, sha256, stored.size, opts),
           {:ok, upload} <-
             %Upload{
               token: token(),
               user_id: user && user.id,
               filename: filename,
               content_type: content_type,
               sha256: sha256,
               attached_to: variant,
               attached_at: if(variant, do: DateTime.utc_now(:second)),
               scan_status: scan_status
             }
             |> Map.merge(stored)
             |> Repo.insert() do
        scan_later(upload)
      else
        %Upload{} = upload -> {:ok, upload}
        {:error, message} -> {:error, message}
      end
    end)
  end

  # What a new upload of this content starts as: as decided for an earlier
  # upload of it, else pending while scanning is on. Quarantined content is
  # refused.
  defp scan_status(sha256) do
    decided =
      Upload
      |> where([u], u.sha256 == ^sha256 and u.scan_status != "pending")
      |> select([u], u.scan_status)
      |> order_by([u], desc: u.scan_status == "quarantined")
      |> limit(1)
      |> Repo.one()

    cond do
      decided == "quarantined" -> {:error, "That file was refused by the virus scanner."}
      decided == "clean" or not Scanner.enabled?() -> {:ok, "clean"}
      true -> {:ok, "pending"}
    end
  end

  defp scan_later(%Upload{scan_status: "pending"} = upload) do
    {:ok, _job} = Jobs.insert(ScanWorker.new(%{upload_id: upload.id, sha256: upload.sha256}))
    {:ok, upload}
  end

  defp scan_later(upload), do: {:ok, upload}

  @doc """
  Records the virus scan's verdict on `upload`'s file (see
  `Firefly.Uploads.ScanWorker`): `:clean` serves every pending upload of
  it; `{:infected, signature}` quarantines every upload of it, each
  recorded in the staff log.
  """
  def scanned(%Upload{sha256: sha256}, :clean) do
    Upload
    |> where([u], u.sha256 == ^sha256 and u.scan_status == "pending")
    |> Repo.update_all(set: [scan_status: "clean", updated_at: NaiveDateTime.utc_now()])

    :ok
  end

  def scanned(%Upload{sha256: sha256}, {:infected, signature}) do
    {:ok, quarantined} =
      Repo.transact(fn ->
        lock(sha256)

        quarantined =
          Upload
          |> where([u], u.sha256 == ^sha256 and u.scan_status != "quarantined")
          |> preload(:user)
          |> Repo.all()

        Upload
        |> where([u], u.sha256 == ^sha256)
        |> Repo.update_all(set: [scan_status: "quarantined", updated_at: NaiveDateTime.utc_now()])

        for upload <- quarantined do
          StaffLog.record_system("upload.quarantine", {"upload", upload.id}, %{
            filename: upload.filename,
            uploader: upload.user && upload.user.username,
            signature: signature
          })

          Firefly.Security.record(
            "upload.quarantine",
            upload.user_id,
            %{filename: upload.filename, signature: signature},
            ip: nil,
            user_agent: nil
          )
        end

        {:ok, quarantined}
      end)

    for upload <- quarantined, do: Logger.warning("Upload #{upload.id} quarantined: #{signature}")
    :ok
  end

  @doc "Whether the upload may be served: scanned clean, or scanning is off."
  def servable?(%Upload{scan_status: status}), do: status == "clean"

  defp lock(sha256), do: Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [sha256])

  # The uploader's own unused copy of the same file, to hand back again.
  defp reusable(user, sha256, nil = _variant) do
    Upload
    |> where([u], u.user_id == ^user.id and u.sha256 == ^sha256 and is_nil(u.attached_to))
    |> limit(1)
    |> Repo.one()
  end

  defp reusable(_user, _sha256, _variant), do: nil

  # The stored file's details: from another upload of the same content
  # (nothing to process or store), or processed and stored now.
  defp stored(data, content_type, sha256, variant) do
    case Repo.one(limit(same_file(sha256, variant), 1)) do
      %Upload{} = existing ->
        {:ok, Map.take(existing, [:content_type, :size, :width, :height, :thumbnail])}

      nil ->
        process_and_put(data, content_type, sha256, variant)
    end
  end

  defp process_and_put(data, content_type, sha256, variant) do
    opts = [variant: variant, max_dimension: SiteSettings.get("max_image_dimension")]
    upload = %Upload{sha256: sha256, content_type: content_type, attached_to: variant}

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

  # Uploads sharing a stored file: the same content and variant (avatars
  # and emoji are stored resized, apart from the rest).
  defp same_file(sha256, nil = _variant) do
    where(Upload, [u], u.sha256 == ^sha256 and coalesce(u.attached_to, "") not in ^@variants)
  end

  defp same_file(sha256, variant),
    do: where(Upload, [u], u.sha256 == ^sha256 and u.attached_to == ^variant)

  # Imports (`quota: false`) and the site's own uploads have no quota.
  defp check_quota(user, sha256, size, opts),
    do: if(opts[:quota] == false, do: :ok, else: check_quota(user, sha256, size))

  defp check_quota(nil = _site, _sha256, _size), do: :ok

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

  defp variant(%Upload{attached_to: variant}) when variant in @variants, do: variant
  defp variant(%Upload{}), do: "original"

  defp blob_key(prefix, %Upload{sha256: sha256, content_type: type}),
    do: "#{prefix}/#{String.slice(sha256, 0, 2)}/#{sha256}#{Processor.extension(type)}"

  defp variant_of(%Upload{attached_to: variant}) when variant in @variants, do: variant
  defp variant_of(%Upload{}), do: nil

  defp keys(%Upload{thumbnail: true} = upload), do: [key(upload), thumbnail_key(upload)]
  defp keys(upload), do: [key(upload)]

  @doc "The upload's URL."
  def url(%Upload{token: token, filename: filename}), do: "/uploads/#{token}/#{filename}"

  @doc """
  The stored file's bytes (for exporting a theme's assets, see
  `Firefly.Themes`): `{:ok, data}` or `{:error, reason}`.
  """
  # Sobelow: the path Storage.locate/3 builds from the upload's key.
  # sobelow_skip ["Traversal.FileModule"]
  def contents(%Upload{} = upload) do
    case Storage.locate(key(upload), upload.content_type, "attachment") do
      {:file, path} ->
        File.read(path)

      {:redirect, url} ->
        case Req.get(url, retry: false, decode_body: false) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          _failed -> {:error, :unreadable}
        end
    end
  end

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
  attached to decides (see the module doc). Staff may fetch any, but
  nobody gets one that's waiting for its virus scan or failed it.
  """
  def readable?(%Upload{} = upload, viewer) do
    cond do
      not servable?(upload) -> false
      upload.attached_to in @variants -> true
      viewer && Accounts.admin?(viewer) -> true
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
          Bodyguard.permit?(Discussion, :view_thread, viewer, post.thread)
    end
  end

  defp attachment_readable?(%Upload{attached_to: "message", message_id: id}, viewer)
       when is_integer(id) do
    case Repo.one(from(m in Message, where: m.id == ^id, preload: :conversation)) do
      nil -> false
      message -> Messaging.reader?(message.conversation, viewer)
    end
  end

  defp attachment_readable?(%Upload{attached_to: "chat", chat_message_id: id}, viewer)
       when is_integer(id),
       do: Chat.message_readable?(id, viewer)

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
  used yet to `target` (a post, message or chat message). An upload already attached
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
  defp target_field(%Chat.Message{}), do: {"chat", :chat_message_id}

  ## Profile images

  # A user's images: the upload variant and the user field holding it.
  @profile_images %{
    avatar: {"avatar", :avatar_upload_id},
    profile_background: {"background", :profile_background_upload_id},
    card_background: {"background", :card_background_upload_id}
  }

  @doc "The profile images a user can upload: `:avatar`, `:profile_background`, `:card_background`."
  def profile_images, do: Map.keys(@profile_images)

  @doc """
  Makes the image at `path` `user`'s `image` (see `profile_images/0`),
  replacing any previous one.
  """
  def set_profile_image(%User{} = user, image, path, filename)
      when is_map_key(@profile_images, image) do
    {variant, field} = @profile_images[image]

    with {:ok, upload} <- create(user, path, filename, variant: variant) do
      previous = Map.fetch!(user, field)
      {:ok, user} = user |> Ecto.Changeset.change([{field, upload.id}]) |> Repo.update()
      if previous && previous != upload.id, do: remove_by_id(previous)
      {:ok, user}
    end
  end

  @doc "Removes `user`'s `image` (an avatar goes back to the generated one)."
  def remove_profile_image(%User{} = user, image) when is_map_key(@profile_images, image) do
    {_variant, field} = @profile_images[image]

    case Map.fetch!(user, field) do
      nil ->
        {:ok, user}

      id ->
        {:ok, user} = user |> Ecto.Changeset.change([{field, nil}]) |> Repo.update()
        remove_by_id(id)
        {:ok, user}
    end
  end

  @doc "The upload of `variant` (avatar or background) with that id (a string from a URL), or nil."
  def get_profile_image(variant, id) when variant in ~w(avatar background) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> Repo.get_by(Upload, id: id, attached_to: variant)
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

  @doc "Deletes the upload, and its stored file once no other upload shares it."
  def remove(%Upload{} = upload) do
    {:ok, delete_file?} =
      Repo.transact(fn ->
        lock(upload.sha256)
        Repo.delete!(upload, allow_stale: true)
        {:ok, not Repo.exists?(same_file(upload.sha256, variant_of(upload)))}
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

    # Whoever showed it goes without.
    for {variant, field} <- Map.values(@profile_images), upload.attached_to == variant do
      User
      |> where([u], field(u, ^field) == ^upload.id)
      |> Repo.update_all(set: [{field, nil}])
    end

    remove(upload)
    # Its emoji went with it (the foreign key cascades).
    if upload.attached_to == "emoji", do: Firefly.Rendering.Emoji.image_deleted()
    :ok
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
  For account deletion: removes `user`'s avatar, backgrounds and the uploads they never
  used. Those in posts and messages stay with them, as the posts and
  messages do (with the anonymized author).
  """
  def delete_account_uploads(%User{id: user_id}) do
    Upload
    |> where([u], u.user_id == ^user_id)
    |> where([u], is_nil(u.attached_to) or u.attached_to in ["avatar", "background"])
    |> Repo.all()
    |> Enum.each(&remove/1)
  end
end
