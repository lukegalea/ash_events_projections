defmodule AshEvents.Projections.Events.Changes.ExtractMetadataFields do
  @moduledoc """
  Generic change that copies named fields from an event resource's `metadata`
  attribute onto top-level attributes of the same name.

  AshEvents passes through arbitrary host-application context as `metadata`
  (a JSON map). When the host wants to index or query certain fields directly
  (for instance, `practice_id` or `user_id`), the event resource declares
  matching attributes and this change moves the values into them on `:create`.

  Both string and atom keys are tolerated since `Ash.Changeset.set_context/2`
  may be called with either form.

  ## Options

    * `:fields` — list of either:
        - atoms (`:practice_id`) — extracted from metadata, always overwritten,
          and cast via `Ecto.UUID.cast/1` when the existing attribute type is
          `:uuid`. Use this for required fields the host always wants set from
          metadata.
        - `{name, opts}` tuples where `opts` is a keyword list:
            * `cast: :uuid` — pass the value through `Ecto.UUID.cast/1`.
            * `cast: :string` — `to_string/1`.
            * `cast: {mod, fun}` — call `mod.fun(value)`, expect `{:ok, val}` /
              `{:error, _}` / value-or-`nil`.
            * `overwrite?: false` — only set the attribute when it is currently
              `nil` (use for actor-derived fields that AshEvents may have set
              already).

  ## Example

      events do
        event_log MyApp.Events.Event
      end

      changes do
        change {AshEvents.Projections.Events.Changes.ExtractMetadataFields,
                fields: [
                  {:practice_id, cast: :uuid},
                  {:user_id, cast: :uuid, overwrite?: false}
                ]},
               on: [:create]
      end
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    fields = Keyword.get(opts, :fields, [])
    metadata = Ash.Changeset.get_attribute(changeset, :metadata) || %{}

    Enum.reduce(fields, changeset, fn field, cs ->
      {name, field_opts} = normalize(field)
      apply_field(cs, name, field_opts, metadata)
    end)
  end

  defp normalize(name) when is_atom(name), do: {name, []}
  defp normalize({name, opts}) when is_atom(name) and is_list(opts), do: {name, opts}

  defp apply_field(changeset, name, opts, metadata) do
    overwrite? = Keyword.get(opts, :overwrite?, true)

    if not overwrite? and Ash.Changeset.get_attribute(changeset, name) do
      changeset
    else
      raw = metadata[Atom.to_string(name)] || metadata[name]
      value = cast(raw, Keyword.get(opts, :cast))
      Ash.Changeset.force_change_attribute(changeset, name, value)
    end
  end

  defp cast(nil, _), do: nil

  defp cast(value, :uuid) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> uuid
      _ -> nil
    end
  end

  defp cast(_value, :uuid), do: nil
  defp cast(value, :string), do: to_string(value)

  defp cast(value, {mod, fun}) when is_atom(mod) and is_atom(fun) do
    case apply(mod, fun, [value]) do
      {:ok, casted} -> casted
      {:error, _} -> nil
      other -> other
    end
  end

  defp cast(value, nil), do: value
end
