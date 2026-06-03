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
        status:  nil | String.t(),  # transient message line (e.g. unknown `:cmd`)
        completed: MapSet.t()       # titles of lessons whose checks all pass
      }

  Code and completion are persisted via `Course.Progress`, so a restart resumes
  exactly where you left off.
  """
  use TermUI.Elm

  alias TermUI.Event
  alias TermUI.Renderer.Style
  alias Course.{Editor, Evaluator, Lessons, Progress}

  @width 74

  # ---- init ----

  def init(_opts) do
    saved = Progress.load()

    %{
      lessons: Lessons.all(),
      idx: 0,
      buffers: %{},
      result: nil,
      status: nil,
      completed: MapSet.new(saved.completed)
    }
    |> restore_buffers(saved)
    |> ensure_buffer()
  end

  # Rebuild a buffer for every lesson that has previously-saved code.
  defp restore_buffers(state, saved) do
    buffers =
      state.lessons
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {lesson, idx}, acc ->
        case Map.fetch(saved.code, lesson.title) do
          {:ok, code} -> Map.put(acc, idx, Editor.from_string(code))
          :error -> acc
        end
      end)

    %{state | buffers: buffers}
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
    state = %{state | result: result}
    state = if solved?(result), do: mark_completed(state), else: state
    {persist(state), []}
  end

  def update(:next, state), do: {move_lesson(state, 1), []}
  def update(:prev, state), do: {move_lesson(state, -1), []}

  def update(:reset, state) do
    fresh = Editor.from_string(current_lesson(state).starter)
    {persist(put_editor(%{state | result: nil}, fresh)), []}
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
        do: persist(%{state | result: nil}),
        else: state

    {state, []}
  end

  # ---- completion + persistence ----

  defp solved?({:ok, results}), do: results != [] and Enum.all?(results, & &1.pass)
  defp solved?(_), do: false

  defp mark_completed(state),
    do: %{state | completed: MapSet.put(state.completed, current_lesson(state).title)}

  defp completed?(state, lesson), do: MapSet.member?(state.completed, lesson.title)
  defp solved_count(state), do: Enum.count(state.lessons, &completed?(state, &1))

  # Snapshot the current code (keyed by lesson title) plus the solved set to disk.
  defp persist(state) do
    code =
      Enum.reduce(state.buffers, %{}, fn {idx, ed}, acc ->
        title = Enum.at(state.lessons, idx).title
        Map.put(acc, title, Editor.to_string(ed))
      end)

    Progress.save(%{code: code, completed: MapSet.to_list(state.completed)})
    state
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
      stack(:horizontal, [
        text(
          "Elixir Course — Lesson #{state.idx + 1}/#{length(state.lessons)}: #{lesson.title}",
          Style.new(fg: :cyan, attrs: [:bold])
        ),
        solved_badge(state, lesson)
      ]),
      text(
        "#{solved_count(state)}/#{length(state.lessons)} lessons solved",
        dim()
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

  defp solved_badge(state, lesson) do
    if completed?(state, lesson),
      do: text("  ✓ solved", Style.new(fg: :green, attrs: [:bold])),
      else: text("")
  end

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

  # Each row is rendered as a list of "cells" — one per character — carrying a
  # syntax colour and whether it's reverse-highlighted (the cursor or a
  # selection). Building rows this way lets syntax highlighting and the
  # cursor/selection overlay compose, instead of fighting over the characters.

  # No selection: only the cursor row gets the block cursor.
  defp render_row(line, row, ed, nil) do
    cells = base_cells(line)
    cells = if row == ed.row, do: put_cursor(cells, ed.col), else: cells
    row_node(cells)
  end

  # Linewise: every character on rows within the range is reverse-highlighted.
  defp render_row(line, row, _ed, {:lines, lo, hi}) when row >= lo and row <= hi do
    line |> base_cells() |> Enum.map(&reverse_cell/1) |> row_node()
  end

  # Charwise: reverse-highlight the selected column span on the touched rows.
  defp render_row(line, row, _ed, {:chars, {sr, sc}, {er, ec}}) when row >= sr and row <= er do
    last = max(String.length(line) - 1, 0)
    from = if row == sr, do: sc, else: 0
    to = if row == er, do: ec, else: last

    line
    |> base_cells()
    |> Enum.with_index()
    |> Enum.map(fn {cell, i} -> if i >= from and i <= to, do: reverse_cell(cell), else: cell end)
    |> row_node()
  end

  defp render_row(line, _row, _ed, _sel), do: line |> base_cells() |> row_node()

  # Turn a source line into syntax-coloured cells. An empty line yields a single
  # blank cell so the cursor/selection still has a character to land on.
  defp base_cells(line) do
    cells =
      line
      |> Course.Highlight.segments()
      |> Enum.flat_map(fn {seg, color} ->
        seg |> String.graphemes() |> Enum.map(&{&1, color, false})
      end)

    if cells == [], do: [{" ", nil, false}], else: cells
  end

  defp reverse_cell({g, color, _rev}), do: {g, color, true}

  # Place the block cursor at `col`; past the end of the line it's a trailing space.
  defp put_cursor(cells, col) do
    if col < length(cells) do
      List.update_at(cells, col, &reverse_cell/1)
    else
      cells ++ [{" ", nil, true}]
    end
  end

  # Render cells to a horizontal stack, merging neighbours that share a style.
  # The two-space gutter keeps the code indented from the screen edge.
  defp row_node(cells) do
    segments =
      cells
      |> Enum.chunk_by(fn {_g, color, rev} -> {color, rev} end)
      |> Enum.map(fn group ->
        {_g, color, rev} = hd(group)
        str = Enum.map_join(group, "", fn {g, _, _} -> g end)
        seg_node(str, color, rev)
      end)

    stack(:horizontal, [text("  ") | segments])
  end

  defp seg_node(str, nil, false), do: text(str)

  defp seg_node(str, color, rev) do
    opts = []
    opts = if color, do: [{:fg, color} | opts], else: opts
    opts = if rev, do: [{:attrs, [:reverse]} | opts], else: opts
    styled(text(str), Style.new(opts))
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
