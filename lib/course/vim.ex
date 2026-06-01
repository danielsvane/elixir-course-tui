defmodule Course.Vim do
  @moduledoc """
  A small but real Vim-style modal layer over `Course.Editor`.

  `handle(editor, key)` takes the current editor and a normalized key and
  returns a new editor. `key` is either a one-grapheme string (a printable
  character) or an atom for a special key (`:escape`, `:enter`, `:backspace`,
  `:tab`, `:left`, `:right`, `:up`, `:down`).

  ## Supported (Normal mode)

    * Motions:   `h j k l`, `w b e`, `0 $ ^`, `gg`, `G`, arrows
    * Enter insert: `i a A I o O`
    * Visual:    `v` (charwise), `V` (linewise)
    * Command:   `:` opens a command line (e.g. `:q` to quit)
    * Delete:    `x`, `D`, `dd`, `dw db de`, `d$ d0`, `diw daw`
    * Change:    `C`, `cc`, `cw cb ce`, `c$ c0`, `ciw caw`
    * `u` to undo

  ## Supported (Visual / Visual-line mode)

    * Extend the selection with any motion (`h j k l w b e 0 $ ^ gg G`).
    * `d`/`x` delete the selection, `c` changes it (delete + insert).
    * `v`/`V` toggle the selection kind; `Esc` leaves visual mode.

  Counts (`3w`), registers, yank/paste, and search are intentionally left
  out — they're a great thing to add yourself later.
  """

  alias Course.Editor

  @word_re ~r/[\p{L}\p{N}_]/u

  @doc "Apply a single key to the editor, respecting the current mode."
  @spec handle(Editor.t(), String.t() | atom()) :: Editor.t()
  def handle(%{mode: :insert} = ed, key), do: insert(ed, key)
  def handle(%{mode: :normal} = ed, key), do: normal(ed, key)
  def handle(%{mode: m} = ed, key) when m in [:visual, :vline], do: visual(ed, key)
  def handle(%{mode: :command} = ed, key), do: cmdline(ed, key)

  # ---- Insert mode ----

  defp insert(ed, :escape), do: %{ed | mode: :normal, pending: ""} |> clamp()
  defp insert(ed, :enter), do: Editor.newline(ed)
  defp insert(ed, :backspace), do: Editor.backspace(ed)
  defp insert(ed, :tab), do: ed |> Editor.insert(" ") |> Editor.insert(" ")
  defp insert(ed, dir) when dir in [:left, :right, :up, :down], do: Editor.move(ed, dir)
  defp insert(ed, key) when is_binary(key), do: Editor.insert(ed, key)
  defp insert(ed, _key), do: ed

  # ---- Normal mode ----

  defp normal(ed, :escape), do: %{ed | pending: ""}
  defp normal(ed, :left), do: ed |> Editor.move(:left) |> clamp() |> done()
  defp normal(ed, :right), do: ed |> move_right() |> done()
  defp normal(ed, :up), do: ed |> Editor.move(:up) |> clamp() |> done()
  defp normal(ed, :down), do: ed |> Editor.move(:down) |> clamp() |> done()
  defp normal(ed, :enter), do: ed |> Editor.move(:down) |> clamp() |> done()
  defp normal(ed, :backspace), do: ed |> Editor.move(:left) |> clamp() |> done()
  defp normal(ed, :tab), do: done(ed)
  defp normal(ed, key) when is_binary(key), do: command(ed, ed.pending <> key)
  defp normal(ed, _key), do: done(ed)

  # Dispatch a (possibly multi-key) Normal-mode command sequence. Motions are
  # shared with Visual mode via `motion/2`; everything else is Normal-only.
  defp command(ed, seq) do
    case motion(ed, seq) do
      {:ok, moved} -> done(moved)
      :nomotion -> command_other(ed, seq)
    end
  end

  defp command_other(ed, seq) do
    case seq do
      "u" -> ed |> Editor.undo() |> clamp() |> done()

      # enter visual
      "v" -> %{ed | mode: :visual, vstart: {ed.row, ed.col}} |> done()
      "V" -> %{ed | mode: :vline, vstart: {ed.row, ed.col}} |> done()

      # open the command line (`:q` etc.)
      ":" -> %{ed | mode: :command, cmdline: ""} |> done()

      # enter insert
      "i" -> start_insert(ed, ed.col) |> done()
      "a" -> start_insert(ed, min(ed.col + 1, llen(ed))) |> done()
      "A" -> start_insert(ed, llen(ed)) |> done()
      "I" -> start_insert(to_first_nonblank(ed), nil) |> done()
      "o" -> open_below(ed) |> done()
      "O" -> open_above(ed) |> done()

      # single-key edits
      "x" -> delete_char(ed) |> done()
      "D" -> op_del(ed, off(ed), line_end_off(ed)) |> clamp() |> done()
      "C" -> ed |> op_del(off(ed), line_end_off(ed)) |> insert_here() |> done()

      # operator prefixes (incomplete — wait for the next key)
      "g" -> pend(ed, "g")
      "d" -> pend(ed, "d")
      "c" -> pend(ed, "c")
      "di" -> pend(ed, "di")
      "ci" -> pend(ed, "ci")
      "da" -> pend(ed, "da")
      "ca" -> pend(ed, "ca")

      # two-key completions
      "dd" -> delete_line(ed) |> done()
      "cc" -> change_line(ed) |> done()
      "dw" -> op_del(ed, off(ed), w_target(ed)) |> clamp() |> done()
      "cw" -> ed |> op_chg(off(ed), min(e_target(ed) + 1, tlen(ed))) |> done()
      "db" -> op_del(ed, b_target(ed), off(ed)) |> clamp() |> done()
      "cb" -> op_chg(ed, b_target(ed), off(ed)) |> done()
      "de" -> op_del(ed, off(ed), min(e_target(ed) + 1, tlen(ed))) |> clamp() |> done()
      "ce" -> op_chg(ed, off(ed), min(e_target(ed) + 1, tlen(ed))) |> done()
      "d$" -> op_del(ed, off(ed), line_end_off(ed)) |> clamp() |> done()
      "c$" -> ed |> op_del(off(ed), line_end_off(ed)) |> insert_here() |> done()
      "d0" -> op_del(ed, line_start_off(ed), off(ed)) |> clamp() |> done()
      "c0" -> op_chg(ed, line_start_off(ed), off(ed)) |> done()

      # three-key text objects
      "diw" -> textobj(ed, &word_range/1, :delete) |> done()
      "ciw" -> textobj(ed, &word_range/1, :change) |> done()
      "daw" -> textobj(ed, &a_word_range/1, :delete) |> done()
      "caw" -> textobj(ed, &a_word_range/1, :change) |> done()

      # anything else: cancel any pending state
      _ -> done(ed)
    end
  end

  # ---- motions (shared by Normal and Visual) ----

  # Returns {:ok, moved_editor} for a recognized cursor motion, or :nomotion.
  # Motions only move the cursor; they never change mode or text, which is why
  # both Normal and Visual mode can reuse them.
  defp motion(ed, seq) do
    case seq do
      "h" -> {:ok, ed |> Editor.move(:left) |> clamp()}
      "l" -> {:ok, move_right(ed)}
      "j" -> {:ok, ed |> Editor.move(:down) |> clamp()}
      "k" -> {:ok, ed |> Editor.move(:up) |> clamp()}
      "0" -> {:ok, %{ed | col: 0}}
      "$" -> {:ok, to_line_end(ed)}
      "^" -> {:ok, to_first_nonblank(ed)}
      "w" -> {:ok, ed |> Editor.move_to_offset(w_target(ed)) |> clamp()}
      "b" -> {:ok, ed |> Editor.move_to_offset(b_target(ed)) |> clamp()}
      "e" -> {:ok, ed |> Editor.move_to_offset(e_target(ed)) |> clamp()}
      "G" -> {:ok, %{ed | row: length(ed.lines) - 1, col: 0} |> clamp()}
      "gg" -> {:ok, %{ed | row: 0, col: 0} |> clamp()}
      _ -> :nomotion
    end
  end

  # ---- Visual / Visual-line mode ----

  defp visual(ed, :escape), do: leave_visual(ed) |> done()
  defp visual(ed, :left), do: ed |> Editor.move(:left) |> clamp() |> done()
  defp visual(ed, :right), do: ed |> move_right() |> done()
  defp visual(ed, :up), do: ed |> Editor.move(:up) |> clamp() |> done()
  defp visual(ed, :down), do: ed |> Editor.move(:down) |> clamp() |> done()
  defp visual(ed, key) when is_binary(key), do: visual_cmd(ed, ed.pending <> key)
  defp visual(ed, _key), do: done(ed)

  defp visual_cmd(ed, seq) do
    case motion(ed, seq) do
      {:ok, moved} ->
        done(moved)

      :nomotion ->
        case seq do
          "g" -> pend(ed, "g")
          "d" -> delete_selection(ed) |> done()
          "x" -> delete_selection(ed) |> done()
          "c" -> change_selection(ed) |> done()
          # Toggle the selection kind; pressing the same one again exits.
          "v" -> toggle_visual(ed, :visual) |> done()
          "V" -> toggle_visual(ed, :vline) |> done()
          _ -> done(ed)
        end
    end
  end

  defp leave_visual(ed), do: %{ed | mode: :normal, vstart: nil} |> clamp()

  defp toggle_visual(ed, kind) do
    if ed.mode == kind, do: leave_visual(ed), else: %{ed | mode: kind}
  end

  @doc """
  The current visual selection, for rendering. Returns:

    * `nil` outside visual modes
    * `{:lines, lo_row, hi_row}` in linewise (`V`) mode
    * `{:chars, {sr, sc}, {er, ec}}` in charwise (`v`) mode, end-inclusive
  """
  @spec selection(Editor.t()) :: nil | tuple()
  def selection(%{mode: :vline, vstart: {ar, _}} = ed),
    do: {:lines, min(ar, ed.row), max(ar, ed.row)}

  def selection(%{mode: :visual, vstart: {ar, ac}} = ed) do
    {min_rc(ar, ac, ed.row, ed.col), max_rc(ar, ac, ed.row, ed.col)}
    |> then(fn {a, b} -> {:chars, a, b} end)
  end

  def selection(_ed), do: nil

  defp min_rc(ar, ac, br, bc), do: if({ar, ac} <= {br, bc}, do: {ar, ac}, else: {br, bc})
  defp max_rc(ar, ac, br, bc), do: if({ar, ac} >= {br, bc}, do: {ar, ac}, else: {br, bc})

  defp delete_selection(%{mode: :vline, vstart: {ar, _}} = ed) do
    lo = min(ar, ed.row)
    hi = max(ar, ed.row)
    ed = Editor.snapshot(ed)
    kept = Enum.take(ed.lines, lo) ++ Enum.drop(ed.lines, hi + 1)
    kept = if kept == [], do: [""], else: kept
    %{leave_visual(ed) | lines: kept, row: min(lo, length(kept) - 1), col: 0} |> clamp()
  end

  defp delete_selection(%{mode: :visual} = ed) do
    {a, b} = char_offsets(ed)
    ed |> op_del(a, b) |> leave_visual() |> clamp()
  end

  defp change_selection(%{mode: :vline, vstart: {ar, _}} = ed) do
    lo = min(ar, ed.row)
    hi = max(ar, ed.row)
    ed = Editor.snapshot(ed)
    kept = Enum.take(ed.lines, lo) ++ [""] ++ Enum.drop(ed.lines, hi + 1)
    %{ed | lines: kept, row: lo, col: 0, mode: :insert, vstart: nil}
  end

  defp change_selection(%{mode: :visual} = ed) do
    {a, b} = char_offsets(ed)
    %{op_del(ed, a, b) | mode: :insert, vstart: nil}
  end

  # Half-open offset range covering a charwise selection (end char included).
  defp char_offsets(%{vstart: {ar, ac}} = ed) do
    anchor = Editor.offset(%{ed | row: ar, col: ac})
    cur = off(ed)
    {min(anchor, cur), max(anchor, cur) + 1}
  end

  # ---- Command-line mode (`:…`) ----
  #
  # We only edit the command string here; the app interprets it on Enter
  # (so that effects like quitting live where commands can be issued).

  defp cmdline(ed, :escape), do: %{ed | mode: :normal, cmdline: ""}
  # Enter is handled by the app, which reads `cmdline` and acts on it.
  defp cmdline(ed, :enter), do: ed
  defp cmdline(%{cmdline: ""} = ed, :backspace), do: %{ed | mode: :normal}
  defp cmdline(ed, :backspace), do: %{ed | cmdline: String.slice(ed.cmdline, 0..-2//1)}
  defp cmdline(ed, key) when is_binary(key), do: %{ed | cmdline: ed.cmdline <> key}
  defp cmdline(ed, _key), do: ed

  # ---- pending-state helpers ----

  defp done(ed), do: %{ed | pending: ""}
  defp pend(ed, seq), do: %{ed | pending: seq}

  # ---- cursor / line helpers ----

  defp llen(ed), do: Editor.current_line_length(ed)
  defp off(ed), do: Editor.offset(ed)
  defp tlen(ed), do: ed |> Editor.to_string() |> String.length()
  defp line_start_off(ed), do: off(ed) - ed.col
  defp line_end_off(ed), do: line_start_off(ed) + llen(ed)

  defp clamp(ed) do
    row = ed.row |> max(0) |> min(length(ed.lines) - 1)
    max_col = ed.lines |> Enum.at(row, "") |> String.length() |> Kernel.-(1) |> max(0)
    %{ed | row: row, col: min(ed.col, max_col)}
  end

  defp move_right(ed) do
    if ed.col < max(llen(ed) - 1, 0), do: %{ed | col: ed.col + 1}, else: ed
  end

  defp to_line_end(ed), do: %{ed | col: max(llen(ed) - 1, 0)}

  defp to_first_nonblank(ed) do
    line = Enum.at(ed.lines, ed.row, "")
    col = line |> String.graphemes() |> Enum.find_index(&(klass(&1) != :space)) || 0
    %{ed | col: col}
  end

  # ---- entering insert ----

  defp start_insert(ed, nil), do: %{Editor.snapshot(ed) | mode: :insert}

  defp start_insert(ed, col) do
    %{Editor.snapshot(ed) | mode: :insert, col: col |> max(0) |> min(llen(ed))}
  end

  defp insert_here(ed), do: %{ed | mode: :insert}

  defp open_below(ed) do
    ed = Editor.snapshot(ed)
    %{ed | lines: List.insert_at(ed.lines, ed.row + 1, ""), row: ed.row + 1, col: 0, mode: :insert}
  end

  defp open_above(ed) do
    ed = Editor.snapshot(ed)
    %{ed | lines: List.insert_at(ed.lines, ed.row, ""), col: 0, mode: :insert}
  end

  # ---- edits ----

  defp delete_char(ed) do
    if llen(ed) == 0 or ed.col >= llen(ed) do
      ed
    else
      ed |> Editor.snapshot() |> Editor.delete_range(off(ed), off(ed) + 1) |> clamp()
    end
  end

  defp delete_line(ed) do
    ed = Editor.snapshot(ed)
    lines = List.delete_at(ed.lines, ed.row)
    lines = if lines == [], do: [""], else: lines
    %{ed | lines: lines, row: min(ed.row, length(lines) - 1), col: 0} |> clamp()
  end

  defp change_line(ed) do
    ed = Editor.snapshot(ed)
    %{ed | lines: List.replace_at(ed.lines, ed.row, ""), col: 0, mode: :insert}
  end

  defp op_del(ed, a, b), do: ed |> Editor.snapshot() |> Editor.delete_range(a, b)
  defp op_chg(ed, a, b), do: ed |> op_del(a, b) |> insert_here()

  defp textobj(ed, range_fun, action) do
    {a, b} = range_fun.(ed)

    case action do
      :delete -> op_del(ed, a, b) |> clamp()
      :change -> op_chg(ed, a, b)
    end
  end

  # ---- word motions (operate on the flattened buffer) ----

  defp w_target(ed), do: next_word_start(graphemes(ed), off(ed))
  defp b_target(ed), do: prev_word_start(graphemes(ed), off(ed))
  defp e_target(ed), do: next_word_end(graphemes(ed), off(ed))

  defp graphemes(ed), do: ed |> Editor.to_string() |> String.graphemes()

  defp next_word_start(gs, i) do
    n = length(gs)

    if i >= n do
      n
    else
      c = klass(at(gs, i))
      j = if c == :space, do: i, else: skip_class(gs, i, c)
      skip_class(gs, j, :space)
    end
  end

  defp prev_word_start(gs, i) do
    j = back_over(gs, i - 1, :space)

    if j < 0 do
      0
    else
      c = klass(at(gs, j))
      back_to_start(gs, j, c)
    end
  end

  defp next_word_end(gs, i) do
    n = length(gs)
    j = skip_class(gs, i + 1, :space)

    if j >= n do
      max(n - 1, 0)
    else
      c = klass(at(gs, j))
      forward_to_end(gs, j, c)
    end
  end

  defp word_range(ed) do
    gs = graphemes(ed)
    i = off(ed)
    n = length(gs)

    if i >= n do
      {i, i}
    else
      c = klass(at(gs, i))
      {back_to_start(gs, i, c), forward_to_end(gs, i, c) + 1}
    end
  end

  defp a_word_range(ed) do
    {s, e} = word_range(ed)
    gs = graphemes(ed)
    e2 = skip_class(gs, e, :space)

    if e2 > e do
      {s, e2}
    else
      {back_over(gs, s - 1, :space) + 1, e}
    end
  end

  # ---- low-level grapheme scanning ----

  defp at(gs, i), do: Enum.at(gs, i)

  defp skip_class(gs, i, class) do
    if i < length(gs) and klass(at(gs, i)) == class, do: skip_class(gs, i + 1, class), else: i
  end

  defp back_over(_gs, i, _class) when i < 0, do: -1

  defp back_over(gs, i, class) do
    if klass(at(gs, i)) == class, do: back_over(gs, i - 1, class), else: i
  end

  defp back_to_start(_gs, 0, _class), do: 0

  defp back_to_start(gs, i, class) do
    if klass(at(gs, i - 1)) == class, do: back_to_start(gs, i - 1, class), else: i
  end

  defp forward_to_end(gs, i, class) do
    if i + 1 < length(gs) and klass(at(gs, i + 1)) == class,
      do: forward_to_end(gs, i + 1, class),
      else: i
  end

  defp klass(c) when c in [" ", "\t", "\n"], do: :space
  defp klass(c), do: if(String.match?(c, @word_re), do: :word, else: :punct)
end
