defmodule Otturnaut.Command.PortWrapper do
  @moduledoc """
  Thin wrapper around Erlang Port operations.

  This module exists to make port operations mockable in tests.
  In production, it simply delegates to the built-in Port module.
  """

  @doc """
  Gets information about a port.
  """
  def info(port) do
    Port.info(port)
  end

  @doc """
  Gets specific information about a port.
  """
  def info(port, item) do
    Port.info(port, item)
  end

  @doc """
  Closes a port.
  """
  def close(port) do
    Port.close(port)
  end
end
