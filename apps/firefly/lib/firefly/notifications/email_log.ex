defmodule Firefly.Notifications.EmailLog do
  @moduledoc """
  The log of emails Firefly sent or tried to send (see `Firefly.Mailer`):
  to whom, the subject, which template (see
  `Firefly.Notifications.Emails`), and whether it was `sent`, `skipped`
  (no recipient) or `failed` (with the error). Staff read it at
  `/staff/emails`; entries older than the `email_log_days` site setting
  are pruned.
  """

  use Ecto.Schema

  import Ecto.Query

  require Logger

  alias Firefly.{Mailer, Repo, SiteSettings}
  alias Firefly.Accounts.User
  alias Firefly.Moderation.StaffLog
  alias Firefly.Notifications.Emails

  @statuses ~w(sent skipped failed)

  schema "email_logs" do
    field(:to, :string)
    field(:subject, :string)
    field(:template, :string)
    field(:status, :string)
    field(:error, :string)
    belongs_to(:user, User)

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc "The statuses: `sent`, `skipped` and `failed`."
  def statuses, do: @statuses

  @doc """
  Records an attempt to send `email` with the mailer's `result`. A failure
  to record is logged, never raised: the email went (or didn't) either way.
  """
  def record(%Swoosh.Email{} = email, result) do
    to = recipients(email)
    {status, error} = status(to, result)

    Repo.insert!(%__MODULE__{
      to: String.slice(to, 0, 255),
      subject: email.subject || "",
      template: email.private[:template] || "other",
      status: status,
      error: error,
      user_id: user_id(to)
    })

    :ok
  rescue
    error -> Logger.error("Couldn't record an email in the log: " <> Exception.message(error))
  end

  defp status("", _result), do: {"skipped", nil}
  defp status(_to, {:error, error}), do: {"failed", describe(error)}
  defp status(_to, _sent), do: {"sent", nil}

  @doc "A mailer error (an adapter's reason or an exception), as text."
  def describe(error) when is_binary(error), do: error
  def describe(error) when is_exception(error), do: Exception.message(error)
  # An HTTP API's answer, e.g. SendGrid's `{401, %{"errors" => ...}}`.
  def describe({status, body}) when is_integer(status),
    do: "HTTP #{status}: " <> if(is_binary(body), do: body, else: inspect(body))

  def describe(error), do: inspect(error)

  @doc "An email's recipients' addresses, comma-separated (`\"\"` for none)."
  def recipients(%Swoosh.Email{to: to}) do
    to
    |> List.wrap()
    |> Enum.map(fn
      {_name, address} -> address
      address -> address
    end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(", ")
  end

  # The member the email went to, when it went to exactly one address of one.
  defp user_id(""), do: nil

  defp user_id(to) do
    Repo.one(
      from(u in User,
        where: fragment("lower(?)", u.email) == ^String.downcase(to),
        order_by: u.id,
        limit: 1,
        select: u.id
      )
    )
  end

  @doc """
  A page of the log, newest first, with users. Filters (string keys):
  `"status"`, `"template"` and `"q"` (part of the address or subject).
  """
  def list(filters, page) do
    __MODULE__
    |> filter(:status, filters["status"])
    |> filter(:template, filters["template"])
    |> search(filters["q"])
    |> order_by(desc: :id)
    |> preload(:user)
    |> Repo.paginate(page: page, page_size: 50)
  end

  defp filter(query, _field, blank) when blank in [nil, ""], do: query
  defp filter(query, field, value), do: where(query, [e], field(e, ^field) == ^value)

  defp search(query, q) when is_binary(q) and q != "" do
    pattern = "%" <> String.replace(String.trim(q), ~r/[\\%_]/, "\\\\\\0") <> "%"
    where(query, [e], ilike(e.to, ^pattern) or ilike(e.subject, ^pattern))
  end

  defp search(query, _blank), do: query

  @doc """
  Sends a test email to `address` as `admin` (staff-logged as
  `email.test`): `:ok`, `{:error, :invalid_address}` or `{:error, reason}`
  when it couldn't be sent (the log has it too).
  """
  def send_test(address, %User{} = admin) do
    address = String.trim(address || "")

    if address =~ ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/ do
      StaffLog.record(admin, "email.test", {"email", nil}, %{to: address})

      case Mailer.deliver_now(Emails.test_email(address)) do
        {:error, error} -> {:error, error}
        _sent -> :ok
      end
    else
      {:error, :invalid_address}
    end
  rescue
    error -> {:error, error}
  end

  @doc "How many emails were sent, skipped and failed in the last day, by status."
  def last_day_counts do
    since = DateTime.add(DateTime.utc_now(:second), -1, :day)

    counts =
      Map.new(
        Repo.all(
          from(e in __MODULE__,
            where: e.inserted_at > ^since,
            group_by: e.status,
            select: {e.status, count()}
          )
        )
      )

    Map.new(@statuses, &{&1, Map.get(counts, &1, 0)})
  end

  @doc """
  Prunes entries older than the `email_log_days` setting, once an hour
  across nodes (see `Firefly.Jobs.Periodic`). Returns how many went.
  """
  def run_due(now \\ DateTime.utc_now(:second)) do
    cutoff = DateTime.add(now, -SiteSettings.get("email_log_days"), :day)
    {count, _} = Repo.delete_all(from(e in __MODULE__, where: e.inserted_at < ^cutoff))
    count
  end
end
