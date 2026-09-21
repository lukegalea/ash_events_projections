defmodule AshEvents.Projections.Events.RequireOptIn do
  @moduledoc """
  Spark extension that enforces explicit event opt-in for any resource that
  uses `AshEvents.Events`.

  Without this extension, a resource using `AshEvents.Events` defaults to
  logging *all* create/update/destroy actions — often unintentional. This
  extension ensures authors explicitly declare `only_actions` so that only the
  intended actions are logged.

  ## Usage

  Add to every resource that also uses `AshEvents.Events`:

      use Ash.Resource,
        extensions: [AshEvents.Events, AshEvents.Projections.Events.RequireOptIn, ...]

      events do
        event_log MyApp.Events.Event
        only_actions [:complete, :email_note]
      end

  Omitting `only_actions` (or leaving it empty) raises a compile-time error.
  """

  use Spark.Dsl.Extension, verifiers: [AshEvents.Projections.Events.RequireOptIn.Verifier]
end

defmodule AshEvents.Projections.Events.RequireOptIn.Verifier do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias AshEvents.Events.Info
  alias Spark.Dsl.Extension
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @impl true
  def verify(dsl_state) do
    extensions = Extension.get_persisted(dsl_state, :extensions, [])

    if AshEvents.Events in extensions do
      case Info.events_only_actions(dsl_state) do
        {:ok, nil} -> missing_opt_in_error(dsl_state)
        {:ok, []} -> missing_opt_in_error(dsl_state)
        {:ok, _actions} -> :ok
        :error -> missing_opt_in_error(dsl_state)
      end
    else
      :ok
    end
  end

  defp missing_opt_in_error(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    {:error,
     DslError.exception(
       message:
         "Resource #{inspect(resource)} uses AshEvents.Events but does not declare " <>
           "`only_actions`. Explicitly list the actions that should be logged:\n\n" <>
           "    events do\n" <>
           "      event_log MyApp.Events.Event\n" <>
           "      only_actions [:my_action]\n" <>
           "    end\n\n" <>
           "This prevents accidental logging of all actions. " <>
           "Add AshEvents.Projections.Events.RequireOptIn to extensions to enable this check.",
       path: [:events, :only_actions],
       module: resource
     )}
  end
end
