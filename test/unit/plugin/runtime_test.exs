defmodule FirestormWeb.Plugin.Sandboxed.RuntimeTest do
  use ExUnit.Case, async: true

  alias FirestormWeb.Plugin.Sandboxed.Runtime

  defp run(source, input \\ nil, opts \\ []), do: Runtime.run(source, "handle", input, opts)

  test "the committed runtime matches its checksum" do
    bytes = File.read!(Application.app_dir(:firestorm_web, "priv/plugins/quickjs.wasm"))
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == Runtime.checksum()
  end

  test "runs a handler with JSON in and out, sync or async" do
    assert {:ok, %{"sum" => 3}} = run("exports.handle = (x) => ({sum: x.a + x.b})", %{a: 1, b: 2})
    assert {:ok, 2} = run("exports.handle = async (x) => { await null; return x + 1 }", 1)
    assert {:ok, nil} = run("exports.handle = () => undefined")
  end

  test "host calls go through the given function, as JSON" do
    host = fn name, args -> {:ok, %{"called" => name, "with" => args}} end

    assert {:ok, %{"ok" => %{"called" => "echo", "with" => %{"v" => 2}}}} =
             run(~S|exports.handle = () => JSON.parse(firefly.__call("echo", '{"v":2}'))|, nil,
               host: host
             )

    denied = fn _name, _args -> {:error, "permission denied"} end

    assert {:ok, %{"error" => "permission denied"}} =
             run(~S|exports.handle = () => JSON.parse(firefly.__call("x", "{}"))|, nil,
               host: denied
             )
  end

  describe "sandbox escapes" do
    test "there's no filesystem, network, process or environment API" do
      assert {:ok, types} =
               run("""
               exports.handle = () => [typeof require, typeof process, typeof std, typeof os,
                 typeof fetch, typeof XMLHttpRequest, typeof WebSocket, typeof Deno, typeof scriptArgs]
               """)

      assert Enum.uniq(types) == ["undefined"]
    end

    test "modules can't be imported" do
      assert {:error, {:js_error, _}} =
               run("exports.handle = async () => { await import('fs'); return 'escaped' }")

      assert {:error, {:js_error, _}} = run("import * as os from 'os'; exports.handle = () => 1")
    end

    test "the clock is the host's and frozen for the call" do
      assert {:ok, [same, now]} =
               run("""
               exports.handle = () => {
                 const a = Date.now(); for (let i = 0; i < 100000; i++) {}
                 return [a === Date.now(), a];
               }
               """)

      assert same
      assert_in_delta now, System.os_time(:millisecond), 5_000
    end
  end

  describe "limits" do
    test "an infinite loop is stopped by the CPU budget" do
      assert {:error, {:timeout, _}} = run("exports.handle = () => { while (true) {} }")
    end

    test "a slow host call is stopped by the wall-clock limit" do
      host = fn _name, _args -> Process.sleep(1_000) && {:ok, 1} end

      assert {:error, {:timeout, _}} =
               run(~S|exports.handle = () => firefly.__call("slow", "{}")|, nil,
                 host: host,
                 timeout: 200
               )
    end

    test "memory is capped" do
      assert {:error, {:memory, _}} =
               run("exports.handle = () => new Uint8Array(64 * 1024 * 1024).length")

      assert {:ok, 1_048_576} = run("exports.handle = () => new Uint8Array(1024 * 1024).length")
    end

    test "deep recursion is an error, not a crash" do
      assert {:error, {:js_error, message}} =
               run("function f() { return f() + 1 }; exports.handle = f")

      assert message =~ "stack"
    end

    test "output is capped" do
      assert {:error, {:output_too_large, _}} =
               run("exports.handle = () => 'x'.repeat(2 * 1024 * 1024)")
    end
  end

  describe "failures are structured" do
    test "errors thrown, syntax errors, missing handlers" do
      assert {:error, {:js_error, "boom" <> _}} =
               run("exports.handle = () => { throw new Error('boom') }")

      assert {:error, {:js_error, _}} = run("exports.handle = ( =>")
      assert {:error, {:no_handler, _}} = run("exports.other = () => 1")

      assert {:error, {:js_error, _}} =
               run("exports.handle = async () => { throw new Error('later') }")
    end

    test "a value JSON can't hold" do
      assert {:error, {:js_error, _}} =
               run("exports.handle = () => { const a = {}; a.a = a; return a }")

      assert {:error, {:js_error, _}} = run("exports.handle = () => 1n")
    end

    @tag :capture_log
    test "a crashing host function doesn't take the caller down" do
      host = fn _name, _args -> raise "host bug" end

      assert {:ok, %{"error" => _}} =
               run(~S|exports.handle = () => JSON.parse(firefly.__call("x", "{}"))|, nil,
                 host: host
               )
    end
  end

  test "each call starts from a fresh instance" do
    source = "globalThis.count = (globalThis.count || 0) + 1; exports.handle = () => count"
    assert {:ok, 1} = run(source)
    assert {:ok, 1} = run(source)
  end
end
