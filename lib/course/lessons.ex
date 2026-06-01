defmodule Course.Lessons do
  @moduledoc """
  The course content, as plain data.

  Each lesson is a map with:
    * `:title`   – shown in the header
    * `:info`    – the teaching text (multi-line string)
    * `:starter` – the code pre-filled into the editor
    * `:checks`  – a list of `%{call: {fun, args}, expect: value}` (optional `:delta`)

  To add a lesson, just append a map to the list in `all/0`. That's it —
  the app picks it up automatically.
  """

  @spec all() :: [map()]
  def all do
    [
      %{
        title: "Values & functions",
        info: """
        In Elixir a function returns the value of its LAST expression — there
        is no `return` keyword. The one-line form is:  def name(args), do: expr

        Task: make `double/1` return its argument multiplied by 2.
        """,
        starter: "def double(n) do\n  # your code here\nend\n",
        checks: [
          %{call: {:double, [10]}, expect: 20},
          %{call: {:double, [-3]}, expect: -6}
        ]
      },
      %{
        title: "String interpolation",
        info: """
        Strings interpolate with \#{...}:   "Hello, \#{name}!"

        Task: make `greet/1` turn "Ada" into "Hello, Ada!".
        """,
        starter: "def greet(name) do\n  # your code here\nend\n",
        checks: [
          %{call: {:greet, ["Ada"]}, expect: "Hello, Ada!"},
          %{call: {:greet, ["Daniel"]}, expect: "Hello, Daniel!"}
        ]
      },
      %{
        title: "Pattern matching in the head",
        info: """
        You can destructure arguments right in the function head. A 2-tuple
        pattern {x, y} binds both elements. Remember: `x` is a variable, but
        `:x` (with a colon) is a fixed atom value.

        Task: make `sum_point/1` add the two elements of a {x, y} tuple.
        """,
        starter: "def sum_point(point) do\n  # tip: match {x, y} = point, or do it in the head\nend\n",
        checks: [
          %{call: {:sum_point, [{3, 4}]}, expect: 7},
          %{call: {:sum_point, [{-2, 2}]}, expect: 0}
        ]
      },
      %{
        title: "Multiple clauses + tags",
        info: """
        Define the SAME function several times with different patterns; Elixir
        runs the first that matches. A leading "tag" atom selects the clause:

          def area({:circle, r}), do: 3.14159 * r * r
          def area({:rect, w, h}), do: w * h

        Task: implement both clauses of `area/1`.
        """,
        starter: "def area({:circle, r}) do\n  # your code\nend\n\ndef area({:rect, w, h}) do\n  # your code\nend\n",
        checks: [
          %{call: {:area, [{:circle, 2}]}, expect: 12.56636, delta: 0.001},
          %{call: {:area, [{:rect, 3, 4}]}, expect: 12}
        ]
      },
      %{
        title: "Recursion over a list",
        info: """
        There are no for/while loops — you recurse. The shape is a base clause
        for the empty list plus a clause that peels the head and recurses:

          def sum([]), do: 0
          def sum([h | t]), do: h + sum(t)

        Task: implement `sum/1` to add all numbers in a list.
        """,
        starter: "def sum([]) do\n  # base case\nend\n\ndef sum([h | t]) do\n  # recursive case\nend\n",
        checks: [
          %{call: {:sum, [[]]}, expect: 0},
          %{call: {:sum, [[1, 2, 3, 4]]}, expect: 10},
          %{call: {:sum, [[5]]}, expect: 5}
        ]
      },
      %{
        title: "Enum.map",
        info: """
        Instead of hand-writing recursion, reach for Enum. `Enum.map/2`
        transforms every element:

          Enum.map([1,2,3], fn x -> x * 10 end)   #=> [10, 20, 30]

        Task: make `triple_all/1` triple every number in the list.
        """,
        starter: "def triple_all(list) do\n  # use Enum.map\nend\n",
        checks: [
          %{call: {:triple_all, [[1, 2, 3]]}, expect: [3, 6, 9]},
          %{call: {:triple_all, [[]]}, expect: []}
        ]
      },
      %{
        title: "The pipeline |>",
        info: """
        The pipe passes the value on its left as the FIRST argument on the
        right, so you read top-to-bottom:

          list
          |> Enum.filter(fn x -> rem(x, 2) == 0 end)   # keep evens
          |> Enum.map(fn x -> x * 3 end)               # triple them
          |> Enum.sum()                                # add them up

        Task: implement `even_triples_sum/1` doing exactly that.
        Example: [1,2,3,4] -> evens [2,4] -> [6,12] -> 18
        """,
        starter: "def even_triples_sum(list) do\n  # build a |> pipeline\nend\n",
        checks: [
          %{call: {:even_triples_sum, [[1, 2, 3, 4]]}, expect: 18},
          %{call: {:even_triples_sum, [[1, 3, 5]]}, expect: 0},
          %{call: {:even_triples_sum, [[2, 4, 6]]}, expect: 36}
        ]
      }
    ]
  end
end
