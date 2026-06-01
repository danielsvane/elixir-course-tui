defmodule Course.Editor do
  @moduledoc """
  A tiny, pure multi-line text editor model.

  The state is just a map of `lines` (a list of strings, one per visual line)
  and a `cursor` at `{row, col}` (both 0-indexed). Every operation takes an
  editor and returns a NEW editor — nothing is mutated. This is deliberately
  written in plain, beginner-readable Elixir so it doubles as example code.
  """

  @type mode :: :normal | :insert | :visual | :vline | :command

  @type t :: %{
          lines: [String.t()],
          row: non_neg_integer(),
          col: non_neg_integer(),
          mode: mode(),
          pending: String.t(),
          undo: [map()],
          vstart: nil | {non_neg_integer(), non_neg_integer()},
          cmdline: String.t()
        }

  @doc "Build an editor from a multi-line string. Starts in Normal mode (Vim-style)."
  @spec from_string(String.t()) :: t()
  def from_string(text) do
    lines =
      case String.split(text, "\n") do
        [] -> [""]
        ls -> ls
      end

    %{lines: lines, row: 0, col: 0, mode: :normal, pending: "", undo: [], vstart: nil, cmdline: ""}
  end

  @doc "Render the editor back to a single string (lines joined by newlines)."
  @spec to_string(t()) :: String.t()
  def to_string(%{lines: lines}), do: Enum.join(lines, "\n")

  @doc "Insert a single character (a 1-grapheme string) at the cursor."
  @spec insert(t(), String.t()) :: t()
  def insert(ed, char) do
    line = current_line(ed)
    {before, rest} = String.split_at(line, ed.col)
    new_line = before <> char <> rest

    ed
    |> put_line(new_line)
    |> Map.put(:col, ed.col + String.length(char))
  end

  @doc "Split the current line at the cursor, creating a new line (Enter)."
  @spec newline(t()) :: t()
  def newline(ed) do
    line = current_line(ed)
    {before, rest} = String.split_at(line, ed.col)

    new_lines =
      ed.lines
      |> List.replace_at(ed.row, before)
      |> List.insert_at(ed.row + 1, rest)

    %{ed | lines: new_lines, row: ed.row + 1, col: 0}
  end

  @doc "Delete the character before the cursor (Backspace), joining lines if needed."
  @spec backspace(t()) :: t()
  def backspace(%{row: 0, col: 0} = ed), do: ed

  def backspace(%{col: 0} = ed) do
    # At the start of a line: merge this line onto the end of the previous one.
    prev = Enum.at(ed.lines, ed.row - 1)
    line = current_line(ed)
    merged = prev <> line

    new_lines =
      ed.lines
      |> List.delete_at(ed.row)
      |> List.replace_at(ed.row - 1, merged)

    %{ed | lines: new_lines, row: ed.row - 1, col: String.length(prev)}
  end

  def backspace(ed) do
    line = current_line(ed)
    {before, rest} = String.split_at(line, ed.col)
    new_line = String.slice(before, 0..-2//1) <> rest

    ed
    |> put_line(new_line)
    |> Map.put(:col, ed.col - 1)
  end

  @doc "Move the cursor one step in a direction, clamping at the edges."
  @spec move(t(), :left | :right | :up | :down) :: t()
  def move(ed, :left) do
    cond do
      ed.col > 0 -> %{ed | col: ed.col - 1}
      ed.row > 0 -> %{ed | row: ed.row - 1, col: line_length(ed, ed.row - 1)}
      true -> ed
    end
  end

  def move(ed, :right) do
    cond do
      ed.col < line_length(ed, ed.row) -> %{ed | col: ed.col + 1}
      ed.row < length(ed.lines) - 1 -> %{ed | row: ed.row + 1, col: 0}
      true -> ed
    end
  end

  def move(%{row: 0} = ed, :up), do: %{ed | col: 0}

  def move(ed, :up) do
    row = ed.row - 1
    %{ed | row: row, col: min(ed.col, line_length(ed, row))}
  end

  def move(ed, :down) do
    if ed.row < length(ed.lines) - 1 do
      row = ed.row + 1
      %{ed | row: row, col: min(ed.col, line_length(ed, row))}
    else
      %{ed | col: line_length(ed, ed.row)}
    end
  end

  @doc "Length (in graphemes) of the current line."
  @spec current_line_length(t()) :: non_neg_integer()
  def current_line_length(ed), do: line_length(ed, ed.row)

  @doc "The absolute character offset of the cursor within `to_string/1`."
  @spec offset(t()) :: non_neg_integer()
  def offset(%{lines: lines, row: row, col: col}) do
    prefix = lines |> Enum.take(row) |> Enum.reduce(0, fn l, acc -> acc + String.length(l) + 1 end)
    prefix + col
  end

  @doc "Move the cursor to an absolute character offset (clamped)."
  @spec move_to_offset(t(), integer()) :: t()
  def move_to_offset(ed, off) do
    text = __MODULE__.to_string(ed)
    off = off |> max(0) |> min(String.length(text))
    {row, col} = offset_to_rowcol(ed.lines, off)
    %{ed | row: row, col: col}
  end

  @doc "Delete the characters in the half-open offset range [a, b); cursor lands at the start."
  @spec delete_range(t(), integer(), integer()) :: t()
  def delete_range(ed, a, b) do
    {a, b} = {min(a, b), max(a, b)}
    text = __MODULE__.to_string(ed)
    new_text = String.slice(text, 0, a) <> String.slice(text, b..-1//1)
    set_text(ed, new_text, a)
  end

  @doc "Replace the whole buffer with `text`, putting the cursor at offset `off`. Keeps mode/pending/undo."
  @spec set_text(t(), String.t(), integer()) :: t()
  def set_text(ed, text, off) do
    lines =
      case String.split(text, "\n") do
        [] -> [""]
        ls -> ls
      end

    off = off |> max(0) |> min(String.length(text))
    {row, col} = offset_to_rowcol(lines, off)
    %{ed | lines: lines, row: row, col: col}
  end

  @doc "Push the current text/cursor onto the undo stack (called before a mutation)."
  @spec snapshot(t()) :: t()
  def snapshot(ed) do
    frame = %{lines: ed.lines, row: ed.row, col: ed.col}
    %{ed | undo: [frame | ed.undo] |> Enum.take(100)}
  end

  @doc "Restore the most recent undo snapshot, if any."
  @spec undo(t()) :: t()
  def undo(%{undo: []} = ed), do: ed
  def undo(%{undo: [frame | rest]} = ed),
    do: %{ed | lines: frame.lines, row: frame.row, col: frame.col, undo: rest}

  # ---- helpers ----

  defp current_line(ed), do: Enum.at(ed.lines, ed.row, "")
  defp put_line(ed, line), do: %{ed | lines: List.replace_at(ed.lines, ed.row, line)}
  defp line_length(ed, row), do: ed.lines |> Enum.at(row, "") |> String.length()

  defp offset_to_rowcol(lines, off), do: offset_to_rowcol(lines, off, 0)

  defp offset_to_rowcol([line | rest], off, row) do
    len = String.length(line)

    if off <= len or rest == [] do
      {row, min(off, len)}
    else
      offset_to_rowcol(rest, off - len - 1, row + 1)
    end
  end

  defp offset_to_rowcol([], _off, row), do: {row, 0}
end
