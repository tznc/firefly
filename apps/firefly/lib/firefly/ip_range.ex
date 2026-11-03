defmodule Firefly.IPRange do
  @moduledoc """
  Addresses and CIDR ranges as text: parsing them and testing whether an
  address falls in one. Used by API keys' allowlists
  (`Firefly.Accounts.ApiKeys`) and the trusted proxies the client IP is
  read from (`FireflyWeb.ClientIP`).
  """

  import Bitwise

  @typedoc "A parsed range: an address and how many of its leading bits matter."
  @type t :: {:inet.ip_address(), non_neg_integer()}

  @doc """
  Parses `"10.0.0.0/8"`, `"192.168.1.5"` or an IPv6 equivalent:
  `{:ok, range}` or `:error`.
  """
  @spec parse(String.t()) :: {:ok, t()} | :error
  def parse(range) when is_binary(range) do
    {address, bits} =
      case String.split(String.trim(range), "/", parts: 2) do
        [address, bits] -> {parse_address(address), Integer.parse(bits)}
        [address] -> {parse_address(address), :host}
      end

    max = if is_tuple(address) and tuple_size(address) == 8, do: 128, else: 32

    case {address, bits} do
      {nil, _bits} -> :error
      {address, :host} -> {:ok, {address, max}}
      {address, {bits, ""}} when bits in 0..max//1 -> {:ok, {address, bits}}
      _invalid -> :error
    end
  end

  @doc "`parse/1`, raising on an invalid range."
  @spec parse!(String.t()) :: t()
  def parse!(range) do
    case parse(range) do
      {:ok, parsed} -> parsed
      :error -> raise ArgumentError, "invalid address or range #{inspect(range)}"
    end
  end

  @doc "An address (a tuple, or text), or nil when it doesn't parse."
  @spec address(String.t() | :inet.ip_address()) :: :inet.ip_address() | nil
  def address(address) when is_tuple(address), do: address
  def address(address), do: parse_address(to_string(address))

  @doc "Whether `address` falls in any of the parsed `ranges`."
  @spec member?(:inet.ip_address() | nil, [t()]) :: boolean()
  def member?(nil, _ranges), do: false
  def member?(address, ranges), do: Enum.any?(ranges, &contains?(&1, address))

  @doc "Whether the parsed `range` contains `address`."
  @spec contains?(t(), :inet.ip_address()) :: boolean()
  def contains?({network, bits}, address) when tuple_size(address) == tuple_size(network) do
    size = if tuple_size(address) == 4, do: 8, else: 16
    shift = tuple_size(address) * size - bits
    to_integer(address, size) >>> shift == to_integer(network, size) >>> shift
  end

  def contains?(_range, _address), do: false

  defp to_integer(address, size),
    do: address |> Tuple.to_list() |> Enum.reduce(0, &(&2 <<< size ||| &1))

  defp parse_address(string) do
    case :inet.parse_strict_address(String.to_charlist(string)) do
      {:ok, address} -> address
      {:error, _reason} -> nil
    end
  end
end
