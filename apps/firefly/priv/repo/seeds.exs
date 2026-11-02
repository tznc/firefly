# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# Inside the script, you can read and write to any of your
# repositories directly:
#
#     Firefly.Repo.insert!(%Firefly.SomeSchema{})
#
# We recommend using the bang functions (`insert!`, `update!`
# and so on) as they will fail if something goes wrong.
alias Firefly.{Discussion, Groups}

IO.puts("~~~~~ INITIALIZING FIREFLY SEEDS ~~~~~")
IO.puts("-- CREATING ROLES --")

{:ok, admin_role} =
  Groups.create_role("admin")

IO.puts("-- CREATING USERS --")

IO.puts("---- Admin von Hornclaw ----")

{:ok, admin} =
  Discussion.login_or_register_from_identity(%{
    username: "admin",
    password: "password"
  })

{:ok, _} = Groups.add_role(admin, admin_role)

IO.puts("---- Bob Vladbob ----")

{:ok, bob} =
  Discussion.login_or_register_from_identity(%{
    username: "bob",
    password: "password"
  })

IO.puts("---- Alice McStinkerton ----")

{:ok, alice} =
  Discussion.login_or_register_from_identity(%{
    username: "alice",
    password: "password"
  })

IO.puts("-- CREATING CATEGORIES --")
IO.puts("---- Elixir ----")

{:ok, elixir} =
  Discussion.create_category(%{title: "Elixir"})

IO.puts("---- Elm ----")

{:ok, elm} =
  Discussion.create_category(%{title: "Elm"})

IO.puts("-- CREATING THREADS --")
IO.puts("---- OTP is cool ----")

{:ok, otp_is_cool} =
  Discussion.create_thread(elixir, bob, %{title: "OTP is cool", body: "Don't you think?"})

{:ok, _elm_mdl} =
  Discussion.create_thread(elm, alice, %{
    title: "elm-mdl",
    body: "What's the story on this library these days?"
  })

IO.puts("-- CREATING POSTS --")
{:ok, _otp_post} = Discussion.create_post(otp_is_cool, alice, %{body: "I really do"})
