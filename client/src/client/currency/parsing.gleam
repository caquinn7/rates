import gleam/bool
import gleam/list
import gleam/result
import gleam/string
import shared/numbers/non_negative_float.{type NonNegativeFloat}

/// Parses a converter amount with valid comma grouping and optional leading or
/// trailing decimal points. Leading signs are rejected; exponent signs are accepted.
/// The original syntax is validated before normalizing a temporary numeric string.
pub fn parse_amount(text: String) -> Result(NonNegativeFloat, Nil) {
  case string.starts_with(text, "+") || string.starts_with(text, "-") {
    True -> Error(Nil)
    False ->
      text
      |> normalize_amount
      |> result.try(non_negative_float.parse)
  }
}

fn normalize_amount(text: String) -> Result(String, Nil) {
  use #(integer_part, fractional_part) <- result.try(
    case string.split(text, ".") {
      [integer] -> Ok(#(integer, ""))
      ["", ""] -> Error(Nil)
      ["", fraction] -> Ok(#("0", fraction))
      [integer, fraction] -> Ok(#(integer, fraction))
      _ -> Error(Nil)
    },
  )
  use <- bool.guard(string.contains(fractional_part, ","), Error(Nil))
  use <- bool.guard(
    string.contains(text, ",") && !is_valid_comma_grouping(integer_part),
    Error(Nil),
  )

  integer_part
  |> string.replace(",", "")
  |> string.append(case fractional_part {
    "" -> ""
    _ -> "." <> fractional_part
  })
  |> Ok
}

fn is_valid_comma_grouping(integer_part: String) -> Bool {
  let assert [head, ..tail] = string.split(integer_part, ",")
  is_digits(head)
  && string.length(head) <= 3
  && list.all(tail, fn(group) { string.length(group) == 3 && is_digits(group) })
}

fn is_digits(text: String) -> Bool {
  text != ""
  && list.all(string.to_graphemes(text), string.contains("0123456789", _))
}
