# SPDX-FileCopyrightText: 2026 Luke Galea
#
# SPDX-License-Identifier: MIT

defmodule AshEvents.Projections.Projector do
  @moduledoc """
  DSL macro for defining event projectors.

  A projector module declares:
  - `grain/1`   — which field or function identifies the stats row to update
  - `project/2` — matches on action name only (any resource)
  - `project/3` — matches on resource + action (resource-specific handlers)

  ## Handler arity

  Handlers can be arity 1 (event only) or arity 2 (event + current projection row).

  **Arity 1** — stateless handlers (most common). The Server calls the handler
  *before* loading the grain row, so if the handler returns `:skip` no DB read
  happens at all. Use for atomic operations like counters and max values.

      project MyApp.Article, :create, fn event ->
        [{:increment, :note_count, 1}]
      end

  **Arity 2** — stateful handlers. The Server loads (or creates) the grain row
  *before* calling the handler, passing it as `current`. Use when you need the
  existing state to derive the new value — e.g. running averages, ratios.

      project MyApp.Order, :complete, fn event, current ->
        dur = event.data["fulfillment_minutes"]
        n = current.orders_count + 1
        new_avg = (current.avg_fulfillment * current.orders_count + dur) / n
        [
          {:increment, :orders_count, 1},
          {:set, :avg_fulfillment, new_avg}
        ]
      end

  Because the projection Server processes events serially there is no
  read-modify-write race: each event's handler sees the row as left by the
  previous event.

  Both handler arities return ops in the same format, so `ApplyOpsChange` and
  the upsert/update machinery remain identical.

  ## Generated API

      MyProjector.__projector_name__()          # "my_projector_v1"
      MyProjector.__grain__()                   # fn event -> grain_key end
      MyProjector.__handlers__()                # raw handler descriptors (introspection)
      MyProjector.handle_event(event)           # :skip | {:ok, ops}     (arity-1 handlers)
      MyProjector.handle_event(event, row)      # :skip | {:ok, ops}     (arity-2 handlers)
      MyProjector.needs_current_state?(event)   # true | false

  The Server checks `needs_current_state?` to decide whether to pre-load the row.
  """

  defmacro __using__(opts) do
    quote do
      @projector_opts unquote(opts)
      @projection_handlers []
      @grain_fn nil
      import AshEvents.Projections.Projector, only: [project: 2, project: 3, grain: 1]
      @before_compile AshEvents.Projections.Projector

      def __projector_name__, do: Keyword.fetch!(@projector_opts, :name)
      def __event_log__, do: Keyword.fetch!(@projector_opts, :event_log)
      def __projection_resource__, do: Keyword.fetch!(@projector_opts, :projection_resource)
    end
  end

  @doc """
  Declares the grain field (atom) or grain function.

  When given an atom, the grain is resolved from the top-level event field of
  that name, falling back to `event.data[atom_string]`.  When given a function,
  it is called with the event and must return the grain key (or `nil` to skip).
  """
  defmacro grain(field) when is_atom(field) do
    grain_ast =
      quote do
        fn event ->
          Map.get(event, unquote(field)) ||
            get_in(event.data || %{}, [Atom.to_string(unquote(field))])
        end
      end

    quote do
      @grain_fn unquote(Macro.escape(grain_ast))
    end
  end

  defmacro grain(fun) do
    quote do
      @grain_fn unquote(Macro.escape(fun))
    end
  end

  @doc """
  Registers a handler for events matching `action_name` (any resource).

  The handler may be arity 1 (`fn event -> ops end`) or arity 2
  (`fn event, current_row -> ops end`).  Arity is detected at compile time.
  """
  defmacro project(action_name, handler_fn) do
    action_atom = to_action_atom(action_name)
    arity = fn_arity(handler_fn)

    quote do
      @projection_handlers [
        {nil, unquote(action_atom), unquote(Macro.escape(handler_fn)), unquote(arity)}
        | @projection_handlers
      ]
    end
  end

  @doc """
  Registers a handler for events matching `resource` AND `action_name`.

  Resource accepts a module reference (resolved at compile time), an atom, or a
  string.  AshEvents stores both resource and action as atoms, so strings are
  converted at compile time via `String.to_atom/1`.

  Handler arity is detected at compile time (see `project/2`).
  """
  defmacro project(resource, action_name, handler_fn) do
    resource_atom =
      case resource do
        {:__aliases__, _, _} ->
          Macro.expand(resource, __CALLER__)

        atom when is_atom(atom) ->
          atom

        str when is_binary(str) ->
          String.to_atom(str)

        other ->
          raise ArgumentError,
                "project/3 resource must be a module reference, atom, or string; got: #{inspect(other)}"
      end

    action_atom = to_action_atom(action_name)
    arity = fn_arity(handler_fn)

    quote do
      @projection_handlers [
        {unquote(resource_atom), unquote(action_atom), unquote(Macro.escape(handler_fn)),
         unquote(arity)}
        | @projection_handlers
      ]
    end
  end

  defmacro __before_compile__(env) do
    grain_fn_ast = Module.get_attribute(env.module, :grain_fn)
    handlers = Module.get_attribute(env.module, :projection_handlers)

    {stateless, stateful} = Enum.split_with(handlers, fn {_, _, _, arity} -> arity == 1 end)

    quote do
      @doc "Returns the grain function (event → grain key, or nil to skip)."
      def __grain__, do: unquote(grain_fn_ast)

      @doc "Returns the raw handler descriptors {resource, action, fn_ast, arity}."
      def __handlers__, do: unquote(Macro.escape(handlers))

      unquote_splicing(Enum.map(stateless, &build_stateless_clause/1))
      unquote_splicing(Enum.map(stateful, &build_stateful_clause/1))

      @doc "Fallback: returns :skip for events with no matching stateless handler."
      def handle_event(_event), do: :skip

      @doc "Fallback: returns :skip for events with no matching stateful handler."
      def handle_event(_event, _current_row), do: :skip

      unquote_splicing(Enum.map(stateful, &build_needs_state_clause/1))

      @doc "Returns false unless this event is handled by an arity-2 (stateful) handler."
      def needs_current_state?(_event), do: false
    end
  end

  defp build_stateless_clause({nil, action, fn_ast, _}) do
    quote do
      def handle_event(%{action: unquote(action)} = event) do
        case unquote(fn_ast).(event) do
          ops when is_list(ops) and ops != [] -> {:ok, ops}
          _ -> :skip
        end
      end
    end
  end

  defp build_stateless_clause({resource, action, fn_ast, _}) do
    quote do
      def handle_event(%{resource: unquote(resource), action: unquote(action)} = event) do
        case unquote(fn_ast).(event) do
          ops when is_list(ops) and ops != [] -> {:ok, ops}
          _ -> :skip
        end
      end
    end
  end

  defp build_stateful_clause({nil, action, fn_ast, _}) do
    quote do
      def handle_event(%{action: unquote(action)} = event, current_row) do
        case unquote(fn_ast).(event, current_row) do
          ops when is_list(ops) and ops != [] -> {:ok, ops}
          _ -> :skip
        end
      end
    end
  end

  defp build_stateful_clause({resource, action, fn_ast, _}) do
    quote do
      def handle_event(
            %{resource: unquote(resource), action: unquote(action)} = event,
            current_row
          ) do
        case unquote(fn_ast).(event, current_row) do
          ops when is_list(ops) and ops != [] -> {:ok, ops}
          _ -> :skip
        end
      end
    end
  end

  defp build_needs_state_clause({nil, action, _, _}) do
    quote do
      def needs_current_state?(%{action: unquote(action)}), do: true
    end
  end

  defp build_needs_state_clause({resource, action, _, _}) do
    quote do
      def needs_current_state?(%{resource: unquote(resource), action: unquote(action)}),
        do: true
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp to_action_atom(name) when is_atom(name), do: name
  defp to_action_atom(name) when is_binary(name), do: String.to_atom(name)

  # Extracts arity from a fn AST at compile time.
  # fn x -> ... end    → 1
  # fn x, y -> ... end → 2
  defp fn_arity({:fn, _, [{:->, _, [args, _]}]}) when is_list(args), do: length(args)
  defp fn_arity(_), do: 1
end
