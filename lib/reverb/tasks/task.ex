defmodule Reverb.Tasks.Task do
  @moduledoc """
  Ecto schema for Reverb tasks — the unit of work for the agent loop.

  Generalized from app-specific feedback: no foreign keys, uses `source_id`
  (free-form string) instead of a user reference. Includes `fingerprint` for
  error deduplication and `severity` for triage prioritization.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @status_values [:new, :todo, :worked_on, :done]
  @severity_values [:critical, :high, :medium, :low]
  @state_values [
    :pending,
    :claimed,
    :running,
    :validating,
    :awaiting_approval,
    :stable,
    :failed,
    :shelved,
    :cancelled
  ]
  @validation_status_values [:pending, :running, :passed, :failed]
  @remote_status_values [:local_only, :push_pending, :pushed, :pr_opened, :merged, :deployed]

  schema "reverb_tasks" do
    field(:body, :string)
    field(:category, :string)
    field(:source_id, :string)
    field(:source_kind, :string, default: "signal")
    field(:subject, :string)
    field(:fingerprint, :string)
    field(:error_count, :integer, default: 1)
    field(:attempt_count, :integer, default: 0)
    field(:priority, :integer, default: 100)
    field(:severity, Ecto.Enum, values: @severity_values, default: :medium)
    field(:status, Ecto.Enum, values: @status_values, default: :new)
    field(:state, Ecto.Enum, values: @state_values, default: :pending)
    field(:validation_status, Ecto.Enum, values: @validation_status_values, default: :pending)
    field(:remote_status, Ecto.Enum, values: @remote_status_values, default: :local_only)
    field(:assigned_agent, :string)
    field(:lease_expires_at, :utc_datetime)
    field(:branch_name, :string)
    field(:workspace_path, :string)
    field(:current_run_id, :binary_id)
    field(:steering_notes, :string)
    field(:last_error, :string)
    field(:done_note, :string)
    field(:metadata, :map, default: %{})

    timestamps(type: :utc_datetime)
  end

  def status_values, do: @status_values
  def severity_values, do: @severity_values
  def state_values, do: @state_values
  def validation_status_values, do: @validation_status_values
  def remote_status_values, do: @remote_status_values

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :body,
      :category,
      :source_id,
      :source_kind,
      :subject,
      :fingerprint,
      :error_count,
      :attempt_count,
      :priority,
      :severity,
      :status,
      :state,
      :validation_status,
      :remote_status,
      :assigned_agent,
      :lease_expires_at,
      :branch_name,
      :workspace_path,
      :current_run_id,
      :steering_notes,
      :last_error,
      :done_note,
      :metadata
    ])
    |> validate_required([:body])
    |> validate_length(:body, min: 1, max: 16_000)
    |> validate_length(:category, max: 255)
    |> validate_length(:source_id, max: 255)
    |> validate_length(:source_kind, max: 255)
    |> validate_length(:subject, max: 255)
    |> validate_length(:assigned_agent, max: 255)
    |> validate_length(:branch_name, max: 255)
    |> validate_length(:workspace_path, max: 4096)
    |> validate_length(:steering_notes, max: 8_000)
    |> validate_length(:last_error, max: 8_000)
    |> validate_length(:done_note, max: 2_000)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:attempt_count, greater_than_or_equal_to: 0)
  end
end
