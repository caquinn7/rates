import gleam/list
import gleam/string
import shared/currency.{type Currency, Crypto, Fiat}
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
/// ### Examples
/// ```gleam
/// format_currency_amount(NonNegativeFloat(1234.567)) // => "1,234.567"
/// format_currency_amount(NonNegativeFloat(0.00000123)) // => "0.00000123"
/// format_currency_amount(NonNegativeFloat(1.2300)) // => "1.23"
/// ```
pub fn format_currency_amount(
  currency: Currency,
  amount: NonNegativeFloat,
) -> String {
  let precision = determine_max_precision(currency, amount)

  let fixed_str = case non_negative_float.to_fixed_string(amount, precision) {
    Ok(s) -> s
    _ -> non_negative_float.to_string(amount)
  }

  case string.split(fixed_str, ".") {
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
    _ -> fixed_str
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
/// when formatting a given currency amount for display.
///
/// Precision is selected based on both the currency type and the
/// conceptual magnitude of the amount.
///
/// ### Fiat currencies
/// - `0` decimal places if the amount is effectively zero
/// - `2` decimal places for normal values (≥ 0.01)
/// - `8` decimal places for sub-cent values (< 0.01 but non-zero),
///   to avoid rounding small but meaningful amounts down to zero
///
/// ### Cryptocurrencies
/// - `0` decimal places if the amount is effectively zero
/// - `4` decimal places if the amount is at least `1.0`
/// - `6` decimal places if the amount is at least `0.01` but less than `1.0`
/// - `8` decimal places for smaller amounts
///
/// To avoid display flicker caused by floating-point representation error,
/// the function applies a small tolerance when comparing against thresholds,
/// so values extremely close to a boundary are treated as belonging to the
/// expected tier.
pub fn determine_max_precision(
  currency: Currency,
  amount: NonNegativeFloat,
) -> Int {
  let eps = 1.0e-12

  case currency {
    Fiat(..) ->
      non_negative_float.with_value(amount, fn(a) {
        case a {
          _ if a <=. eps -> 0
          // sub-cent fiat needs more precision
          _ if a +. eps <. 0.01 -> 8
          _ -> 2
        }
      })

    Crypto(..) ->
      non_negative_float.with_value(amount, fn(a) {
        case a {
          _ if a <=. eps -> 0
          _ if a +. eps >=. 1.0 -> 4
          _ if a +. eps >=. 0.01 -> 6
          _ -> 8
        }
      })
  }
}
