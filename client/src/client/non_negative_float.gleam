import gleam/bool
import gleam/float
import gleam/function
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A non-negative floating-point number.
///
/// The `NonNegativeFloat` type guarantees that the wrapped `Float` is
/// greater than or equal to zero. Use the `new` or `parse` functions
/// to construct values of this type safely.
pub opaque type NonNegativeFloat {
  NonNegativeFloat(Float)
}

/// Creates a `NonNegativeFloat` from a `Float`, returning an error if the value is negative.
///
/// Returns:
/// - `Ok(NonNegativeFloat)` if the float is greater than or equal to zero
/// - `Error(Nil)` if the float is negative
pub fn new(f: Float) -> Result(NonNegativeFloat, Nil) {
  case f >=. 0.0 {
    False -> Error(Nil)
    True -> Ok(NonNegativeFloat(f))
  }
}

pub fn from_float_unsafe(x: Float) -> NonNegativeFloat {
  case new(x) {
    Error(_) -> panic as "Expected a non-negative value"
    Ok(p) -> p
  }
}

/// Parses a string into a `NonNegativeFloat`, validating formatting and positivity.
///
/// Accepts:
/// - Optional commas in the integer portion (e.g., `"1,000.25"`)
/// - Leading decimal points (e.g., `".5"` becomes `"0.5"`)
/// - Trailing decimal points (e.g., `"1."` becomes `"1.0"`)
///
/// Rejects:
/// - Invalid comma grouping (e.g., `"1,2,3"`)
/// - Scientific notation (e.g., `"1e10"`)
/// - Negative values or non-numeric input
pub fn parse(str: String) -> Result(NonNegativeFloat, Nil) {
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

  let is_valid_comma_grouping = fn(int_str) {
    let assert [head, ..tail] = string.split(int_str, ",")

    string.length(head) <= 3
    && list.all(tail, fn(chunk) { string.length(chunk) == 3 })
  }

  let parse_float = fn(str) {
    str
    |> float.parse
    |> result.lazy_or(fn() {
      str
      |> int.parse
      |> result.map(int.to_float)
    })
  }

  let cleaned =
    str
    |> drop_trailing_decimal
    |> add_zero_if_starts_with_decimal

  use #(int_part, frac_part) <- result.try(case string.split(cleaned, ".") {
    [i] -> Ok(#(i, ""))
    [i, f] -> Ok(#(i, f))
    _ -> Error(Nil)
  })

  let str_has_comma = string.contains(str, ",")
  use <- bool.guard(
    str_has_comma && !is_valid_comma_grouping(int_part),
    Error(Nil),
  )

  int_part
  |> string.replace(",", "")
  |> string.append(case frac_part == "" {
    False -> "." <> frac_part
    True -> ""
  })
  |> parse_float
  |> result.try(new)
}

/// Applies a function to the inner float value of a `NonNegativeFloat` and returns the result.
///
/// This is useful for inspecting or transforming the float without unwrapping directly.
///
/// Example:
/// ```gleam
/// let str_value = with_value(p, float.to_string)
/// ```
pub fn with_value(p: NonNegativeFloat, fun: fn(Float) -> a) -> a {
  let NonNegativeFloat(value) = p
  fun(value)
}

pub fn unwrap(p: NonNegativeFloat) -> Float {
  with_value(p, function.identity)
}

/// Returns the largest possible `NonNegativeFloat` representable in JavaScript.
pub fn max() -> NonNegativeFloat {
  NonNegativeFloat(1.7976931348623157e308)
}

/// Returns `True` if the inner value is exactly `0.0`, otherwise `False`.
pub fn is_zero(p: NonNegativeFloat) -> Bool {
  with_value(p, fn(f) { f == 0.0 })
}

pub fn multiply(a: NonNegativeFloat, b: NonNegativeFloat) -> NonNegativeFloat {
  use a <- with_value(a)
  use b <- with_value(b)
  NonNegativeFloat(a *. b)
}

/// Attempts to divide two `NonNegativeFloat` values, returning a `Result`.
///
/// If the division is successful, returns `Ok(NonNegativeFloat)` with the result.
/// If the operation fails (e.g., division by zero), returns `Error(Nil)`.
///
/// # Arguments
/// - `a`: The dividend as a `NonNegativeFloat`.
/// - `b`: The divisor as a `NonNegativeFloat`.
///
/// # Returns
/// - `Result(NonNegativeFloat, Nil)`: The result of the division or an error.
pub fn try_divide(
  a: NonNegativeFloat,
  b: NonNegativeFloat,
) -> Result(NonNegativeFloat, Nil) {
  use a <- with_value(a)
  use b <- with_value(b)
  result.map(float.divide(a, b), NonNegativeFloat)
}

/// Returns `True` if the first `NonNegativeFloat` is strictly less than the second, otherwise `False`.
pub fn is_less_than(a: NonNegativeFloat, b: NonNegativeFloat) -> Bool {
  use a <- with_value(a)
  use b <- with_value(b)
  a <. b
}

/// Returns `True` if the first `NonNegativeFloat` is strictly greater than the second, otherwise `False`.
pub fn is_greater_than(a: NonNegativeFloat, b: NonNegativeFloat) -> Bool {
  use a <- with_value(a)
  use b <- with_value(b)
  a >. b
}

/// Converts a `NonNegativeFloat` to its string representation.
///
/// This function returns the standard string representation of the underlying
/// float value, which may include decimal places or scientific notation for
/// very large or very small numbers.
///
/// ## Notes
/// - For precise decimal formatting, consider using `to_fixed_string` instead.
/// - The output format follows Gleam's `float.to_string` behavior.
pub fn to_string(p: NonNegativeFloat) -> String {
  with_value(p, float.to_string)
}

pub type ToFixedStringError {
  InvalidPrecision
  UnexpectedFormat
}

/// Converts a `NonNegativeFloat` to a string with fixed decimal precision.
///
/// - The number is formatted using JavaScript’s native `Number.prototype.toFixed`
///   method via FFI, which rounds the number to exactly `precision` digits after
///   the decimal point.
/// - When `precision` is `0`, the decimal point is omitted entirely.
///
/// ## Errors
/// - Returns `Error(InvalidPrecision)` if `precision` is less than 0 or greater than 100.
/// - Returns `Error(UnexpectedFormat)` if the underlying `toFixed` output does not
///   include a decimal when `precision > 0`. This should never occur, but the error
///   is returned defensively.
///
/// ## Examples
/// ```gleam
/// let Ok(p) = non_negative_float.new(1234.567)
/// to_fixed_string(p, 2) // => Ok("1234.57")
///
/// to_fixed_string(p, 0) // => Ok("1235")
/// ```
///
/// ## Notes
/// - This function depends on JavaScript behavior. For example, `toFixed` performs rounding,
///   so `1234.567` with precision 2 becomes `"1234.57"` rather than being truncated.
pub fn to_fixed_string(
  p: NonNegativeFloat,
  precision: Int,
) -> Result(String, ToFixedStringError) {
  use <- bool.guard(precision < 0 || precision > 100, Error(InvalidPrecision))

  let raw_str = with_value(p, to_fixed(_, precision))

  case precision {
    0 -> Ok(raw_str)
    _ ->
      case string.split(raw_str, ".") {
        [int_part, frac_part] -> Ok(int_part <> "." <> frac_part)
        _ -> Error(UnexpectedFormat)
      }
  }
}

@external(javascript, "../number_ffi.mjs", "to_fixed")
fn to_fixed(f: Float, digits: Int) -> String
