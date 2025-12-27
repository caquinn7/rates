import gleam/list
import gleam/string
import shared/non_negative_float.{type NonNegativeFloat}

/// Formats a `NonNegativeFloat` amount as a human-readable string with appropriate
/// precision and comma grouping.
///
/// - The decimal precision varies based on the size of the amount:
///     - 0.0 → 0 decimal places
///     - ≥ 1.0 → 4 decimal places
///     - ≥ 0.01 → 6 decimal places
///     - < 0.01 → 8 decimal places
///
/// The integer portion of the result is grouped with commas (e.g., `1,234.56`).
/// Trailing zeroes in the decimal portion are removed (e.g., `1.2300` becomes `1.23`).
///
/// ## Examples
/// ```gleam
/// format_currency_amount(NonNegativeFloat(1234.567)) // => "1,234.567"
/// format_currency_amount(NonNegativeFloat(0.00000123)) // => "0.00000123"
/// format_currency_amount(NonNegativeFloat(1.2300)) // => "1.23"
/// ```
pub fn format_currency_amount(amount: NonNegativeFloat) -> String {
  let precision = determine_max_precision(amount)

  // todo: do not assert
  let assert Ok(result) = non_negative_float.to_fixed_string(amount, precision)

  case string.split(result, ".") {
    [int_part, frac_part] -> {
      let int_part = add_comma_grouping(int_part)
      let trimmed_frac =
        frac_part
        |> string.to_graphemes
        |> list.reverse
        |> list.drop_while(fn(c) { c == "0" })
        |> list.reverse
        |> string.join("")

      case trimmed_frac {
        "" -> int_part
        _ -> int_part <> "." <> trimmed_frac
      }
    }
    _ -> result
  }
}

/// Adds comma grouping to an integer string.
/// E.g., "1234567" becomes "1,234,567"
fn add_comma_grouping(int_string: String) -> String {
  int_string
  |> string.to_graphemes
  |> list.reverse
  |> list.sized_chunk(3)
  |> list.map(fn(chunk) {
    chunk
    |> list.reverse
    |> string.join("")
  })
  |> list.reverse
  |> string.join(",")
}

/// Determines the maximum number of decimal places (precision) to use
/// when formatting a given currency amount.
///
/// The precision varies based on the value of the amount:
/// - 0 decimal places if the amount is zero
/// - 4 decimal places if the amount is at least 1.0
/// - 6 decimal places if the amount is at least 0.01 but less than 1.0
/// - 8 decimal places for smaller amounts
pub fn determine_max_precision(amount: NonNegativeFloat) -> Int {
  // todo: use an epsilon?
  non_negative_float.with_value(amount, fn(a) {
    case a {
      _ if a == 0.0 -> 0
      _ if a >=. 1.0 -> 4
      _ if a >=. 0.01 -> 6
      _ -> 8
    }
  })
}
