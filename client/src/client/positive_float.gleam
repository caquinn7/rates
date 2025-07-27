import gleam/bool
import gleam/float
import gleam/function
import gleam/int
import gleam/list
import gleam/result
import gleam/string

/// A non-negative floating-point number.
///
/// The `PositiveFloat` type guarantees that the wrapped `Float` is
/// greater than or equal to zero. Use the `new` or `parse` functions
/// to construct values of this type safely.
pub opaque type PositiveFloat {
  PositiveFloat(Float)
}

/// Creates a `PositiveFloat` from a `Float`, returning an error if the value is negative.
///
/// Returns:
/// - `Ok(PositiveFloat)` if the float is greater than or equal to zero
/// - `Error(Nil)` if the float is negative
pub fn new(f: Float) -> Result(PositiveFloat, Nil) {
  case f >=. 0.0 {
    False -> Error(Nil)
    True -> Ok(PositiveFloat(f))
  }
}

pub fn from_float_unsafe(x: Float) -> PositiveFloat {
  case new(x) {
    Error(_) -> panic as "Expected a positive value"
    Ok(p) -> p
  }
}

/// Parses a string into a `PositiveFloat`, validating formatting and positivity.
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
pub fn parse(str: String) -> Result(PositiveFloat, Nil) {
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

/// Applies a function to the inner float value of a `PositiveFloat` and returns the result.
///
/// This is useful for inspecting or transforming the float without unwrapping directly.
///
/// Example:
/// ```gleam
/// let str_value = with_value(p, float.to_string)
/// ```
pub fn with_value(p: PositiveFloat, fun: fn(Float) -> a) -> a {
  let PositiveFloat(value) = p
  fun(value)
}

pub fn unwrap(p: PositiveFloat) -> Float {
  with_value(p, function.identity)
}

/// Returns the largest possible `PositiveFloat` representable in JavaScript.
pub fn max() -> PositiveFloat {
  PositiveFloat(max_float())
}

/// Returns `True` if the inner value is exactly `0.0`, otherwise `False`.
pub fn is_zero(p: PositiveFloat) -> Bool {
  with_value(p, fn(f) { f == 0.0 })
}

pub fn multiply(a: PositiveFloat, b: PositiveFloat) -> PositiveFloat {
  use a <- with_value(a)
  use b <- with_value(b)
  PositiveFloat(a *. b)
}

/// Attempts to divide two `PositiveFloat` values, returning a `Result`.
///
/// If the division is successful, returns `Ok(PositiveFloat)` with the result.
/// If the operation fails (e.g., division by zero), returns `Error(Nil)`.
///
/// # Arguments
/// - `a`: The dividend as a `PositiveFloat`.
/// - `b`: The divisor as a `PositiveFloat`.
///
/// # Returns
/// - `Result(PositiveFloat, Nil)`: The result of the division or an error.
pub fn try_divide(
  a: PositiveFloat,
  b: PositiveFloat,
) -> Result(PositiveFloat, Nil) {
  use a <- with_value(a)
  use b <- with_value(b)
  result.map(float.divide(a, b), PositiveFloat)
}

pub type ToFixedStringError {
  InvalidPrecision
  UnexpectedFormat
}

/// Converts a `PositiveFloat` to a string with fixed decimal precision and
/// comma-separated digit grouping in the integer part.
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
/// let Ok(p) = positive_float.new(1234.567)
/// to_fixed_string(p, 2) // => Ok("1,234.57")
///
/// to_fixed_string(p, 0) // => Ok("1,235")
/// ```
///
/// ## Notes
/// - This function depends on JavaScript behavior. For example, `toFixed` performs rounding,
///   so `1234.567` with precision 2 becomes `"1234.57"` rather than being truncated.
pub fn to_fixed_string(
  p: PositiveFloat,
  precision: Int,
) -> Result(String, ToFixedStringError) {
  let precision_invalid = precision < 0 || precision > 100
  use <- bool.guard(precision_invalid, Error(InvalidPrecision))

  let raw_str = with_value(p, to_fixed(_, precision))

  case precision {
    0 -> Ok(group_digits_with_commas(raw_str))

    _ ->
      case string.split(raw_str, ".") {
        [int_part, frac_part] -> {
          let int_part = group_digits_with_commas(int_part)
          Ok(int_part <> "." <> frac_part)
        }

        _ -> Error(UnexpectedFormat)
      }
  }
}

fn group_digits_with_commas(int_str) {
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

@external(javascript, "../number_ffi.mjs", "max_number")
fn max_float() -> Float

@external(javascript, "../number_ffi.mjs", "to_fixed")
fn to_fixed(f: Float, digits: Int) -> String
