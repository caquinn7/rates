import gleam/bool
import gleam/float
import gleam/function
import gleam/int
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

/// Parses a finite, non-negative number using dot-decimal Gleam float or integer syntax.
/// Leading signs are accepted; negative values are rejected and negative zero
/// is normalized to positive zero.
///
/// Scientific notation requires a complete float, such as `"1.0e-3"`.
/// Grouped numbers and incomplete decimals, such as `"1,000"`, `".5"`, and
/// `"123."`, are rejected.
pub fn parse(str: String) -> Result(NonNegativeFloat, Nil) {
  // Erlang also accepts decimal commas; require the same syntax on both runtimes.
  use <- bool.guard(string.contains(str, ","), Error(Nil))

  str
  |> float.parse
  |> result.lazy_or(fn() {
    str
    |> int.parse
    |> result.try(number_ops.safe_int_to_float)
  })
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
