# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.AshEventsProjections.Install do
    @shortdoc "Installs ash_events_projections into a project. Run with `mix igniter.install ash_events_projections`."

    @moduledoc """
    #{@shortdoc}

    Adds the recommended configuration block, registers the supervisor in
    `application.ex`, and imports the formatter rules.

    ## Options

      * `--repo` — module name of your Ecto repo (defaults to `<App>.Repo`)
      * `--pubsub` — Phoenix.PubSub server name (defaults to `<App>.PubSub`)
      * `--event-log` — your AshEvents event log resource (no default; required
        when not already obvious from the project)

    ## What it does

      1. Adds `import_deps: [:ash_events_projections]` to `.formatter.exs`.
      2. Writes the runtime config block (under `config :ash_events_projections`)
         to `config/config.exs` if not already present.
      3. Inserts `AshEvents.Projections.Supervisor` into the application
         supervision tree (after the repo and PubSub).
    """

    use Igniter.Mix.Task

    alias Igniter.Project.Config
    alias Igniter.Project.Formatter

    @impl Igniter.Mix.Task
    def info(_argv, _source) do
      %Igniter.Mix.Task.Info{
        group: :ash,
        example:
          "mix igniter.install ash_events_projections --repo MyApp.Repo --event-log MyApp.Events.Event",
        schema: [repo: :string, pubsub: :string, event_log: :string]
      }
    end

    @impl Igniter.Mix.Task
    def igniter(igniter) do
      options = igniter.args.options

      app_name = Igniter.Project.Application.app_name(igniter)
      app_module = Igniter.Project.Module.module_name_prefix(igniter)

      repo =
        options[:repo]
        |> module_or_default(Module.concat([app_module, Repo]))

      pubsub =
        options[:pubsub]
        |> module_or_default(Module.concat([app_module, PubSub]))

      event_log =
        options[:event_log]
        |> module_or_default(Module.concat([app_module, Events, Event]))

      igniter
      |> Formatter.import_dep(:ash_events_projections)
      |> add_config(app_name, repo, pubsub, event_log)
      |> Igniter.Project.Application.add_new_child(
        AshEvents.Projections.Supervisor,
        after: [repo, {Phoenix.PubSub, [name: pubsub]}]
      )
    end

    defp module_or_default(nil, default), do: default
    defp module_or_default(str, _default) when is_binary(str), do: Module.concat([str])

    defp add_config(igniter, _app_name, repo, pubsub, event_log) do
      Config.configure_new(
        igniter,
        "config.exs",
        :ash_events_projections,
        [:repo],
        repo
      )
      |> Config.configure_new(
        "config.exs",
        :ash_events_projections,
        [:pubsub],
        pubsub
      )
      |> Config.configure_new(
        "config.exs",
        :ash_events_projections,
        [:event_log],
        event_log
      )
      |> Config.configure_new(
        "config.exs",
        :ash_events_projections,
        [:projectors],
        []
      )
      |> Config.configure_new(
        "config.exs",
        :ash_events_projections,
        [:start_projectors?],
        true
      )
      |> Config.configure_new(
        "config.exs",
        :ash_events_projections,
        [:start_probe?],
        true
      )
    end
  end
else
  defmodule Mix.Tasks.AshEventsProjections.Install do
    @moduledoc "Installs ash_events_projections into a project. Should be called with `mix igniter.install ash_events_projections`."

    @shortdoc @moduledoc

    use Mix.Task

    def run(_argv) do
      Mix.shell().error("""
      The task 'ash_events_projections.install' requires igniter to be run.

      Add `{:igniter, "~> 0.6", only: [:dev], runtime: false}` to your `mix.exs`,
      then `mix deps.get` and re-run with:

          mix igniter.install ash_events_projections

      For more information, see: https://hexdocs.pm/igniter
      """)

      exit({:shutdown, 1})
    end
  end
end
