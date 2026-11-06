import gleam/bool
import gleam/float
import gleam/function
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import shared/internal/numbers as number_ops
import shared/numbers/positive_float.{type PositiveFloat}

pub const max = NonNegativeFloat(1.7976931348623157e308)

/// A non-negative floating-point number.
///
/// The `NonNegativeFloat` type guarantees that the wrapped `Float` is
/// finite and greater than or equal to `0.0`.
pub opaque type NonNegativeFloat {
  NonNegativeFloat(Float)
}

/// Creates a `NonNegativeFloat` from a `Float`,
/// returning an error if the value is less than `0.0`.
/// Negative zero is normalized to positive zero.
/// 
/// On the JavaScript runtime, also checks that the value is not `Infinity` or `NaN`.
pub fn new(f: Float) -> Result(NonNegativeFloat, Nil) {
  case number_ops.is_finite(f) && f >=. 0.0 {
    False -> Error(Nil)
    True if f <=. 0.0 -> Ok(NonNegativeFloat(0.0))
    True -> Ok(NonNegativeFloat(f))
  }
}

/// Panics on invalid input!
pub fn from_float_unsafe(f: Float) -> NonNegativeFloat {
  case new(f) {
    Error(_) -> panic as "Expected a non-negative, finite value"
    Ok(n) -> n
  }
}

