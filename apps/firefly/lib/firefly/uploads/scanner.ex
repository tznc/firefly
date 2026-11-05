defmodule Firefly.Uploads.Scanner do
  @moduledoc """
  Virus scanning of uploads with ClamAV, through a `clamd` daemon over TCP
  (its `INSTREAM` command). Off unless `FIREFLY_CLAMAV_HOST` is set
  (`config :firefly, Firefly.Uploads.Scanner, host: ..., port: 3310`).

  When it's on, a new upload starts `pending` and isn't served to anyone
  until `Firefly.Uploads.ScanWorker` has had clamd look at the stored file:
  clean, it's served as usual; infected, it's quarantined (never served,
  recorded in the staff log). While clamd can't be reached the job retries
  and the upload stays unserved: scanning fails closed.
  """

  @chunk 64 * 1024

  @doc "Whether scanning is on."
  def enabled?, do: config()[:host] not in [nil, ""]

  @doc """
  Scans `data`: `:clean`, `{:infected, signature}` or `{:error, reason}`
  (clamd unreachable, or it reported an error).
  """
  @spec scan(binary) :: :clean | {:infected, String.t()} | {:error, term}
  def scan(data) when is_binary(data) do
    opts = config()
    host = String.to_charlist(opts[:host])
    timeout = opts[:timeout] || 30_000

    with {:ok, socket} <-
           :gen_tcp.connect(host, opts[:port] || 3310, [:binary, active: false], timeout) do
      try do
        with :ok <- :gen_tcp.send(socket, "zINSTREAM\0"),
             :ok <- send_chunks(socket, data),
             :ok <- :gen_tcp.send(socket, <<0::32>>),
             {:ok, reply} <- recv_reply(socket, timeout, "") do
          parse(reply)
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp send_chunks(_socket, <<>>), do: :ok

  defp send_chunks(socket, data) do
    size = min(byte_size(data), @chunk)
    <<chunk::binary-size(^size), rest::binary>> = data

    with :ok <- :gen_tcp.send(socket, [<<size::32>>, chunk]), do: send_chunks(socket, rest)
  end

  # The reply ends with a NUL (the `z` prefix) or when clamd closes.
  defp recv_reply(socket, timeout, acc) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:ok, data} ->
        acc = acc <> data

        if String.ends_with?(acc, "\0"),
          do: {:ok, acc},
          else: recv_reply(socket, timeout, acc)

      {:error, :closed} when acc != "" ->
        {:ok, acc}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def parse(reply) do
    reply = reply |> String.trim_trailing("\0") |> String.trim()

    cond do
      String.ends_with?(reply, " OK") ->
        :clean

      String.ends_with?(reply, " FOUND") ->
        signature =
          reply |> String.trim_trailing(" FOUND") |> String.split(": ", parts: 2) |> List.last()

        {:infected, signature}

      true ->
        {:error, {:clamd, reply}}
    end
  end

  defp config, do: Application.get_env(:firefly, __MODULE__, [])
end
