import gleam/bool
import gleam/string
import shared/numbers/non_negative_float.{type NonNegativeFloat}

/// Parses a converter amount, rejecting leading signs while retaining exponent signs.
/// Other input syntax is delegated to the shared numeric parser.
pub fn parse_amount(text: String) -> Result(NonNegativeFloat, Nil) {
  use <- bool.guard(
    string.starts_with(text, "+") || string.starts_with(text, "-"),
    Error(Nil),
  )
  non_negative_float.parse(text)
}
