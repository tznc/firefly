defmodule FirestormWeb.Plugin.BundleTest do
  use ExUnit.Case, async: true

  import FirestormWeb.PluginHelpers

  alias FirestormWeb.Plugin.{Bundle, Manifest}
  alias FirestormWeb.Plugin.Sandboxed.Runtime

  test "reads a valid bundle" do
    zip =
      bundle_zip(
        %{
          "permissions" => ["read"],
          "hooks" => ["enabled"],
          "settings" => [
            %{
              "key" => "color",
              "type" => "enum",
              "choices" => ["red", "blue"],
              "default" => "red"
            }
          ],
          "dependencies" => %{"other" => "~> 1.2"}
        },
        %{"index.js" => "exports.enabled = () => null;"}
      )

    assert {:ok, %Bundle{manifest: manifest, checksum: checksum}} = Bundle.read(zip)
    assert %Manifest{id: "test-plugin", source: "upload", permissions: ["read"]} = manifest
    assert [%{key: "color", default: "red", choices: ["red", "blue"]}] = manifest.settings
    assert manifest.dependencies == %{"other" => "~> 1.2"}
    assert checksum == Base.encode16(:crypto.hash(:sha256, zip), case: :lower)
  end

  test "a bundle zipped as a folder works" do
    manifest =
      Jason.encode!(%{
        "id" => "folder",
        "name" => "F",
        "version" => "1.0.0",
        "firefly" => "~> 1.0"
      })

    assert {:ok, %Bundle{manifest: %{id: "folder"}}} =
             Bundle.read(zip(%{"folder/plugin.json" => manifest, "folder/index.js" => ""}))
  end

  test "modules require each other relatively" do
    {:ok, bundle} =
      Bundle.read(
        bundle_zip(%{}, %{
          "index.js" =>
            ~S|const util = require("./lib/util"); exports.handle = (x) => util.double(x);|,
          "lib/util.js" => ~S|exports.double = (x) => require("./math.js").times(x, 2);|,
          "lib/math.js" => "exports.times = (a, b) => a * b;"
        })
      )

    assert {:ok, 42} = Runtime.run(Bundle.code(bundle), "handle", 21)
  end

  describe "malformed bundles are rejected with a reason" do
    test "not a zip, too big, no manifest, bad JSON" do
      assert {:error, "The file isn't a valid .zip."} = Bundle.read("not a zip")
      assert {:error, "The bundle is over" <> _} = Bundle.read(:binary.copy("x", 2 * 1024 * 1024))
      assert {:error, "The bundle has no plugin.json."} = Bundle.read(zip(%{"index.js" => ""}))

      assert {:error, "plugin.json isn't valid JSON."} =
               Bundle.read(zip(%{"plugin.json" => "{", "index.js" => ""}))
    end

    test "unsafe paths" do
      assert {:error, "The bundle has a file with an unsafe path" <> _} =
               Bundle.read(zip(%{"plugin.json" => "{}", "../evil.js" => ""}))
    end

    test "missing main file or assets, non-UTF-8 code" do
      assert {:error, "The bundle is missing index.js."} =
               Bundle.read(bundle_zip(%{}, %{"main.js" => ""}))

      assert {:error, "The bundle is missing widget.html."} =
               Bundle.read(bundle_zip(%{"assets" => ["widget.html"]}))

      assert {:error, "index.js must be UTF-8 text."} =
               Bundle.read(bundle_zip(%{}, %{"index.js" => <<255, 254>>}))
    end

    test "too many files" do
      files = Map.new(1..101, &{"f#{&1}.js", ""})
      assert {:error, "The bundle has more than 100 files."} = Bundle.read(bundle_zip(%{}, files))
    end
  end

  describe "manifests are validated strictly" do
    defp invalid(attrs) do
      base = %{"id" => "ok", "name" => "Ok", "version" => "1.0.0", "firefly" => "~> 1.0"}
      {:error, message} = Manifest.parse(Map.merge(base, attrs), "upload")
      message
    end

    test "unknown keys, hooks and permissions" do
      assert invalid(%{"permision" => []}) =~ ~s(unknown key "permision")
      assert invalid(%{"hooks" => ["on_boot"]}) =~ ~s(unknown hook "on_boot")
      assert invalid(%{"permissions" => ["root"]}) =~ ~s(unknown permission "root")
      assert invalid(%{"permissions" => ["read", "read"]}) =~ "repeats"
    end

    test "required fields and formats" do
      assert {:error, message} = Manifest.parse(%{}, "upload")
      assert message =~ ~s("id" is required)
      assert invalid(%{"id" => "Bad Id"}) =~ ~s("id" must be)
      assert invalid(%{"version" => "one"}) =~ "semantic version"
      assert invalid(%{"main" => "../x.js"}) =~ ~s("main")
      assert invalid(%{"dependencies" => %{"xy" => "soon"}}) =~ "version requirement"
      assert invalid(%{"priority" => -1}) =~ "priority"
    end

    test "the plugin API version must match" do
      assert invalid(%{"firefly" => "~> 2.0"}) =~ "needs Firefly plugin API ~> 2.0"
    end

    test "registry plugins aren't supported yet; source can't be faked" do
      assert invalid(%{"source" => "registry"}) =~ "registry aren't supported yet"
      assert invalid(%{"source" => "core"}) =~ ~s("source" must be "upload")
      assert invalid(%{"registry" => %{"url" => "x"}}) =~ "reserved"

      assert {:ok, %Manifest{source: "upload"}} =
               Manifest.parse(
                 %{
                   "id" => "ok",
                   "name" => "Ok",
                   "version" => "1.0.0",
                   "firefly" => "~> 1.0",
                   "source" => "upload"
                 },
                 "upload"
               )
    end

    test "settings need a type and a valid default" do
      assert invalid(%{"settings" => [%{"key" => "a"}]}) =~ "must have a type"
      assert invalid(%{"settings" => [%{"key" => "a", "type" => "integer"}]}) =~ "needs a default"

      assert invalid(%{
               "settings" => [%{"key" => "a", "type" => "integer", "default" => 5, "max" => 3}]
             }) =~
               "needs a valid default: it must be at most 3"

      assert invalid(%{"settings" => [%{"key" => "a", "type" => "enum", "default" => "x"}]}) =~
               "needs a list of choices"
    end
  end
end
