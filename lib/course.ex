defmodule Course do
  @moduledoc """
  An interactive, terminal-based Elixir course.

  Start it with:

      mix run -e "Course.start()"

  or from an IEx session with `iex -S mix` then `Course.start()`.
  """

  @tty "/dev/tty"

  # Turn off every mouse-reporting mode (normal, button, all-motion, SGR, X10).
  @mouse_off "\e[?1000l\e[?1002l\e[?1003l\e[?1006l\e[?9l"
  # Show the cursor, leave the alternate screen, reset text attributes.
  @screen_restore "\e[?25h\e[?1049l\e[0m"

  @doc """
  Launch the course TUI. Blocks until you quit with `:q` or `Ctrl+C`.

  TermUI leaves a few terminal features in a state that bites us, and it tries
  to fix them through channels that don't survive every exit path. So we deal
  with them ourselves, talking straight to `#{@tty}`:

    * **Mouse tracking.** TermUI turns on full motion reporting at startup. We
      never use the mouse, so we turn it right back off — and crucially we do
      it by writing to the terminal device directly. That sticks for the whole
      session (the renderer never re-enables it), so even a hard kill can't
      leave your terminal spewing `\\e[<…M` mouse sequences.

    * **Flow control / signals (`stty`).** `-ixon` stops the terminal from
      eating `Ctrl+Q`/`Ctrl+S` as XON/XOFF before they reach us. `-isig` stops
      `Ctrl+C` from raising SIGINT and hard-killing the VM (which skips all
      cleanup); instead it arrives as an ordinary key we turn into a clean
      quit. TermUI sets these via `System.cmd("stty", …)`, but that runs with a
      pipe on stdin, so it no-ops — targeting `#{@tty}` with `stty -F` works.
  """
  def start do
    saved = capture_tty()

    try do
      {:ok, runtime} = TermUI.Runtime.start_link(root: Course.App)

      # TermUI enabled mouse tracking during init; kill it for the session.
      tty_write(@mouse_off)
      harden_tty()

      ref = Process.monitor(runtime)

      receive do
        {:DOWN, ^ref, :process, ^runtime, _reason} -> :ok
      end
    after
      tty_write(@mouse_off <> @screen_restore)
      restore_tty(saved)
    end
  end

  # ---- talking to the terminal device directly ----

  # Write bytes straight to the controlling terminal, bypassing Erlang's
  # console IO (which can be dropped or truncated under `{:noshell, :raw}`).
  defp tty_write(seq) do
    case File.open(@tty, [:append]) do
      {:ok, io} ->
        IO.binwrite(io, seq)
        File.close(io)

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  # ---- stty (signals + flow control) ----

  defp capture_tty do
    case System.cmd("stty", ["-F", @tty, "-g"], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp harden_tty do
    System.cmd("stty", ["-F", @tty, "-isig", "-ixon"], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end

  defp restore_tty(nil), do: :ok

  defp restore_tty(saved) do
    System.cmd("stty", ["-F", @tty, saved], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end
end
