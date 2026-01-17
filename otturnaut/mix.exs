defmodule Otturnaut.MixProject do
  use Mix.Project

  def project do
    [
      app: :otturnaut,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_coverage: test_coverage(),
      releases: releases()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Otturnaut.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:reactor, "~> 0.17"},
      {:req, "~> 0.5"},
      {:mimic, "~> 2.0", only: :test},
      {:plug, "~> 1.19", only: :test},
      {:bandit, "~> 1.0", only: :test}
    ]
  end

  defp test_coverage do
    [
      summary: [threshold: 100]
    ]
  end

  defp releases do
    [
      otturnaut: [
        include_executables_for: [:unix],
        strip_beams: true
      ]
    ]
  end
end
