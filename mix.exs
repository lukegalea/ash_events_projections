# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.MixProject do
  use Mix.Project

  @version "0.1.0"

  @source_url "https://github.com/lukegalea/ash_events_projections"

  @description """
  Event-driven projections for AshEvents. Define declarative projectors that
  asynchronously fold a centralized event log into pre-aggregated stats tables,
  with checkpointing, dead-letter handling, blue/green rebuilds, gap detection,
  and a full operations toolkit.
  """

  def project do
    [
      app: :ash_events_projections,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      package: package(),
      deps: deps(),
      aliases: aliases(),
      docs: &docs/0,
      description: @description,
      source_url: @source_url,
      homepage_url: "https://lukegalea.github.io/ash_events_projections",
      consolidate_protocols: Mix.env() != :test,
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def cli do
    [
      preferred_envs: [
        "test.create": :test,
        "test.migrate": :test,
        "test.rollback": :test,
        "test.drop": :test,
        "test.generate_migrations": :test,
        "test.reset": :test
      ]
    ]
  end

  defp ash_version(default_version) do
    case System.get_env("ASH_VERSION") do
      nil -> default_version
      "local" -> [path: "../ash", override: true]
      "main" -> [git: "https://github.com/ash-project/ash.git", override: true]
      version -> "~> #{version}"
    end
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    application(Mix.env())
  end

  defp application(:test) do
    [
      mod: {AshEvents.Projections.TestApp, []},
      extra_applications: [:logger]
    ]
  end

  defp application(_) do
    [extra_applications: [:logger]]
  end

  defp package do
    [
      maintainers: ["Luke Galea"],
      licenses: ["MIT"],
      files: ~w(lib .formatter.exs mix.exs README* CHANGELOG* LICENSE
        documentation usage-rules.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Docs" => "https://hexdocs.pm/ash_events_projections",
        "Website" => "https://lukegalea.github.io/ash_events_projections"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extra_section: "GUIDES",
      extras: extras(),
      groups_for_extras: [
        Tutorials: ~r'documentation/tutorials',
        "How-To": ~r'documentation/how-to',
        Topics: ~r'documentation/topics',
        DSLs: ~r'documentation/dsls',
        About: ["CHANGELOG.md"]
      ],
      groups_for_modules: [
        "Public DSL": [
          AshEvents.Projections.Projector,
          AshEvents.Projections.ProjectionResource,
          AshEvents.Projections.AttachProjection
        ],
        Runtime: [
          AshEvents.Projections.Supervisor,
          AshEvents.Projections.Server,
          AshEvents.Projections.LeaderMonitor,
          AshEvents.Projections.PubsubListener,
          AshEvents.Projections.Probe
        ],
        Resources: [
          AshEvents.Projections.Checkpoint,
          AshEvents.Projections.DeadLetter,
          AshEvents.Projections.Registry
        ],
        Operations: [
          AshEvents.Projections.Operations.Bootstrap,
          AshEvents.Projections.Operations.Dlq,
          AshEvents.Projections.Operations.EventGrowth,
          AshEvents.Projections.Operations.Gaps,
          AshEvents.Projections.Operations.Reset,
          AshEvents.Projections.Operations.Verify,
          AshEvents.Projections.Rebuilder,
          AshEvents.Projections.Lag,
          AshEvents.Projections.TimeTravel
        ],
        "AshEvents Integration": [
          AshEvents.Projections.NotifyProjectors,
          AshEvents.Projections.ExtractMetadataFields,
          AshEvents.Projections.RecordIdAdvisoryLockKeyGenerator,
          AshEvents.Projections.RequireOptIn
        ]
      ]
    ]
  end

  defp extras do
    [
      {"README.md", title: "Home"},
      "documentation/tutorials/01-getting-started.md",
      "documentation/tutorials/02-attaching-projections.md",
      "documentation/tutorials/03-blue-green-deploys.md",
      "documentation/how-to/rebuild-a-projection.md",
      "documentation/how-to/inspect-the-dlq.md",
      "documentation/how-to/detect-gaps.md",
      "documentation/how-to/verify-completeness.md",
      "documentation/how-to/handle-mid-batch-crashes.md",
      "documentation/how-to/temporal-queries.md",
      "documentation/how-to/observability-lag-and-health.md",
      "documentation/how-to/add-event-emitting-action.md",
      "documentation/topics/architecture.md",
      "documentation/topics/projection-types.md",
      "documentation/topics/checkpointing-and-replay.md",
      "documentation/topics/operations-glossary.md",
      "CHANGELOG.md"
    ]
  end

  defp deps do
    [
      {:ash, ash_version("~> 3.5")},
      {:ash_postgres, "~> 2.0"},
      {:ash_events, "~> 0.6"},
      {:phoenix_pubsub, "~> 2.1"},
      {:spark, "~> 2.0"},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"},

      # Dev / test
      {:ecto_sql, "~> 3.10"},
      {:postgrex, ">= 0.0.0"},
      {:ex_doc, "~> 0.37", only: [:dev], runtime: false},
      {:ex_check, "~> 0.16", only: [:dev, :test]},
      {:credo, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:dialyxir, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:sobelow, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false},
      {:git_ops, "~> 2.0", only: [:dev], runtime: false},
      {:igniter, "~> 0.6", optional: true}
    ]
  end

  defp aliases do
    [
      "test.generate_migrations": "ash_postgres.generate_migrations",
      "test.check_migrations": "ash_postgres.generate_migrations --check",
      "test.migrate": "ash_postgres.migrate",
      "test.rollback": "ash_postgres.rollback",
      "test.create": "ash_postgres.create",
      "test.reset": ["test.drop", "test.create", "test.migrate"],
      "test.drop": "ash_postgres.drop",
      sobelow: "sobelow --skip -i Config.HTTPS",
      docs: [
        "spark.cheat_sheets",
        "docs",
        "spark.replace_doc_links"
      ],
      credo: "credo --strict",
      "spark.formatter":
        "spark.formatter --extensions AshEvents.Projections.ProjectionResource,AshEvents.Projections.AttachProjection",
      "spark.cheat_sheets":
        "spark.cheat_sheets --extensions AshEvents.Projections.ProjectionResource,AshEvents.Projections.AttachProjection"
    ]
  end
end
