defmodule Firefly.PackagesPropertyTest do
  @moduledoc """
  Properties of `Firefly.Packages`: reading a package is total (anything
  malformed is `{:error, message}`), paths and limits hold against hostile
  zips, a theme and its tag go together, theme settings can't break out
  of their CSS declaration, and any sequence of installs, upgrades and
  uninstalls keeps every installed package's dependencies met, checked
  against a model.
  """
  use Firefly.DataCase, async: true
  use ExUnitProperties

  # :zip logs the leading "/" it drops from hostile names.
  @moduletag :capture_log

  import Firefly.Generators
  import Firefly.Fixtures

  alias Firefly.{Packages, Themes}
  alias Firefly.Packages.Archive

  defp read(zip) do
    case Packages.read(zip) do
      {:ok, %Archive{}} = ok -> ok
      {:error, message} = error when is_binary(message) -> error
    end
  end

  # A zip with exactly these names: :zip.create/3 would rewrite some (it
  # drops a leading "/"), so each is written as a placeholder of the same
  # length, then put back in the headers.
  defp zip(entries) do
    named =
      entries
      |> Enum.with_index()
      |> Enum.map(fn {{name, data}, n} ->
        placeholder =
          if String.starts_with?(name, "/"),
            do: String.pad_leading("#{n}Z", byte_size(name), "Q"),
            else: name

        {name, placeholder, data}
      end)

    {:ok, {_name, zip}} =
      :zip.create(
        ~c"p.zip",
        Enum.map(named, fn {_, p, data} -> {String.to_charlist(p), data} end),
        [:memory]
      )

    Enum.reduce(named, zip, fn {name, placeholder, _}, zip ->
      if name == placeholder, do: zip, else: :binary.replace(zip, placeholder, name, [:global])
    end)
  end

  defp valid_zip do
    map(theme_package(), fn {manifest, files} -> Archive.build(manifest, files) end)
  end

  describe "reading" do
    property "any bytes give {:ok, _} or {:error, message}" do
      check all(data <- one_of([any_binary(2_000), adversarial_text()]), max_runs: runs(200)) do
        assert {:error, _} = read(data)
      end
    end

    property "damaged packages give {:ok, _} or {:error, message}" do
      check all(
              zip <- valid_zip(),
              cuts <- list_of({integer(0..10_000), integer(0..255)}, min_length: 1, max_length: 8),
              truncate <- integer(0..10_000),
              max_runs: runs(200)
            ) do
        flipped =
          Enum.reduce(cuts, zip, fn {at, byte}, zip ->
            at = rem(at, byte_size(zip))
            <<before::binary-size(^at), _::8, rest::binary>> = zip
            <<before::binary, byte, rest::binary>>
          end)

        read(flipped)
        read(binary_part(zip, 0, rem(truncate, byte_size(zip))))
      end
    end

    property "valid theme packages read back as built" do
      check all({manifest, files} <- theme_package(), max_runs: runs(100)) do
        assert {:ok, archive} = read(Archive.build(manifest, files))
        assert archive.manifest.id == manifest["id"]
        assert archive.manifest.version == manifest["version"]
        assert archive.manifest.tags == ["theme"]
        assert archive.manifest.theme == manifest["theme"]
        assert Map.take(archive.files, Map.keys(files)) == files
      end
    end

    property "a manifest of any shape is read or refused, never crashes" do
      check all(
              {manifest, files} <- theme_package(),
              key <- member_of(~w(id name version firefly tags theme main settings dependencies
                                  optional_dependencies assets hooks permissions priority url
                                  description extra)),
              value <- json_value(),
              theme_key <- member_of(~w(name colors css head_html assets components component x)),
              theme_value <- json_value(),
              max_runs: runs(300)
            ) do
        manifest = Map.put(manifest, key, value)

        manifest =
          if is_map(manifest["theme"]),
            do: put_in(manifest, ["theme", theme_key], theme_value),
            else: manifest

        read(Archive.build(manifest, files))
      end
    end

    property "a manifest that isn't JSON, or isn't an object, is refused" do
      check all(
              json <- one_of([adversarial_text(), map(json_value(), &Jason.encode!/1)]),
              max_runs: runs(100)
            ) do
        case Jason.decode(json) do
          {:ok, map} when is_map(map) -> read(zip([{"firefly.json", json}]))
          _ -> assert {:error, _} = read(zip([{"firefly.json", json}]))
        end
      end
    end
  end

  describe "paths and limits" do
    property "paths that leave the package are refused" do
      check all(
              {manifest, files} <- theme_package(),
              prefix <- member_of(["../", "a/../../", "/", "/etc/", "..\\", "a\\..\\"]),
              name <- string(:alphanumeric, min_length: 1, max_length: 10),
              max_runs: runs(100)
            ) do
        entries = [
          {"firefly.json", Jason.encode!(manifest)},
          {prefix <> name, "x"} | Map.to_list(files)
        ]

        assert {:error, message} = read(zip(entries))
        assert message =~ "unsafe path" or message =~ "valid .zip"
      end
    end

    property "more than 200 files are refused" do
      check all(extra <- integer(201..260), max_runs: runs(5)) do
        files = for n <- 1..extra, into: %{}, do: {"f#{n}.txt", "x"}
        {manifest, _} = Enum.at(theme_package(), 0)
        assert {:error, message} = read(Archive.build(manifest, files))
        assert message =~ "more than 200 files"
      end
    end
  end

  describe "the theme tag" do
    property "a theme section and the theme tag go together" do
      check all(
              {manifest, files} <- theme_package(),
              tags <- list_of(tag_name(), max_length: 3),
              theme? <- boolean(),
              tagged? <- boolean(),
              max_runs: runs(100)
            ) do
        tags = Enum.uniq(if(tagged?, do: ["theme" | tags], else: tags))
        manifest = Map.put(manifest, "tags", tags)
        # Without a theme it's a plugin: it needs code.
        {manifest, files} =
          if theme?,
            do: {manifest, files},
            else: {Map.delete(manifest, "theme"), Map.put(files, "index.js", "")}

        result = read(Archive.build(manifest, files))

        if theme? == tagged? do
          assert {:ok, archive} = result
          assert "theme" in archive.manifest.tags == is_map(archive.manifest.theme)
        else
          assert {:error, _} = result
        end
      end
    end
  end

  describe "theme settings" do
    setup do
      %{admin: admin_fixture()}
    end

    # Whether `value` stays one declaration value: strings closed before
    # their line ends, brackets balanced, no `;`, `{`, `}` or comment
    # outside them (CSS Syntax: a newline, \r or \f ends a string badly).
    defp one_value?(value), do: scan(String.codepoints(value), nil, 0)

    defp scan([], nil, 0), do: true
    defp scan([], _string, _depth), do: false
    defp scan(["\\", _ | rest], string, depth), do: scan(rest, string, depth)
    defp scan([q | rest], q, depth), do: scan(rest, nil, depth)
    defp scan([nl | _], string, _) when string != nil and nl in ["\n", "\r", "\f"], do: false
    defp scan([_ | rest], string, depth) when string != nil, do: scan(rest, string, depth)
    defp scan([q | rest], nil, depth) when q in ["\"", "'"], do: scan(rest, q, depth)
    defp scan([o | rest], nil, depth) when o in ["(", "["], do: scan(rest, nil, depth + 1)

    defp scan([c | rest], nil, depth) when c in [")", "]"] and depth > 0,
      do: scan(rest, nil, depth - 1)

    defp scan([c | _], nil, _) when c in [")", "]", ";", "{", "}"], do: false
    defp scan(["/", "*" | _], nil, _), do: false
    defp scan([_ | rest], nil, depth), do: scan(rest, nil, depth)

    property "values can't break out of their custom property", %{admin: admin} do
      settings = [
        %{"key" => "tagline", "type" => "text", "default" => "", "label" => "T", "help" => ""},
        %{"key" => "accent", "type" => "string", "default" => "red", "label" => "A", "help" => ""}
      ]

      {manifest, files} = Enum.at(theme_package(), 0)
      manifest = Map.merge(manifest, %{"id" => "fzsettings", "settings" => settings})
      {:ok, archive} = Packages.read(Archive.build(manifest, files))
      {:ok, package} = Packages.install(archive, admin)

      check all(
              value <-
                one_of([
                  adversarial_text(10),
                  member_of([
                    "x\f;} body{display:none} :root{",
                    "(",
                    ")",
                    "a(b",
                    "\"",
                    "'",
                    "/*",
                    "\\",
                    "url(x",
                    "red;}",
                    "x\r;}",
                    "</style>"
                  ])
                ]),
              key <- member_of(["tagline", "accent"]),
              max_runs: runs(150)
            ) do
        # The form sends every setting.
        params = Map.put(%{"tagline" => "", "accent" => "red"}, key, value)

        case Packages.update_settings(package, params, admin) do
          {:ok, _} ->
            emitted =
              package.id
              |> Packages.css_variables()
              |> declaration_of(key)
              |> String.replace_prefix("--fzsettings-#{key}: ", "")
              |> String.replace_suffix(";", "")

            assert one_value?(emitted),
                   "#{inspect(value)} became #{inspect(emitted)}, which breaks out of its declaration"

          {:error, _errors} ->
            :ok
        end
      end
    end

    defp declaration_of(css, key) do
      # Declarations are "--id-key: value;" joined by spaces; the next one
      # starts with " --fzsettings-".
      css
      |> String.split(~r/ (?=--fzsettings-)/)
      |> Enum.find("", &String.starts_with?(&1, "--fzsettings-#{key}:"))
    end
  end

  describe "install, upgrade and uninstall" do
    @ids ~w(fza fzb fzc fzd)

    # Commands: install (or upgrade) a theme package at `1.minor.0`
    # requiring others, or uninstall one.
    defp command do
      one_of([
        tuple({
          constant(:install),
          member_of(@ids),
          integer(0..3),
          map_of(member_of(@ids), member_of([">= 1.0.0", "~> 1.1", "== 1.0.0", ">= 1.2.0"]),
            max_length: 2
          )
        }),
        tuple({constant(:uninstall), member_of(@ids)})
      ])
    end

    defp manifest(id, minor, deps) do
      %{
        "id" => id,
        "name" => "Package #{id}",
        "version" => "1.#{minor}.0",
        "firefly" => "~> 1.0",
        "tags" => ["theme"],
        "theme" => %{"name" => "Theme #{id}", "colors" => %{"light" => %{"primary" => "#0b6bcb"}}},
        "dependencies" => deps
      }
    end

    # The model: what installing would leave broken (requirements not met,
    # or a cycle), naively.
    defp broken?(model) do
      unmet =
        Enum.any?(model, fn {_id, {_minor, deps}} ->
          Enum.any?(deps, fn {dep, req} ->
            case model[dep] do
              nil -> true
              {minor, _} -> not Version.match?("1.#{minor}.0", req)
            end
          end)
        end)

      unmet or cyclic?(model)
    end

    defp cyclic?(model) do
      Enum.any?(Map.keys(model), fn id -> reaches?(model, id, id, MapSet.new()) end)
    end

    defp reaches?(model, from, target, seen) do
      {_minor, deps} = model[from] || {0, %{}}

      Enum.any?(Map.keys(deps), fn dep ->
        dep == target or
          (not MapSet.member?(seen, dep) and reaches?(model, dep, target, MapSet.put(seen, dep)))
      end)
    end

    defp step({:install, id, minor, deps}, model, admin) do
      expected_ok? =
        case model[id] do
          {current, _} when minor <= current -> false
          _ -> not broken?(Map.put(model, id, {minor, deps}))
        end

      {:ok, archive} = Packages.read(Archive.build(manifest(id, minor, deps), %{}))
      result = Packages.install(archive, admin)

      assert match?({:ok, _}, result) == expected_ok?,
             "install #{id} 1.#{minor}.0 #{inspect(deps)} over #{inspect(model)}: #{inspect(result)}"

      if expected_ok?, do: Map.put(model, id, {minor, deps}), else: model
    end

    defp step({:uninstall, id}, model, admin) do
      needed? =
        Enum.any?(model, fn {other, {_, deps}} -> other != id and Map.has_key?(deps, id) end)

      expected_ok? = Map.has_key?(model, id) and not needed?
      result = Packages.uninstall(id, admin)

      assert result == :ok == expected_ok?,
             "uninstall #{id} from #{inspect(model)}: #{inspect(result)}"

      if expected_ok?, do: Map.delete(model, id), else: model
    end

    defp assert_matches(model) do
      installed =
        for %{package: package} <- Packages.list(), package.package_id in @ids, into: %{} do
          {package.package_id, package.version}
        end

      assert installed == Map.new(model, fn {id, {minor, _}} -> {id, "1.#{minor}.0"} end)
      refute broken?(model)

      for id <- @ids do
        package = Packages.get(id)
        themes = if package, do: Themes.package_themes(package.id), else: []
        assert length(themes) == if(package, do: 1, else: 0)
      end
    end

    test "every sequence keeps dependencies met, as the model says" do
      admin = admin_fixture()

      check all(commands <- list_of(command(), min_length: 1, max_length: 10), max_runs: runs(15)) do
        # Each run starts from nothing installed: it's rolled back.
        Firefly.Repo.transact(fn ->
          Enum.reduce(commands, %{}, fn command, model ->
            model = step(command, model, admin)
            assert_matches(model)
            model
          end)

          {:error, :rollback}
        end)
      end
    end
  end

  describe "deep fuzzing" do
    @describetag :fuzz
    @describetag timeout: :infinity

    property "reading stays total" do
      check all(
              data <-
                one_of([
                  any_binary(5_000),
                  map(
                    {valid_zip(), list_of(integer(0..255), min_length: 1, max_length: 20),
                     integer(0..10_000)},
                    fn {zip, bytes, at} ->
                      at = rem(at, byte_size(zip))

                      binary_part(zip, 0, at) <>
                        :erlang.list_to_binary(bytes) <> binary_part(zip, at, byte_size(zip) - at)
                    end
                  )
                ]),
              max_runs: fuzz_runs()
            ) do
        read(data)
      end
    end
  end
end
