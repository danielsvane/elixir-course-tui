defmodule Course.App do
  @moduledoc """
  The terminal UI for the course, built on The Elm Architecture (TermUI).

    * `init/1`         – set up state (lessons + per-lesson editor buffers)
    * `event_to_msg/2` – translate a key press into a message
    * `update/2`       – apply a message, returning new state (+ commands)
    * `view/1`         – render the current state to a screen tree

  State shape:

      %{
        lessons: [lesson],          # from Course.Lessons.all/0
        idx:     non_neg_integer,   # which lesson is active
        buffers: %{idx => editor},  # Course.Editor state, kept per lesson
        result:  nil | {:ok, [check_result]} | {:error, message},
        status:  nil | String.t()   # transient message line (e.g. unknown `:cmd`)
      }
  """
  use TermUI.Elm

  alias TermUI.Event
  alias TermUI.Renderer.Style
  alias Course.{Editor, Evaluator, Lessons}

  @width 74

  # ---- init ----

  def init(_opts) do
    %{lessons: Lessons.all(), idx: 0, buffers: %{}, result: nil, status: nil}
    |> ensure_buffer()
  end

  # ---- input -> messages ----

  # Course commands use Ctrl/Page keys (these work in any Vim mode); every
  # other key is forwarded to the Vim layer as `{:key, normalized}`.
  def event_to_msg(%Event.Key{key: key, modifiers: mods}, _state) when is_binary(key) do
    cond do
      :ctrl in mods ->
        case key do
          "r" -> {:msg, :run}
          "l" -> {:msg, :reset}
          # `:q` is the primary quit; Ctrl+C is a terminal-agnostic backup
          # (Ctrl+Q is unreliable — Kitty and others grab it).
          "c" -> {:msg, :quit}
          _ -> :ignore
        end

      mods == [] ->
        {:msg, {:key, key}}

      true ->
        :ignore
    end
  end

  def event_to_msg(%Event.Key{key: :page_down}, _state), do: {:msg, :next}
  def event_to_msg(%Event.Key{key: :page_up}, _state), do: {:msg, :prev}

  def event_to_msg(%Event.Key{key: key}, _state)
      when key in [:escape, :enter, :backspace, :tab, :left, :right, :up, :down],
      do: {:msg, {:key, key}}

  def event_to_msg(_event, _state), do: :ignore

  # ---- update ----

  def update(:quit, state), do: {state, [:quit]}

  def update(:run, state) do
    code = state |> current_editor() |> Editor.to_string()
    result = Evaluator.run(code, current_lesson(state).checks)
    {%{state | result: result}, []}
  end

  def update(:next, state), do: {move_lesson(state, 1), []}
  def update(:prev, state), do: {move_lesson(state, -1), []}

  def update(:reset, state) do
    fresh = Editor.from_string(current_lesson(state).starter)
    {put_editor(%{state | result: nil}, fresh), []}
  end

  # Submitting a command line (`:q⏎` etc.) is interpreted here, not in the Vim
  # layer, because commands can have app-level effects like quitting.
  def update({:key, :enter}, %{} = state) do
    ed = current_editor(state)

    if ed.mode == :command do
      run_ex_command(String.trim(ed.cmdline), state)
    else
      apply_key(:enter, state)
    end
  end

  def update({:key, key}, state), do: apply_key(key, state)

  def update(_msg, state), do: {state, []}

  defp apply_key(key, state) do
    ed = current_editor(state)
    ed2 = Course.Vim.handle(ed, key)
    state = put_editor(%{state | status: nil}, ed2)
    # Only clear the last result when the code actually changed (not on a mere
    # cursor move or mode switch).
    state =
      if Editor.to_string(ed2) != Editor.to_string(ed),
        do: %{state | result: nil},
        else: state

    {state, []}
  end

  # `:q` / `:quit` / `:wq` / `:x` (and `!` variants) all quit; an empty command
  # just closes the line; anything else flashes a message.
  defp run_ex_command("", state), do: {leave_command(state, nil), []}

  defp run_ex_command(cmd, state) when cmd in ~w(q q! qa qa! quit quit! wq x), do: {state, [:quit]}

  defp run_ex_command(cmd, state),
    do: {leave_command(state, "Not a course command: :#{cmd}"), []}

  defp leave_command(state, status) do
    ed = %{current_editor(state) | mode: :normal, cmdline: ""}
    put_editor(%{state | status: status}, ed)
  end

  # ---- view ----

  def view(state) do
    lesson = current_lesson(state)
    ed = current_editor(state)

    stack(:vertical, [
      text(
        "Elixir Course — Lesson #{state.idx + 1}/#{length(state.lessons)}: #{lesson.title}",
        Style.new(fg: :cyan, attrs: [:bold])
      ),
      rule(),
      stack(:vertical, text_lines(lesson.info)),
      label("CODE  —  #{mode_label(ed.mode)}"),
      stack(:vertical, render_editor(ed)),
      command_line(ed, state.status),
      label("RESULTS"),
      stack(:vertical, render_result(state.result)),
      rule(),
      text(
        "Ctrl+R run · PgDn/PgUp lesson · Ctrl+L reset · :q or Ctrl+C quit",
        dim()
      )
    ])
  end

  # ---- view helpers ----

  defp mode_label(:insert), do: "-- INSERT --  (Esc → normal)"
  defp mode_label(:visual), do: "-- VISUAL --  (motions select · d/c · Esc)"
  defp mode_label(:vline), do: "-- VISUAL LINE --  (j/k select · d/c · Esc)"
  defp mode_label(:command), do: "COMMAND  (type a command · Enter run · Esc cancel)"
  defp mode_label(:normal), do: "NORMAL  (i insert · v/V visual · :q quit · ciw · dd · u undo)"

  # The bottom line: the command being typed, a transient status, or nothing.
  defp command_line(%{mode: :command, cmdline: cmd}, _status) do
    stack(:horizontal, [
      text(":" <> cmd),
      styled(text(" "), Style.new(attrs: [:reverse]))
    ])
  end

  defp command_line(_ed, nil), do: text("")
  defp command_line(_ed, status), do: text(status, Style.new(fg: :yellow))

  defp render_editor(ed) do
    sel = Course.Vim.selection(ed)

    ed.lines
    |> Enum.with_index()
    |> Enum.map(fn {line, row} -> render_row(line, row, ed, sel) end)
  end

  # No selection: only the cursor row gets the block cursor.
  defp render_row(line, row, ed, nil) do
    if row == ed.row, do: cursor_line(line, ed.col), else: text("  " <> line)
  end

  # Linewise: every row in range is fully highlighted.
  defp render_row(line, row, _ed, {:lines, lo, hi}) when row >= lo and row <= hi do
    styled(text("  " <> blank_if_empty(line)), Style.new(attrs: [:reverse]))
  end

  # Charwise: highlight the selected column span on rows the selection touches.
  defp render_row(line, row, _ed, {:chars, {sr, sc}, {er, ec}}) when row >= sr and row <= er do
    last = max(String.length(line) - 1, 0)
    from = if row == sr, do: sc, else: 0
    to = if row == er, do: ec, else: last
    highlight_span(line, from, to)
  end

  defp render_row(line, _row, _ed, _sel), do: text("  " <> line)

  # Reverse-highlight columns `from..to` (inclusive) of a line.
  defp highlight_span(line, from, to) do
    before = String.slice(line, 0, from)
    mid = String.slice(line, from, to - from + 1)
    rest = String.slice(line, (to + 1)..-1//1) || ""

    stack(:horizontal, [
      text("  " <> before),
      styled(text(blank_if_empty(mid)), Style.new(attrs: [:reverse])),
      text(rest)
    ])
  end

  defp blank_if_empty(""), do: " "
  defp blank_if_empty(s), do: s

  defp cursor_line(line, col) do
    {before, rest} = String.split_at(line, col)

    {under, tail} =
      case String.split_at(rest, 1) do
        {"", _} -> {" ", ""}
        {ch, more} -> {ch, more}
      end

    stack(:horizontal, [
      text("  " <> before),
      styled(text(under), Style.new(attrs: [:reverse])),
      text(tail)
    ])
  end

  defp render_result(nil), do: [text("▶ Press Ctrl+R to run your code.", dim())]

  defp render_result({:error, message}) do
    [text("✗ Your code did not compile:", Style.new(fg: :red, attrs: [:bold]))] ++
      Enum.map(text_lines(message), &styled(&1, Style.new(fg: :red)))
  end

  defp render_result({:ok, results}) do
    passed = Enum.count(results, & &1.pass)
    total = length(results)

    summary =
      if passed == total do
        text("🎉 #{passed}/#{total} checks passed — solved!", Style.new(fg: :green, attrs: [:bold]))
      else
        text("#{passed}/#{total} checks passed — keep going.", Style.new(fg: :yellow))
      end

    Enum.map(results, &result_row/1) ++ [text(""), summary]
  end

  defp result_row(%{pass: true} = r),
    do: text("  ✓ #{format_call(r.call)} = #{inspect(r.got)}", Style.new(fg: :green))

  defp result_row(%{error: err} = r) when is_binary(err),
    do: text("  ✗ #{format_call(r.call)} raised: #{err}", Style.new(fg: :red))

  defp result_row(r) do
    text(
      "  ✗ #{format_call(r.call)} = #{inspect(r.got)}  (expected #{inspect(r.expect)})",
      Style.new(fg: :red)
    )
  end

  defp format_call({fun, args}),
    do: "#{fun}(" <> Enum.map_join(args, ", ", &inspect/1) <> ")"

  defp text_lines(string), do: string |> String.split("\n") |> Enum.map(&text/1)

  defp rule, do: text(String.duplicate("─", @width), dim())

  defp label(name) do
    dashes = String.duplicate("─", max(@width - String.length(name) - 4, 0))
    text("── #{name} #{dashes}", dim())
  end

  defp dim, do: Style.new(fg: :bright_black)

  # ---- state helpers ----

  defp current_lesson(state), do: Enum.at(state.lessons, state.idx)
  defp current_editor(state), do: Map.fetch!(state.buffers, state.idx)

  defp put_editor(state, editor),
    do: %{state | buffers: Map.put(state.buffers, state.idx, editor)}

  defp ensure_buffer(state) do
    if Map.has_key?(state.buffers, state.idx) do
      state
    else
      put_editor(state, Editor.from_string(current_lesson(state).starter))
    end
  end

  defp move_lesson(state, delta) do
    new_idx = clamp(state.idx + delta, 0, length(state.lessons) - 1)
    ensure_buffer(%{state | idx: new_idx, result: nil})
  end

  defp clamp(n, lo, hi), do: n |> max(lo) |> min(hi)
end
