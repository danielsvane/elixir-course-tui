defmodule Course.Highlight do
  @moduledoc """
  A tiny, pure Elixir syntax highlighter.

  `segments/1` turns one line of source into a list of `{text, color}` chunks,
  where `color` is a `TermUI` foreground color (an atom) or `nil` for "use the
  default". It's a deliberately small, single-line tokenizer — no multi-line
  state (heredocs, `"""` strings) — so it stays easy to read and is enough to
  make the code area pleasant. Like the rest of the project it's written as
  plain, beginner-readable Elixir and is fully unit-tested.

  The approach: a list of `{regex, category}` rules, each anchored at the start
  of the remaining text (`\\A`). At every position we try the rules in order and
  the first one that matches consumes that chunk. Identifiers get a second look
  to see whether they're actually keywords.
  """

  # Words that read as language keywords / common special forms. They aren't
  # all reserved in Elixir, but colouring them this way matches how editors and
  # IEx present code, which is what learners will recognise.
  @keywords ~w(
    def defp defmodule defmacro defmacrop defstruct defprotocol
    defimpl defdelegate defguard defguardp defexception
    do end fn if else unless case cond when and or not in
    for with try catch rescue after raise reraise throw receive
    import alias require use quote unquote super
    true false nil
  )

  # Rules tried in order at each position. Order matters: comments and strings
  # win before anything inside them could match.
  @rules [
    {~r/\A#.*/u, :comment},
    {~r/\A"(?:\\.|[^"\\])*"?/u, :string},
    {~r/\A'(?:\\.|[^'\\])*'?/u, :string},
    {~r/\A\?(?:\\.|.)/u, :string},
    {~r/\A:(?:"(?:\\.|[^"\\])*"|[a-zA-Z_]\w*[?!]?)/u, :atom},
    {~r/\A@[a-zA-Z_]\w*/u, :attr},
    {~r/\A&\d+/u, :number},
    {~r/\A\d[\d_]*(?:\.\d+)?(?:[eE][+-]?\d+)?/u, :number},
    {~r/\A0[xob][0-9a-fA-F]+/u, :number},
    {~r/\A[A-Z][A-Za-z0-9_]*(?:\.[A-Z][A-Za-z0-9_]*)*/u, :module},
    {~r/\A[a-z_][A-Za-z0-9_]*[?!]?/u, :ident},
    {~r/\A\s+/u, :space},
    {~r/\A./u, :punct}
  ]

  @colors %{
    comment: :bright_black,
    string: :green,
    atom: :cyan,
    attr: :magenta,
    number: :yellow,
    module: :yellow,
    keyword: :magenta,
    ident: nil,
    space: nil,
    punct: nil
  }

  @doc """
  Split a single line into `{text, color}` segments.

  Adjacent segments of the same colour are merged so the result is compact.
  """
  @spec segments(String.t()) :: [{String.t(), atom() | nil}]
  def segments(""), do: [{"", nil}]

  def segments(line) do
    line
    |> tokenize([])
    |> merge_adjacent()
  end

  # Walk the line, peeling off one token at a time.
  defp tokenize("", acc), do: Enum.reverse(acc)

  defp tokenize(rest, acc) do
    {text, category, rest} = next_token(rest)
    tokenize(rest, [{text, color_of(text, category)} | acc])
  end

  defp next_token(rest) do
    Enum.find_value(@rules, fn {re, category} ->
      case Regex.run(re, rest) do
        [match | _] when match != "" ->
          {match, category, binary_part(rest, byte_size(match), byte_size(rest) - byte_size(match))}

        _ ->
          nil
      end
    end)
  end

  # An identifier that happens to be a keyword is recoloured as one.
  defp color_of(text, :ident) when text in @keywords, do: @colors.keyword
  defp color_of(_text, category), do: Map.get(@colors, category)

  defp merge_adjacent(segments) do
    segments
    |> Enum.chunk_by(fn {_text, color} -> color end)
    |> Enum.map(fn group ->
      color = group |> hd() |> elem(1)
      text = group |> Enum.map_join("", fn {t, _} -> t end)
      {text, color}
    end)
  end
end
