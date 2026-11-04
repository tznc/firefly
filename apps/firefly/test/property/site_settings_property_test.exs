defmodule Firefly.SiteSettingsPropertyTest do
  @moduledoc """
  Properties of `Firefly.SiteSettings`: every setting's default and every
  value it accepts survive being stored and read back (cast, dump, cast
  again); anything else is refused with a message, never a crash; and
  saving through `update/2` stores what `get/1` then returns.
  """
  # Sync: it saves site settings, which concurrent tests' transactions lock.
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.SiteSettings

  # How a value is stored (the column is text): as SiteSettings stores it.
  defp dump(value) when is_list(value), do: Enum.join(value, ",")
  defp dump(value), do: to_string(value)

  defp definitions, do: SiteSettings.definitions()

  # Values a setting of this type might be given: valid ones, and not.
  defp raw(%{type: :boolean}),
    do: one_of([member_of(["true", "false", "1", "0", "on", "", "TRUE"]), boolean()])

  defp raw(%{type: :integer} = d),
    do:
      one_of([
        map(integer((d.min - 5)..(d.max + 5)), &Integer.to_string/1),
        map(integer(), &Integer.to_string/1),
        member_of(["", " 5 ", "+3", "1.5", "1e3", "0x10", "٣", String.duplicate("9", 40)])
      ])

  defp raw(%{type: :select, options: options}),
    do: one_of([member_of(Enum.map(options, &elem(&1, 1))), adversarial_text(3)])

  defp raw(%{type: :list} = d) do
    item =
      if d[:options],
        do: one_of([member_of(d.options), adversarial_text(2)]),
        else:
          one_of([
            string(:alphanumeric, max_length: 20),
            adversarial_text(3),
            member_of(["a,b", "x\ny", " , "])
          ])

    one_of([
      map(list_of(item, max_length: 5), &Enum.join(&1, ",")),
      map(list_of(item, max_length: 5), &Enum.join(&1, "\n")),
      list_of(item, max_length: 5)
    ])
  end

  defp raw(%{type: :color}),
    do: one_of([hex_color(), map(hex_color(), &(" " <> &1 <> "\n")), adversarial_text(3)])

  defp raw(%{type: :email}), do: one_of([email(), adversarial_text(4), constant("")])

  defp raw(%{type: :upload}),
    do:
      one_of([
        constant(""),
        map(string(:alphanumeric, min_length: 1), &"/uploads/ab12/#{&1}.png"),
        map(adversarial_text(3), &("/uploads/" <> &1))
      ])

  defp raw(_text_or_string),
    do: one_of([adversarial_text(), long_string(600), string(:printable, max_length: 120)])

  test "every default survives being stored and read back" do
    for definition <- definitions() do
      assert SiteSettings.cast(definition, dump(definition.default)) == {:ok, definition.default},
             "#{definition.key}'s default #{inspect(definition.default)} doesn't survive storing"
    end
  end

  property "accepted values survive being stored and read back; others are refused" do
    check all(
            definition <- member_of(definitions()),
            value <- raw(definition),
            max_runs: runs(400)
          ) do
      case SiteSettings.cast(definition, value) do
        {:ok, cast} ->
          assert SiteSettings.cast(definition, dump(cast)) == {:ok, cast},
                 "#{definition.key}: #{inspect(value)} was taken as #{inspect(cast)}, stored as #{inspect(dump(cast))}"

        {:error, message} ->
          assert is_binary(message)
      end
    end
  end

  property "values of the wrong shape are refused, never crash" do
    check all(
            definition <- member_of(definitions()),
            value <- one_of([json_value(), any_text()]),
            max_runs: runs(300)
          ) do
      assert match?({:ok, _}, SiteSettings.cast(definition, value)) or
               match?(
                 {:error, message} when is_binary(message),
                 SiteSettings.cast(definition, value)
               )
    end
  end

  test "what update/2 saves is what get/1 returns" do
    admin = admin_fixture()

    check all(
            definition <-
              member_of(Enum.reject(definitions(), &(&1[:secret] || System.get_env(&1.env)))),
            value <- raw(definition),
            max_runs: runs(60)
          ) do
      case SiteSettings.update(%{definition.key => value}, admin) do
        {:ok, _changes} ->
          {:ok, expected} = SiteSettings.cast(definition, value)
          assert SiteSettings.get(definition.key) == expected

        {:error, %{} = errors} ->
          assert Map.keys(errors) == [definition.key]
      end
    end
  end

  test "importing settings of any shape saves them or says why, never crashes" do
    admin = admin_fixture()
    keys = Enum.map(definitions(), & &1.key)

    check all(
            settings <-
              map_of(
                one_of([member_of(keys), adversarial_text(2)]),
                one_of([json_value(), adversarial_text()]),
                max_length: 4
              ),
            max_runs: runs(30)
          ) do
      assert match?(
               {:ok, %{changed: _, skipped: _}},
               Firefly.SiteSettings.Transfer.import(settings, admin)
             ) or
               match?({:error, %{}}, Firefly.SiteSettings.Transfer.import(settings, admin))
    end
  end

  describe "deep fuzzing" do
    @describetag :fuzz
    @describetag timeout: :infinity

    property "casting stays total and round-trips" do
      check all(
              definition <- member_of(definitions()),
              value <- one_of([raw(definition), json_value(), any_text()]),
              max_runs: fuzz_runs()
            ) do
        case SiteSettings.cast(definition, value) do
          {:ok, cast} -> assert SiteSettings.cast(definition, dump(cast)) == {:ok, cast}
          {:error, message} -> assert is_binary(message)
        end
      end
    end
  end
end

defmodule Firefly.SiteSettingsEnvPropertyTest do
  @moduledoc "Environment pins win over stored values (sync: it sets environment variables)."
  use Firefly.DataCase, async: false
  use ExUnitProperties

  import Firefly.Fixtures

  alias Firefly.SiteSettings

  test "a pinned setting reads the environment's value, and can't be changed here" do
    admin = admin_fixture()

    pinnable =
      Enum.filter(SiteSettings.definitions(), &(&1.type in [:integer, :boolean, :string]))

    check all(definition <- StreamData.member_of(pinnable), max_runs: Firefly.Generators.runs(30)) do
      {pinned, other} =
        case definition do
          %{type: :integer, min: min, max: max} -> {to_string(max), to_string(min)}
          %{type: :boolean, default: default} -> {to_string(not default), to_string(default)}
          %{type: :string} -> {"Pinned value", "Other value"}
        end

      System.put_env(definition.env, pinned)

      try do
        {:ok, expected} = SiteSettings.cast(definition, pinned)
        assert SiteSettings.get(definition.key) == expected
        assert SiteSettings.env_override(definition.key) == definition.env

        assert {:error, %{} = errors} = SiteSettings.update(%{definition.key => other}, admin)
        assert errors[definition.key] =~ definition.env
        assert SiteSettings.get(definition.key) == expected
      after
        System.delete_env(definition.env)
      end

      assert SiteSettings.env_override(definition.key) == nil
    end
  end
end
