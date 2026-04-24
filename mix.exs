defmodule Loam.MixProject do
  use Mix.Project

  def project do
    [
      app: :loam,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Loam.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:zenohex, "~> 0.9.0"},
      {:stream_data, "~> 1.3", only: [:dev, :test]}
    ]
  end
end
