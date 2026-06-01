defmodule Course.Evaluator do
  @moduledoc """
  Compiles the learner's code and runs a lesson's checks against it.

  The learner writes function definitions (e.g. `def double(n), do: n * 2`).
  We wrap that in a uniquely-named throwaway module, compile it, then call
  each checked function and compare the result to the expected value.

  Compiler warnings/errors are captured via `Code.with_diagnostics/1` so they
  never print to the terminal and corrupt the TUI screen.
  """

  @type check :: %{:call => {atom(), [term()]}, :expect => term(), optional(:delta) => number()}
  @type result :: %{
          call: {atom(), [term()]},
          expect: term(),
          got: term(),
          pass: boolean(),
          error: String.t() | nil
        }

  @doc """
  Compile `code` and run `checks`.

  Returns `{:ok, [result]}` if the code compiled (individual checks may still
  fail), or `{:error, message}` if the code failed to compile.
  """
  @spec run(String.t(), [check()]) :: {:ok, [result()]} | {:error, String.t()}
  def run(code, checks) do
    mod_name = "CourseSolution#{System.unique_integer([:positive])}"
    mod = Module.concat([mod_name])
    source = "defmodule #{mod_name} do\n" <> code <> "\nend\n"

    {outcome, diagnostics} =
      Code.with_diagnostics(fn ->
        try do
          Code.compile_string(source)
          :ok
        rescue
          e -> {:error, Exception.message(e)}
        catch
          kind, reason -> {:error, Exception.format(kind, reason)}
        end
      end)

    case outcome do
      :ok ->
        try do
          {:ok, Enum.map(checks, &run_check(mod, &1))}
        after
          purge(mod)
        end

      {:error, message} ->
        {:error, with_diagnostics(message, diagnostics)}
    end
  end

  defp run_check(mod, check) do
    {fun, args} = check.call
    expect = check.expect
    delta = Map.get(check, :delta)

    try do
      got = apply(mod, fun, args)
      %{call: {fun, args}, expect: expect, got: got, pass: passed?(got, expect, delta), error: nil}
    rescue
      e -> %{call: {fun, args}, expect: expect, got: nil, pass: false, error: Exception.message(e)}
    end
  end

  defp passed?(got, expect, nil), do: got == expect
  defp passed?(got, expect, delta) when is_number(got), do: abs(got - expect) <= delta
  defp passed?(_got, _expect, _delta), do: false

  # If the compile error message is sparse, append captured diagnostics.
  defp with_diagnostics(message, []), do: message

  defp with_diagnostics(message, diagnostics) do
    extra =
      diagnostics
      |> Enum.map(& &1.message)
      |> Enum.reject(&(&1 == message))
      |> Enum.join("\n")

    if extra == "", do: message, else: message <> "\n" <> extra
  end

  defp purge(mod) do
    :code.purge(mod)
    :code.delete(mod)
  end
end
