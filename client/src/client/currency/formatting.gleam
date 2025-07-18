import gleam/float
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import shared/currency.{type Currency, Crypto, Fiat}

/// Parses a string representing a numeric amount into a `Float`.
///
/// This function handles strings that may contain commas as thousands separators,
/// optional leading or trailing decimal points, and both integer and float representations.
/// If the string ends with a decimal point (e.g., "123."), the trailing dot is removed.
/// If the string starts with a decimal point (e.g., ".45"), a leading zero is added.
/// Returns `Result(Float, Nil)`, where `Ok(Float)` is the parsed value, or `Error(Nil)` if parsing fails.
///
/// # Examples
///
/// ```gleam
/// parse_amount("1,234.56") // Ok(1234.56)
/// parse_amount(".99")      // Ok(0.99)
/// parse_amount("1000")     // Ok(1000.0)
/// parse_amount("abc")      // Error(Nil)
/// ```
pub fn parse_amount(str: String) -> Result(Float, Nil) {
  let drop_trailing_decimal = fn(str) {
    case string.ends_with(str, ".") {
      False -> str
      True -> string.drop_end(str, 1)
    }
  }

  let add_zero_if_starts_with_decimal = fn(str) {
    case string.starts_with(str, ".") {
      False -> str
      True -> "0" <> str
    }
  }

  let remove_commas = string.replace(_, ",", "")

  let parse_float = fn(str) {
    str
    |> float.parse
    |> result.lazy_or(fn() {
      str
      |> int.parse
      |> result.map(int.to_float)
    })
  }

  str
  |> remove_commas
  |> drop_trailing_decimal
  |> add_zero_if_starts_with_decimal
  |> parse_float
}

/// Formats a floating-point `amount` as a string according to the given `currency`.
/// The determines the appropriate decimal precision, and groups the integer part
/// for readability. If the fractional part consists only of zeroes, it is omitted from the result.
/// Otherwise, the fractional part is included after a decimal point.
///
/// ## Arguments
/// - `currency`: The currency used to determine formatting rules.
/// - `amount`: The floating-point number to format.
///
/// ## Returns
/// A string representation of the formatted amount, suitable for display.
pub fn format_amount_str(currency: Currency, amount: Float) -> String {
  let amount = float.absolute_value(amount)

  let precision = determine_max_precision(currency, amount)
  let rounded = float.to_precision(amount, precision)
  let rounded_str = float.to_string(rounded)

  let assert [int_str, frac_str] = string.split(rounded_str, ".")
  let int_str = group_digits_with_commas(int_str)

  let frac_str_all_zeroes =
    frac_str
    |> string.replace("0", "")
    |> string.length
    == 0

  case frac_str_all_zeroes && amount >. 0.0 {
    True -> int_str
    False -> int_str <> "." <> frac_str
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
pub fn determine_max_precision(currency: Currency, amount: Float) -> Int {
  case currency {
    Fiat(..) -> 2

    Crypto(..) ->
      case amount {
        a if a == 0.0 -> 0
        a if a >=. 1.0 -> 4
        a if a >=. 0.01 -> 6
        _ -> 8
      }
  }
}

fn group_digits_with_commas(int_str: String) -> String {
  int_str
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
