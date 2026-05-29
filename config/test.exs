import Config

config :ash_events_projections,
  ecto_repos: [AshEvents.Projections.TestRepo],
  repo: AshEvents.Projections.TestRepo,
  pubsub: AshEvents.Projections.TestPubSub,
  pubsub_topic: "ash_events_projections_test:new_event",
  event_log: AshEvents.Projections.TestApp.Events.Event,
  event_table: "ash_events",
  table_prefix: "ash_projection_",
  projectors: [],
  start_projectors?: false,
  start_probe?: false,
  telemetry_prefix: [:ash_events_projections_test]

config :ash_events_projections, AshEvents.Projections.TestRepo,
  database: "ash_events_projections_test#{System.get_env("MIX_TEST_PARTITION")}",
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :ash, :validate_domain_resource_inclusion?, false
config :ash, :validate_domain_config_inclusion?, false
config :ash, :disable_async?, true

config :logger, level: :warning
