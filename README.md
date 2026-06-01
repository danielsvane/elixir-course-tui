# Elixir Course (TUI)

An interactive terminal course for learning Elixir, built with
[TermUI](https://github.com/pcharbon70/term_ui). Each lesson shows some
teaching text and a code editor; you write a solution and press a key to run
it against the lesson's checks.

## Run it

```sh
cd course
mix run -e "Course.start()"
```

(It takes over the terminal, so run it in a real terminal, not a pipe.)

## Keys

The code editor is **modal, Vim-style**. You start in **Normal** mode.

Course commands (work in any mode):

| Key      | Action                          |
|----------|---------------------------------|
| Ctrl+R   | run your code against checks    |
| PageDown | next lesson                     |
| PageUp   | previous lesson                 |
| Ctrl+L   | reset the lesson to its starter |
| `:q`     | quit (Vim-style; type `:` then `q` then Enter) |
| Ctrl+C   | quit (backup chord; cleans up the terminal too) |

Vim editing (in the code area):

| Mode   | Keys                                                    |
|--------|---------------------------------------------------------|
| Normal | `h j k l` / arrows, `w b e`, `0 $ ^`, `gg`, `G`         |
| Normal | `i a A I` enter insert · `o O` open line                |
| Normal | `v` charwise visual · `V` linewise visual               |
| Normal | `:` command line — `:q` / `:quit` to exit               |
| Normal | `x`, `D`, `dd`, `dw db de`, `d$ d0`, `diw daw`          |
| Normal | `C`, `cc`, `cw cb ce`, `c$ c0`, `ciw caw`               |
| Normal | `u` undo                                                |
| Visual | any motion extends the selection · `d`/`x` delete · `c` change · `v`/`V` toggle · `Esc` |
| Insert | type to edit · `Enter` newline · `Tab` 2 spaces · `Esc` |

`V` selects whole lines (extend with `j`/`k`); `v` selects characters (extend
with any motion, and like real Vim it's inclusive of the cursor cell, so `vwd`
differs from `dw`).

Not yet implemented (good things to add yourself): counts like `3w`, search
`/`, registers, yank/paste, and `.` repeat. The whole Vim layer lives in
`lib/course/vim.ex` as pure functions, with tests in `test/course_test.exs`.

## How it's built (the parts you'll extend)

| File                      | Responsibility                                            |
|---------------------------|-----------------------------------------------------------|
| `lib/course/lessons.ex`   | The course content as plain data. **Add lessons here.**   |
| `lib/course/editor.ex`    | A pure multi-line text-editor model (lines + cursor).     |
| `lib/course/evaluator.ex` | Compiles your code and runs each lesson's checks.         |
| `lib/course/app.ex`       | The Elm app: `init` / `event_to_msg` / `update` / `view`. |
| `lib/course.ex`           | `Course.start/0` entry point.                             |

### Adding a lesson

Append a map to the list in `Course.Lessons.all/0`:

```elixir
%{
  title: "My lesson",
  info: "Explain the idea here.\nMultiple lines are fine.",
  starter: "def my_fun(x) do\n  # your code\nend\n",
  checks: [
    %{call: {:my_fun, [1]}, expect: 2},
    %{call: {:my_fun, [5]}, expect: 6}
  ]
}
```

A check is `%{call: {function_name, [args]}, expect: value}`. Add `delta:`
for float comparisons, e.g. `%{call: {:area, [2]}, expect: 12.566, delta: 0.001}`.

## Tests

```sh
mix test
```

The editor, evaluator, and the whole Elm loop are tested headlessly (no
terminal needed) by driving `update/2` and rendering `view/1` directly.
