defmodule Firefly.LDAPTestDirectory do
  @moduledoc """
  The OpenLDAP server the `:ldap`-tagged tests log in against: the
  `ghcr.io/rroemhild/docker-test-openldap` image (Planet Express's staff:
  `fry`/`fry`, `leela`/`leela`...), on `localhost` ports 10389 (LDAP and
  StartTLS) and 10636 (LDAPS), or `FIREFLY_TEST_LDAP_HOST`. CI runs it as a
  service; locally:

      docker run -d -p 10389:10389 -p 10636:10636 ghcr.io/rroemhild/docker-test-openldap:master
      mix test --include ldap
  """

  # Test support, for any app's tests: unchecked.
  use Boundary, top_level?: true, check: [in: false, out: false]

  @doc "The directory's configuration (see `Firefly.Accounts.Auth.LDAP`), with `overrides`."
  def config(overrides \\ []) do
    Keyword.merge(
      [
        host: System.get_env("FIREFLY_TEST_LDAP_HOST", "localhost"),
        port: 10389,
        # Its certificate is self-signed for planetexpress.com.
        encryption: "starttls",
        verify: false,
        bind_dn: "cn=admin,dc=planetexpress,dc=com",
        bind_password: "GoodNewsEveryone",
        base_dn: "ou=people,dc=planetexpress,dc=com",
        user_filter: "(&(objectClass=inetOrgPerson)(uid=%{username}))",
        group_base_dn: "ou=people,dc=planetexpress,dc=com",
        group_filter: "(&(objectClass=Group)(member=%{dn}))",
        name: "Planet Express"
      ],
      overrides
    )
  end

  @doc "Configures the directory for the current test (restored when it ends)."
  def configure(overrides \\ []) do
    original = Application.get_env(:firefly, Firefly.Accounts.Auth.LDAP)
    Application.put_env(:firefly, Firefly.Accounts.Auth.LDAP, config(overrides))

    ExUnit.Callbacks.on_exit(fn ->
      if original,
        do: Application.put_env(:firefly, Firefly.Accounts.Auth.LDAP, original),
        else: Application.delete_env(:firefly, Firefly.Accounts.Auth.LDAP)
    end)
  end
end
