defmodule Firefly.Moderation.Screening do
  @moduledoc """
  Screening lists staff keep at `/staff/screening`: email addresses (or
  `*@domain` patterns), IP addresses (or CIDR ranges) and URL domains that
  are blocked.

    * A screened email or IP can't sign up, whichever way (password,
      invitation, social login or single sign-on, email login link).
    * A post (thread, reply or edit) linking a screened domain, or written
      from a screened IP, is refused like any invalid post. Staff are
      exempt.

  The IP is the current request's, as `Firefly.Moderation.Akismet.client/0`
  holds it (set for every page and request by the web interface). Every
  block counts on its entry (`match_count`, `last_matched_at`) and is
  recorded in the staff log as the system's `screening.block`, with what
  was blocked and where. Adding and removing entries is staff-logged too.
  """

  import Ecto.Query

  require Logger

  alias Firefly.{Accounts, IPRange, Repo}
  alias Firefly.Accounts.User
  alias Firefly.Moderation.{Akismet, ScreenedItem, StaffLog}

  @doc "The entries of the `kind` list, most recently added first."
  def list(kind) when is_binary(kind) do
    Repo.all(
      from(s in ScreenedItem,
        where: s.kind == ^kind,
        order_by: [desc: s.id],
        preload: :created_by
      )
    )
  end

  @doc "How many entries each list has, by kind."
  def counts do
    counts =
      Map.new(Repo.all(from(s in ScreenedItem, group_by: s.kind, select: {s.kind, count()})))

    Map.new(ScreenedItem.kinds(), &{&1, Map.get(counts, &1, 0)})
  end

  def change(attrs \\ %{}), do: ScreenedItem.changeset(%ScreenedItem{}, attrs)

  @doc "Adds `value` to the `kind` list as `actor` (staff-logged)."
  def create(attrs, %User{} = actor) do
    Repo.transact(fn ->
      with {:ok, item} <-
             %ScreenedItem{created_by_id: actor.id}
             |> ScreenedItem.changeset(attrs)
             |> Repo.insert() do
        StaffLog.record(actor, "screening.create", {"screened_item", item.id}, %{
          kind: item.kind,
          value: item.value
        })

        {:ok, item}
      end
    end)
  end

  @doc "Removes the entry with `id` as `actor` (staff-logged)."
  def delete(id, %User{} = actor) do
    Repo.transact(fn ->
      case Repo.get(ScreenedItem, id) do
        nil ->
          {:error, :not_found}

        item ->
          Repo.delete!(item)

          StaffLog.record(actor, "screening.delete", {"screened_item", item.id}, %{
            kind: item.kind,
            value: item.value
          })

          {:ok, item}
      end
    end)
  end

  ## Checks

  @doc """
  Whether someone may sign up with `email` (nil: no address) from the
  current request's IP: `:ok`, `{:error, :screened_email}` or
  `{:error, :screened_ip}`.
  """
  def check_signup(email) do
    cond do
      item = email_match(email) -> blocked(item, email, "signup")
      item = ip_match(current_ip()) -> blocked(item, current_ip(), "signup")
      true -> :ok
    end
  end

  @doc """
  Adds an error to a post changeset (its `:body`) when the post links a
  screened domain or comes from a screened IP. Staff are exempt.
  """
  def validate_post(%Ecto.Changeset{valid?: false} = changeset, _user), do: changeset

  def validate_post(%Ecto.Changeset{} = changeset, %User{} = user) do
    body = Ecto.Changeset.get_change(changeset, :body)

    with true <- is_binary(body),
         false <- Accounts.staff?(user),
         {:error, reason} <- check_post(body) do
      Ecto.Changeset.add_error(changeset, :body, message(reason), validation: :screened)
    else
      _allowed -> changeset
    end
  end

  defp check_post(body) do
    cond do
      item = ip_match(current_ip()) -> blocked(item, current_ip(), "post")
      found = url_match(body) -> blocked(elem(found, 0), elem(found, 1), "post")
      true -> :ok
    end
  end

  @doc "What to tell someone a screening list blocked."
  def message(:screened_email), do: "can't be used to sign up here"
  def message(:screened_ip), do: "can't be used from your network: it's blocked"
  def message(:screened_url), do: "links a site that's blocked here"

  defp blocked(%ScreenedItem{} = item, what, where) do
    now = DateTime.utc_now(:second)

    Repo.update_all(from(s in ScreenedItem, where: s.id == ^item.id),
      inc: [match_count: 1],
      set: [last_matched_at: now]
    )

    StaffLog.record_system("screening.block", {"screened_item", item.id}, %{
      kind: item.kind,
      value: item.value,
      matched: what,
      during: where
    })

    Logger.info("Screened #{item.kind} #{inspect(item.value)} blocked a #{where}: #{what}")
    {:error, String.to_existing_atom("screened_" <> item.kind)}
  end

  defp current_ip, do: Akismet.client()[:ip]

  defp email_match(email) when is_binary(email) do
    email = email |> String.trim() |> String.downcase()

    Enum.find(items("email"), fn item ->
      pattern = "^" <> (item.value |> Regex.escape() |> String.replace("\\*", ".*")) <> "$"
      Regex.match?(Regex.compile!(pattern), email)
    end)
  end

  defp email_match(_none), do: nil

  defp ip_match(nil), do: nil

  defp ip_match(ip) do
    case IPRange.address(ip) do
      nil ->
        nil

      address ->
        Enum.find(items("ip"), &in_range?(&1.value, address))
    end
  end

  defp in_range?(range, address) do
    case IPRange.parse(range) do
      {:ok, range} -> IPRange.contains?(range, address)
      :error -> false
    end
  end

  # The first link in `body` to a screened domain (or a subdomain of one).
  defp url_match(body) do
    domains = items("url")

    if domains == [] do
      nil
    else
      ~r{\b(?:https?://|www\.)[^\s<>)\]"']+}i
      |> Regex.scan(body)
      |> Enum.find_value(fn [url] ->
        host = ScreenedItem.domain(url)

        item =
          host &&
            Enum.find(domains, &(host == &1.value or String.ends_with?(host, "." <> &1.value)))

        item && {item, url}
      end)
    end
  end

  defp items(kind), do: Repo.all(from(s in ScreenedItem, where: s.kind == ^kind))
end
