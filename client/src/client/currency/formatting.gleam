import client/positive_float.{type PositiveFloat}
import gleam/list
import gleam/string
import shared/currency.{type Currency, Crypto, Fiat}

/// Formats a `PositiveFloat` amount as a human-readable string with appropriate
/// precision and comma grouping, based on the given `Currency`.
///
/// - For fiat currencies, the amount is always formatted with 2 decimal places.
/// - For cryptocurrencies, the decimal precision varies based on the size of the amount:
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
/// format_currency_amount(Fiat(..), PositiveFloat(1234.567)) // => "1,234.57"
/// format_currency_amount(Crypto(..), PositiveFloat(0.00000123)) // => "0.00000123"
/// format_currency_amount(Crypto(..), PositiveFloat(1.2300)) // => "1.23"
/// ```
pub fn format_currency_amount(
  currency: Currency,
  amount: PositiveFloat,
) -> String {
  let precision = determine_max_precision(currency, amount)
  let assert Ok(result) = positive_float.to_fixed_string(amount, precision)

  case string.split(result, ".") {
    [int_part, frac_part] -> {
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

/// Determines the maximum number of decimal places (precision) to use when formatting
/// a given amount for a specific currency type.
///
/// For cryptocurrencies, the precision varies based on the value of the amount:
/// - 0 decimal places if the amount is zero
/// - 4 decimal places if the amount is at least 1.0
/// - 6 decimal places if the amount is at least 0.01 but less than 1.0
/// - 8 decimal places for smaller amounts
///
/// For fiat currencies, the precision is always 2 decimal places.
///
/// # Arguments
/// - `currency`: The currency, which can be either `Crypto` or `Fiat`.
/// - `amount`: The numeric value to determine the precision for.
///
/// # Returns
/// The maximum number of decimal places to use for formatting the amount.
pub fn determine_max_precision(currency: Currency, amount: PositiveFloat) -> Int {
  case currency {
    Fiat(..) -> 2

    Crypto(..) ->
      positive_float.with_value(amount, fn(a) {
        case a {
          a if a == 0.0 -> 0
          a if a >=. 1.0 -> 4
          a if a >=. 0.01 -> 6
          _ -> 8
        }
      })
  }
}
