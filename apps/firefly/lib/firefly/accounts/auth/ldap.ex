defmodule Firefly.Accounts.Auth.LDAP do
  @moduledoc """
  Logging in with a directory's username and password (OpenLDAP, Active
  Directory, FreeIPA...), through OTP's `:eldap`. Configured by the
  deployment (`FIREFLY_LDAP_*`, see `config/runtime.exs`):

      config :firefly, Firefly.Accounts.Auth.LDAP,
        host: "ldap.example.com", port: 389,
        encryption: "starttls",          # or "ldaps", or "none"
        verify: true, ca_cert_file: "/etc/ssl/ldap-ca.pem",
        bind_dn: "cn=firefly,ou=services,dc=example,dc=com", bind_password: "...",
        base_dn: "ou=people,dc=example,dc=com",
        user_filter: "(uid=%{username})",
        uid_attribute: "entryUUID", username_attribute: "uid",
        email_attribute: "mail", name_attribute: "cn",
        group_base_dn: "ou=groups,dc=example,dc=com",
        group_filter: "(member=%{dn})", group_name_attribute: "cn",
        name: "Example directory"

  A login searches (as the bind DN, or anonymously without one) under the
  base DN for exactly one entry matching the user filter, then binds as
  that entry with the password given; an empty password never gets that
  far (it would be an anonymous bind, which servers accept). TLS (LDAPS
  or StartTLS) verifies the server's certificate against `ca_cert_file`,
  else the system's CAs, and its hostname, unless `verify` is off.

  Accounts link by the entry's `uid_attribute` (provider `"ldap"` in
  `user_identities`, see `Firefly.Accounts.Auth`); a directory email links
  to the confirmed local account with it. With a group base DN, each login
  makes the member's groups those of the directory's groups (by name) that
  exist here (see `Firefly.Accounts.Auth.GroupSync`).

  With the `ldap_replaces_password` setting on, the directory replaces
  local passwords (and the email links and passkeys that go with them).
  """

  require Record

  alias Firefly.Accounts.Auth
  alias Firefly.Accounts.Auth.GroupSync
  alias Firefly.Accounts.Auth.LDAP.Filter

  Record.defrecordp(
    :eldap_search,
    Record.extract(:eldap_search, from_lib: "eldap/include/eldap.hrl")
  )

  @timeout 5_000
  @defaults [
    port: nil,
    encryption: "starttls",
    verify: true,
    user_filter: "(uid=%{username})",
    uid_attribute: "entryUUID",
    username_attribute: "uid",
    email_attribute: "mail",
    name_attribute: "cn",
    group_filter: "(member=%{dn})",
    group_name_attribute: "cn"
  ]

  defp config do
    config = Application.get_env(:firefly, __MODULE__, [])
    Keyword.merge(@defaults, Enum.reject(config, fn {_key, value} -> value in [nil, ""] end))
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  @doc "Whether a host and base DN are configured."
  def enabled?, do: present?(config()[:host]) and present?(config()[:base_dn])

  @doc "The directory's name for people (`name`), by default \"LDAP\"."
  def label, do: if(present?(config()[:name]), do: config()[:name], else: "LDAP")

  @doc """
  Checks `username` and `password` against the directory: `{:ok, entry}`
  (`dn`, `uid`, `username`, `email`, `name`, `groups`; groups nil without
  a group base DN) or `{:error, :invalid_credentials}` (also for unknown
  or ambiguous usernames) or `{:error, :unavailable}` (the directory, or
  its configuration).
  """
  def authenticate(username, password)
      when is_binary(username) and is_binary(password) and password != "" do
    username = String.trim(username)

    if username == "" or byte_size(username) > 256,
      do: {:error, :invalid_credentials},
      else: with_connection(&find_and_bind(&1, username, password))
  end

  def authenticate(_username, _password), do: {:error, :invalid_credentials}

  defp with_connection(fun) do
    case connect() do
      {:ok, handle} ->
        try do
          fun.(handle)
        after
          :eldap.close(handle)
        end

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  defp connect do
    config = config()
    host = String.to_charlist(config[:host])
    tls = tls_options(config)

    case config[:encryption] do
      "ldaps" ->
        :eldap.open([host],
          port: config[:port] || 636,
          ssl: true,
          sslopts: tls,
          timeout: @timeout
        )

      encryption ->
        with {:ok, handle} <- :eldap.open([host], port: config[:port] || 389, timeout: @timeout) do
          start_tls(handle, encryption, tls)
        end
    end
  end

  defp start_tls(handle, "none", _tls), do: {:ok, handle}

  defp start_tls(handle, _starttls, tls) do
    case :eldap.start_tls(handle, tls, @timeout) do
      :ok ->
        {:ok, handle}

      error ->
        :eldap.close(handle)
        {:error, error}
    end
  end

  defp tls_options(config) do
    if config[:verify] in [false, "false"] do
      [verify: :verify_none]
    else
      cacerts =
        if present?(config[:ca_cert_file]),
          do: [cacertfile: String.to_charlist(config[:ca_cert_file])],
          else: [cacerts: :public_key.cacerts_get()]

      [
        verify: :verify_peer,
        server_name_indication: String.to_charlist(config[:host]),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++ cacerts
    end
  end

  defp find_and_bind(handle, username, password) do
    config = config()

    with :ok <- service_bind(handle, config),
         {:ok, filter} <- filter(config[:user_filter], %{"username" => username}),
         {:ok, {dn, attributes}} <- find_user(handle, config, filter),
         {:ok, groups} <- groups(handle, config, dn, username),
         :ok <- user_bind(handle, dn, password) do
      {:ok,
       %{
         dn: dn,
         uid: uid(dn, attributes, config[:uid_attribute]),
         username: first(attributes, config[:username_attribute]),
         email: first(attributes, config[:email_attribute]),
         name: first(attributes, config[:name_attribute]),
         groups: groups
       }}
    end
  end

  defp filter(template, values) do
    case Filter.parse(template, values) do
      {:ok, filter} -> {:ok, filter}
      {:error, _invalid} -> {:error, :unavailable}
    end
  end

  defp service_bind(handle, config) do
    if present?(config[:bind_dn]) do
      case :eldap.simple_bind(
             handle,
             chars(config[:bind_dn]),
             chars(config[:bind_password] || "")
           ) do
        :ok -> :ok
        _error -> {:error, :unavailable}
      end
    else
      :ok
    end
  end

  defp user_bind(handle, dn, password) do
    case :eldap.simple_bind(handle, chars(dn), chars(password)) do
      :ok -> :ok
      _error -> {:error, :invalid_credentials}
    end
  end

  defp find_user(handle, config, filter) do
    attributes =
      Enum.map(
        [:uid_attribute, :username_attribute, :email_attribute, :name_attribute],
        &chars(config[&1])
      )

    case search(handle, config[:base_dn], filter, attributes, 2) do
      {:ok, [{dn, attributes}]} -> {:ok, {dn, attributes}}
      {:ok, _none_or_several} -> {:error, :invalid_credentials}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  defp groups(handle, config, dn, username) do
    if present?(config[:group_base_dn]) do
      with {:ok, filter} <- filter(config[:group_filter], %{"dn" => dn, "username" => username}),
           {:ok, entries} <-
             search(
               handle,
               config[:group_base_dn],
               filter,
               [chars(config[:group_name_attribute])],
               1000
             ) do
        {:ok,
         entries
         |> Enum.flat_map(fn {_dn, attrs} -> values(attrs, config[:group_name_attribute]) end)
         |> Enum.uniq()}
      else
        {:error, _reason} -> {:error, :unavailable}
      end
    else
      {:ok, nil}
    end
  end

  defp search(handle, base, filter, attributes, size_limit) do
    # The record form: the keyword form's type leaves out `size_limit`.
    query =
      eldap_search(
        base: chars(base),
        filter: filter,
        scope: :eldap.wholeSubtree(),
        attributes: attributes,
        size_limit: size_limit
      )

    case :eldap.search(handle, query) do
      {:ok, result} when elem(result, 0) == :eldap_search_result ->
        search_result(elem(result, 1))

      {:ok, _referral} ->
        {:error, :referral}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp search_result(entries) do
    {:ok,
     for {:eldap_entry, dn, attributes} <- entries do
       {to_string(dn),
        Map.new(attributes, fn {name, vals} -> {String.downcase(to_string(name)), vals} end)}
     end}
  end

  defp values(attributes, name) do
    attributes
    |> Map.get(String.downcase(name), [])
    |> Enum.map(&text/1)
  end

  defp first(attributes, name), do: attributes |> values(name) |> Enum.find(&present?/1)

  # A binary id (Active Directory's objectGUID) as hex; the entry's DN when
  # there's no such attribute.
  defp uid(dn, attributes, name) do
    case Map.get(attributes, String.downcase(name), []) do
      [value | _] ->
        value = :erlang.list_to_binary(value)
        if String.printable?(value), do: value, else: Base.encode16(value, case: :lower)

      [] ->
        dn
    end
  end

  defp text(value), do: value |> :erlang.list_to_binary() |> String.trim()

  defp chars(value), do: :binary.bin_to_list(value)

  @doc "What `Firefly.Accounts.Auth.login/2` and `connect/2` use from an entry."
  def info(entry) do
    %{
      provider: :ldap,
      uid: entry.uid,
      nickname: entry.username,
      name: entry.name,
      email: entry.email,
      # The directory's addresses are the organization's own.
      email_verified: true
    }
  end

  @doc """
  Logs in (or links, or registers) the directory account `username` with
  `password`, then syncs its groups.
  """
  def login(username, password, invite \\ nil) do
    with {:ok, entry} <- authenticate(username, password),
         {:ok, user} <- Auth.login(info(entry), invite) do
      {:ok, sync(user, entry)}
    end
  end

  @doc "Brings `user`'s groups in line with the directory's, when groups are configured."
  def sync(user, %{groups: nil}), do: user

  def sync(user, %{groups: groups}) do
    GroupSync.mirror(user, groups)
    user
  end

  @doc "A message for an `authenticate/2` error."
  def message(:invalid_credentials), do: "Wrong #{label()} username or password."
  def message(:unavailable), do: "#{label()} can't be reached right now. Try again later."
  def message(reason) when is_binary(reason), do: reason
end
