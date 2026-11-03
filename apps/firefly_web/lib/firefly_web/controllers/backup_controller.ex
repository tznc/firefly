defmodule FireflyWeb.BackupController do
  @moduledoc """
  Downloads a backup (admins only, behind the `:admin` pipeline) through a
  signed link from `/staff/backups` that works for 5 minutes, for the
  admin who asked (see `Firefly.Backups.download/2`).
  """
  use FireflyWeb, :controller

  alias Firefly.Backups

  def download(conn, %{"token" => token}) do
    case Backups.download(token, conn.assigns.current_user) do
      {:ok, name, {:file, path}} ->
        send_download(conn, {:file, path}, filename: name, content_type: "application/gzip")

      {:ok, _name, {:redirect, url}} ->
        redirect(conn, external: url)

      {:error, message} ->
        conn
        |> put_flash(:error, message)
        |> redirect(to: ~p"/staff/backups")
    end
  end
end
