defmodule CourseTest do
  use ExUnit.Case

  alias Course.{App, Editor, Evaluator}
  alias TermUI.Event

  describe "Editor" do
    test "from_string / to_string round-trips" do
      ed = Editor.from_string("a\nb\nc")
      assert ed.lines == ["a", "b", "c"]
      assert Editor.to_string(ed) == "a\nb\nc"
    end

    test "insert places a char at the cursor and advances it" do
      ed = Editor.from_string("") |> Editor.insert("h") |> Editor.insert("i")
      assert Editor.to_string(ed) == "hi"
      assert ed.col == 2
    end

    test "newline splits the current line" do
      ed = %{Editor.from_string("abcd") | col: 2} |> Editor.newline()
      assert ed.lines == ["ab", "cd"]
      assert ed.row == 1 and ed.col == 0
    end

    test "backspace deletes within a line" do
      ed = %{Editor.from_string("abc") | col: 3} |> Editor.backspace()
      assert Editor.to_string(ed) == "ab"
    end

    test "backspace at column 0 merges with the previous line" do
      ed = %{Editor.from_string("ab\ncd") | row: 1, col: 0} |> Editor.backspace()
      assert ed.lines == ["abcd"]
      assert ed.row == 0 and ed.col == 2
    end

    test "movement clamps at the edges" do
      ed = Editor.from_string("ab\nc")
      assert Editor.move(ed, :left) == ed
      assert Editor.move(ed, :up) == ed
      moved = ed |> Editor.move(:right) |> Editor.move(:right) |> Editor.move(:right)
      assert {moved.row, moved.col} == {1, 0}
    end
  end

  describe "Evaluator" do
    test "a correct solution passes every check" do
      checks = [%{call: {:double, [10]}, expect: 20}, %{call: {:double, [-3]}, expect: -6}]
      assert {:ok, results} = Evaluator.run("def double(n), do: n * 2", checks)
      assert Enum.all?(results, & &1.pass)
    end

    test "a wrong solution reports the mismatch but still compiles" do
      checks = [%{call: {:double, [10]}, expect: 20}]
      assert {:ok, [r]} = Evaluator.run("def double(n), do: n + 2", checks)
      refute r.pass
      assert r.got == 12
    end

    test "non-compiling code returns an error" do
      assert {:error, message} = Evaluator.run("def double(n), do: ", [])
      assert is_binary(message)
    end

    test "delta allows float tolerance" do
      checks = [%{call: {:area, [2]}, expect: 12.56636, delta: 0.001}]
      assert {:ok, [r]} = Evaluator.run("def area(r), do: 3.14159 * r * r", checks)
      assert r.pass
    end

    test "a raising function is caught, not crashed" do
      checks = [%{call: {:boom, []}, expect: :ok}]
      assert {:ok, [r]} = Evaluator.run("def boom, do: raise \"nope\"", checks)
      refute r.pass
      assert r.error =~ "nope"
    end
  end

  describe "App (driven headlessly)" do
    test "init builds a buffer for the first lesson" do
      state = App.init([])
      assert state.idx == 0
      assert Map.has_key?(state.buffers, 0)
      assert is_binary(Editor.to_string(state.buffers[0]))
    end

    test "event_to_msg routes commands vs Vim keys" do
      # Ctrl/Page keys are course commands
      assert App.event_to_msg(%Event.Key{key: "r", modifiers: [:ctrl]}, %{}) == {:msg, :run}
      # Ctrl+C is the chord-based quit (Ctrl+Q is unreliable in Kitty et al.)
      assert App.event_to_msg(%Event.Key{key: "c", modifiers: [:ctrl]}, %{}) == {:msg, :quit}
      assert App.event_to_msg(%Event.Key{key: "q", modifiers: [:ctrl]}, %{}) == :ignore
      assert App.event_to_msg(%Event.Key{key: :page_down}, %{}) == {:msg, :next}
      assert App.event_to_msg(%Event.Key{key: :page_up}, %{}) == {:msg, :prev}

      # Everything else goes to the Vim layer as {:key, _}
      assert App.event_to_msg(%Event.Key{key: "a", char: "a", modifiers: []}, %{}) ==
               {:msg, {:key, "a"}}

      assert App.event_to_msg(%Event.Key{key: :escape}, %{}) == {:msg, {:key, :escape}}
      assert App.event_to_msg(%Event.Key{key: :enter}, %{}) == {:msg, {:key, :enter}}
      assert App.event_to_msg(%Event.Key{key: :up}, %{}) == {:msg, {:key, :up}}
    end

    test "you can type a solution through the Vim layer and run it" do
      # Start on lesson 1 (double/1). Buffer starts empty + Normal mode.
      state = put_code(App.init([]), "")
      # i  -> insert mode, then type the one-liner, then Esc
      keys = ["i" | String.graphemes("def double(n), do: n * 2")] ++ [:escape]
      state = Enum.reduce(keys, state, fn k, s -> elem(App.update({:key, k}, s), 0) end)
      {state, []} = App.update(:run, state)
      assert {:ok, results} = state.result
      assert Enum.all?(results, & &1.pass)
    end

    test "typing a solution and running it solves lesson 1" do
      state = App.init([]) |> put_code("def double(n), do: n * 2")
      {state, []} = App.update(:run, state)
      assert {:ok, results} = state.result
      assert Enum.all?(results, & &1.pass)
    end

    test "Ctrl+Q asks the runtime to quit" do
      assert {_state, [:quit]} = App.update(:quit, App.init([]))
    end

    test "navigation moves between lessons and clamps" do
      state = App.init([])
      total = length(state.lessons)
      {next, []} = App.update(:next, state)
      assert next.idx == 1
      {back, []} = App.update(:prev, next)
      assert back.idx == 0
      last = Enum.reduce(1..(total + 3), state, fn _, s -> elem(App.update(:next, s), 0) end)
      assert last.idx == total - 1
    end

    test "view/1 renders a render tree without crashing, for every lesson" do
      state = App.init([])

      for idx <- 0..(length(state.lessons) - 1) do
        s = ensure_view_buffer(%{state | idx: idx})
        node = App.view(s)
        assert is_struct(node, TermUI.Component.RenderNode)
      end
    end

    test "view/1 renders a results section after a run" do
      state = App.init([]) |> put_code("def double(n), do: n + 1")
      {state, []} = App.update(:run, state)
      node = App.view(state)
      assert is_struct(node, TermUI.Component.RenderNode)
    end
  end

  describe "Vim" do
    alias Course.Vim

    # Apply a list of keys (strings or atoms) to an editor.
    defp keys(ed, list), do: Enum.reduce(list, ed, &Vim.handle(&2, &1))

    test "starts in normal mode; i enters insert and types text" do
      ed = Editor.from_string("")
      assert ed.mode == :normal
      ed = keys(ed, ["i" | String.graphemes("hello")])
      assert ed.mode == :insert
      assert Editor.to_string(ed) == "hello"
      ed = Vim.handle(ed, :escape)
      assert ed.mode == :normal
    end

    test "w / b / e word motions" do
      ed = Editor.from_string("foo bar baz")
      assert keys(ed, ["w"]).col == 4
      assert keys(ed, ["w", "w"]).col == 8
      assert keys(ed, ["$", "b"]).col == 8
      assert keys(ed, ["e"]).col == 2
    end

    test "0 and $ jump to line ends" do
      ed = %{Editor.from_string("hello world") | col: 5}
      assert keys(ed, ["0"]).col == 0
      assert keys(ed, ["$"]).col == 10
    end

    test "x deletes the char under the cursor" do
      ed = Editor.from_string("abc")
      assert Editor.to_string(keys(ed, ["x"])) == "bc"
    end

    test "dd deletes the current line" do
      ed = %{Editor.from_string("one\ntwo\nthree") | row: 1}
      assert Editor.to_string(keys(ed, ["d", "d"])) == "one\nthree"
    end

    test "dw deletes a word forward" do
      ed = Editor.from_string("foo bar baz")
      assert Editor.to_string(keys(ed, ["d", "w"])) == "bar baz"
    end

    test "ciw changes the inner word, landing in insert mode" do
      ed = %{Editor.from_string("foo bar baz") | col: 4}
      ed = keys(ed, ["c", "i", "w"])
      assert ed.mode == :insert
      assert Editor.to_string(ed) == "foo  baz"
      ed = keys(ed, String.graphemes("QUX"))
      assert Editor.to_string(ed) == "foo QUX baz"
    end

    test "diw deletes the inner word" do
      ed = %{Editor.from_string("foo bar baz") | col: 4}
      assert Editor.to_string(keys(ed, ["d", "i", "w"])) == "foo  baz"
    end

    test "u undoes the last change" do
      ed = Editor.from_string("abc")
      changed = keys(ed, ["x"])
      assert Editor.to_string(changed) == "bc"
      restored = Vim.handle(changed, "u")
      assert Editor.to_string(restored) == "abc"
    end

    test "an unfinished operator (d) then an invalid key cancels cleanly" do
      ed = Editor.from_string("abc")
      ed = Vim.handle(ed, "d")
      assert ed.pending == "d"
      ed = Vim.handle(ed, "z")
      assert ed.pending == ""
      assert Editor.to_string(ed) == "abc"
    end

    test "V enters linewise visual and selects the current line" do
      ed = %{Editor.from_string("one\ntwo\nthree") | row: 1}
      ed = Vim.handle(ed, "V")
      assert ed.mode == :vline
      assert Vim.selection(ed) == {:lines, 1, 1}
    end

    test "V then j extends the linewise selection, and d deletes those lines" do
      ed = %{Editor.from_string("one\ntwo\nthree\nfour") | row: 1}
      ed = keys(ed, ["V", "j"])
      assert Vim.selection(ed) == {:lines, 1, 2}
      ed = Vim.handle(ed, "d")
      assert ed.mode == :normal
      assert Editor.to_string(ed) == "one\nfour"
    end

    test "Vd on the only line leaves a single empty line" do
      ed = Editor.from_string("solo")
      assert Editor.to_string(keys(ed, ["V", "d"])) == ""
    end

    test "V upward (k) selects the range regardless of direction" do
      ed = %{Editor.from_string("a\nb\nc\nd") | row: 2}
      ed = keys(ed, ["V", "k"])
      assert Vim.selection(ed) == {:lines, 1, 2}
      assert Editor.to_string(Vim.handle(ed, "d")) == "a\nd"
    end

    test "Vc clears the lines and drops into insert mode" do
      ed = %{Editor.from_string("keep\ndrop\nkeep2") | row: 1}
      ed = keys(ed, ["V", "c"])
      assert ed.mode == :insert
      assert Editor.to_string(ed) == "keep\n\nkeep2"
      ed = keys(ed, String.graphemes("new"))
      assert Editor.to_string(ed) == "keep\nnew\nkeep2"
    end

    test "v charwise is inclusive of the cursor cell (vw differs from dw)" do
      ed = Editor.from_string("foo bar baz")
      # `w` lands on the 'b' of bar; visual selection includes it, so `vwd`
      # deletes "foo b" — unlike the exclusive operator `dw`.
      ed = keys(ed, ["v", "w"])
      assert ed.mode == :visual
      assert Editor.to_string(Vim.handle(ed, "d")) == "ar baz"
    end

    test "v then $ selects to end of line inclusively" do
      ed = Editor.from_string("abcde")
      ed = keys(ed, ["v", "$"])
      assert Editor.to_string(Vim.handle(ed, "d")) == ""
    end

    test "Esc leaves visual mode without changing text" do
      ed = %{Editor.from_string("hello") | col: 1}
      ed = keys(ed, ["v", "l", "l"])
      assert ed.mode == :visual
      ed = Vim.handle(ed, :escape)
      assert ed.mode == :normal
      assert ed.vstart == nil
      assert Editor.to_string(ed) == "hello"
    end

    test "v then V toggles to linewise; v again exits visual" do
      ed = Editor.from_string("line")
      ed = Vim.handle(ed, "v")
      assert ed.mode == :visual
      ed = Vim.handle(ed, "V")
      assert ed.mode == :vline
      ed = Vim.handle(ed, "V")
      assert ed.mode == :normal
    end

    test ": opens the command line and accumulates typed characters" do
      ed = Editor.from_string("code")
      ed = keys(ed, [":" | String.graphemes("quit")])
      assert ed.mode == :command
      assert ed.cmdline == "quit"
    end

    test "command-line backspace edits, then cancels at empty" do
      ed = keys(Editor.from_string("x"), [":", "q", "x"])
      assert ed.cmdline == "qx"
      ed = Vim.handle(ed, :backspace)
      assert ed.cmdline == "q"
      ed = Vim.handle(ed, :backspace)
      assert ed.cmdline == ""
      # one more backspace on the empty line drops back to Normal
      ed = Vim.handle(ed, :backspace)
      assert ed.mode == :normal
    end

    test "Esc cancels the command line without quitting" do
      ed = keys(Editor.from_string("x"), [":", "q"])
      ed = Vim.handle(ed, :escape)
      assert ed.mode == :normal
      assert ed.cmdline == ""
    end
  end

  describe "Highlight" do
    alias Course.Highlight

    # Find the colour assigned to the first segment whose text contains `needle`.
    defp color_of(line, needle) do
      Enum.find_value(Highlight.segments(line), fn {text, color} ->
        if String.contains?(text, needle), do: {:found, color}
      end)
    end

    test "segments reassemble into the original line" do
      line = ~s|def double(n), do: n * 2 # hi|
      reassembled = Highlight.segments(line) |> Enum.map_join("", fn {t, _} -> t end)
      assert reassembled == line
    end

    test "an empty line yields a single blank, uncoloured segment" do
      assert Highlight.segments("") == [{"", nil}]
    end

    test "keywords, modules, atoms, numbers, strings and comments get colours" do
      assert color_of("def foo", "def") == {:found, :magenta}
      assert color_of("Enum.map", "Enum") == {:found, :yellow}
      assert color_of("x = :ok", ":ok") == {:found, :cyan}
      assert color_of("n * 2", "2") == {:found, :yellow}
      assert color_of(~s|x = "hi"|, "\"hi\"") == {:found, :green}
      assert color_of("x # note", "# note") == {:found, :bright_black}
      assert color_of("@moduledoc false", "@moduledoc") == {:found, :magenta}
    end

    test "plain identifiers and punctuation stay uncoloured" do
      assert color_of("foo bar", "foo") == {:found, nil}
      assert color_of("a + b", "+") == {:found, nil}
    end

    test "a '#' inside a string is not treated as a comment" do
      # The whole string (including the #) should be one green segment.
      assert color_of(~s|x = "a # b"|, "# b") == {:found, :green}
    end
  end

  describe "App command line (`:q`)" do
    defp type(state, list), do: Enum.reduce(list, state, fn k, s -> elem(App.update({:key, k}, s), 0) end)

    test ":q quits the app" do
      state = type(App.init([]), [":", "q"])
      assert current(state).mode == :command
      assert {_state, [:quit]} = App.update({:key, :enter}, state)
    end

    test ":quit also quits" do
      state = type(App.init([]), [":" | String.graphemes("quit")])
      assert {_state, [:quit]} = App.update({:key, :enter}, state)
    end

    test "an unknown :command flashes a status and returns to Normal" do
      state = type(App.init([]), [":" | String.graphemes("nope")])
      {state, []} = App.update({:key, :enter}, state)
      assert current(state).mode == :normal
      assert state.status =~ "Not a course command"
      # the next keystroke clears the transient status
      {state, []} = App.update({:key, "j"}, state)
      assert state.status == nil
    end

    test "bare :⏎ just closes the command line" do
      state = type(App.init([]), [":"])
      {state, []} = App.update({:key, :enter}, state)
      assert current(state).mode == :normal
      assert state.status == nil
    end
  end

  # Helpers
  defp current(state), do: state.buffers[state.idx]

  defp put_code(state, code) do
    %{state | buffers: Map.put(state.buffers, state.idx, Editor.from_string(code))}
  end

  defp ensure_view_buffer(state) do
    if Map.has_key?(state.buffers, state.idx) do
      state
    else
      starter = Enum.at(state.lessons, state.idx).starter
      %{state | buffers: Map.put(state.buffers, state.idx, Editor.from_string(starter))}
    end
  end
end
