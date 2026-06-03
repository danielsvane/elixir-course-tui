defmodule Course.Progress do
  @moduledoc """
  Persists the learner's progress between runs: the code typed for each lesson
  and which lessons have been solved. Everything is keyed by lesson **title**
  (stable even if lessons are reordered) and stored in a single project-local
  file as an Erlang term — no JSON dependency needed.

  The file location comes from the `:course, :progress_file` application
  setting, defaulting to `.course_progress` in the current directory. Tests set
  it to `nil` to disable disk access entirely (load is empty, save is a no-op).

      %{code: %{title => source}, completed: [title]}
  """

  @default_file ".course_progress"

  @doc "An empty progress structure (no code, nothing solved)."
  @spec empty() :: %{code: map(), completed: [String.t()]}
  def empty, do: %{code: %{}, completed: []}

  @doc "Where the progress file lives, or `nil` when persistence is disabled."
  @spec path() :: String.t() | nil
  def path do
    case Application.get_env(:course, :progress_file, :default) do
      :default -> Path.join(File.cwd!(), @default_file)
      other -> other
    end
  end

  @doc "Load saved progress, returning `empty/0` if there's nothing (or it's unreadable)."
  @spec load() :: %{code: map(), completed: [String.t()]}
  def load do
    with p when is_binary(p) <- path(),
         {:ok, bin} <- File.read(p),
         {:ok, data} <- decode(bin) do
      data
    else
      _ -> empty()
    end
  end

  @doc "Write progress to disk (a no-op when persistence is disabled). Returns the data."
  @spec save(%{code: map(), completed: [String.t()]}) :: %{code: map(), completed: [String.t()]}
  def save(data) do
    case path() do
      nil -> data
      p -> File.write(p, :erlang.term_to_binary(data)) && data
    end
  end

  # `:safe` refuses to invent unknown atoms; a corrupt file just resets progress.
  defp decode(bin) do
    case :erlang.binary_to_term(bin, [:safe]) do
      %{code: code, completed: completed} when is_map(code) and is_list(completed) ->
        {:ok, %{code: code, completed: completed}}

      _ ->
        :error
    end
  rescue
    _ -> :error
  end
end