/// Parses a string into a `NonNegativeFloat`, validating formatting and non-negativity.
///
/// Accepts:
/// - Optional commas in the integer portion (e.g., `"1,000.25"`)
/// - Leading decimal points (e.g., `".5"` becomes `"0.5"`)
/// - Trailing decimal points (e.g., `"1."` becomes `"1.0"`)
/// - Scientific notation (e.g., `"1.0e10"`)
///
/// Rejects:
/// - Invalid comma grouping (e.g., `"1,2,3"`)
/// - Multiple decimal points or commas outside the integer portion
/// - Negative values or non-numeric input
pub fn parse(str: String) -> Result(NonNegativeFloat, Nil) {
  // Validate the original decimal structure before normalizing either end.
  use #(int_part, frac_part) <- result.try(case string.split(str, ".") {
    [i] -> Ok(#(i, ""))
    ["", ""] -> Error(Nil)
    ["", f] -> Ok(#("0", f))
    [i, f] -> Ok(#(i, f))
    _ -> Error(Nil)
  })
  use <- bool.guard(string.contains(frac_part, ","), Error(Nil))
  use <- bool.guard(
    string.contains(str, ",") && !is_valid_comma_grouping(int_part),
    Error(Nil),
  )

  int_part
  |> string.replace(",", "")
  |> string.append(case frac_part == "" {
    True -> ""
    False -> "." <> frac_part
  })
  |> parse_float
  |> result.try(new)
}

fn parse_float(str: String) -> Result(Float, Nil) {
  str
  |> float.parse
  |> result.lazy_or(fn() {
    str
    |> int.parse
    |> result.try(number_ops.safe_int_to_float)
  })
}

fn is_valid_comma_grouping(int_str: String) -> Bool {
  let assert [head, ..tail] = string.split(int_str, ",")
  let head = case head {
    "+" <> digits | "-" <> digits -> digits
    _ -> head
  }

  is_digits(head)
  && string.length(head) <= 3
  && list.all(tail, fn(chunk) { string.length(chunk) == 3 && is_digits(chunk) })
}

fn is_digits(str: String) -> Bool {
  str != ""
  && list.all(string.to_graphemes(str), string.contains("0123456789", _))
}

/// Applies a function to the inner float value of a `NonNegativeFloat` and returns the result.
///
/// This is useful for inspecting or transforming the float without unwrapping directly.
///
/// Example:
/// ```gleam
/// let str_value = with_value(p, float.to_string)
/// ```
pub fn with_value(n: NonNegativeFloat, fun: fn(Float) -> a) -> a {
  let NonNegativeFloat(value) = n
  fun(value)
}

pub fn unwrap(n: NonNegativeFloat) -> Float {
  with_value(n, function.identity)
}

/// Returns `True` if the inner value is exactly `0.0`, otherwise `False`.
pub fn is_zero(n: NonNegativeFloat) -> Bool {
  with_value(n, fn(f) { f == 0.0 })
}

/// Attempts to multiply two `NonNegativeFloat` values,
/// returning `Error(Nil)` if the result overflows.
pub fn multiply(
  a: NonNegativeFloat,
  b: NonNegativeFloat,
) -> Result(NonNegativeFloat, Nil) {
  use a <- with_value(a)
  use b <- with_value(b)
  result.map(number_ops.safe_multiply(a, b), NonNegativeFloat)
}

/// Attempts to multiply a `NonNegativeFloat` by a `PositiveFloat`,
/// returning `Error(Nil)` if the result overflows.
pub fn multiply_by_positive(
  a: NonNegativeFloat,
  b: PositiveFloat,
) -> Result(NonNegativeFloat, Nil) {
  use a <- with_value(a)
  use b <- positive_float.with_value(b)
  result.map(number_ops.safe_multiply(a, b), NonNegativeFloat)
}

/// Attempts to divide two `NonNegativeFloat` values,
/// returning `Error(Nil)` if the operation fails (e.g., division by zero, overflow).
pub fn divide(
  a: NonNegativeFloat,
  b: NonNegativeFloat,
) -> Result(NonNegativeFloat, Nil) {
  use a <- with_value(a)
  use b <- with_value(b)
  use <- bool.guard(b == 0.0, Error(Nil))
  result.try(number_ops.safe_divide(a, b), new)
}

/// Attempts to divide a `NonNegativeFloat` by a `PositiveFloat`,
/// returning `Error(Nil)` if the result overflows.
pub fn divide_by_positive(
  a: NonNegativeFloat,
  by b: PositiveFloat,
) -> Result(NonNegativeFloat, Nil) {
  use a <- with_value(a)
  use b <- positive_float.with_value(b)
  result.map(number_ops.safe_divide(a, b), NonNegativeFloat)
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

/// Converts a `NonNegativeFloat` to its string representation
/// by calling `float.to_string` on the wrapped `Float` value.
/// 
/// For precise decimal formatting, consider using `non_negative_float.to_fixed_string` instead.
pub fn to_string(n: NonNegativeFloat) -> String {
  with_value(n, float.to_string)
}

pub type ToFixedStringError {
  InvalidPrecision
}

/// Converts a `NonNegativeFloat` to a string with fixed decimal precision.
///
/// The number is rounded and formatted with exactly `precision`
/// digits after the decimal point. When `precision` is `0`, the decimal point is
/// omitted entirely.
///
/// Supports every finite `NonNegativeFloat` without using exponential notation.
///
/// This function is intended for **display formatting of approximate values**
/// (such as exchange rates or converted amounts), not for representing stored
/// monetary balances.
///
/// Returns `Error(InvalidPrecision)` if `precision` is less than 0 or greater than 100.
///
/// ### Examples
/// ```gleam
/// let Ok(n) = non_negative_float.new(1234.567)
/// to_fixed_string(n, 2) // => Ok("1234.57")
/// to_fixed_string(n, 0) // => Ok("1235")
/// ```
///
/// ### Notes
/// - The underlying formatters perform rounding rather than truncation.
/// - Because this function operates on binary floating-point values, results may
///   reflect floating-point representation effects (for example, `1.005` may
///   format as `"1.00"` when using precision 2).
pub fn to_fixed_string(
  n: NonNegativeFloat,
  precision: Int,
) -> Result(String, ToFixedStringError) {
  use <- bool.guard(precision < 0 || precision > 100, Error(InvalidPrecision))
  Ok(with_value(n, to_fixed(_, precision)))
}

@external(erlang, "number_ffi", "to_fixed")
@external(javascript, "../internal/number_ffi.mjs", "toFixed")
fn to_fixed(f: Float, digits: Int) -> String
