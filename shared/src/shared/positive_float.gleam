import gleam/float
import gleam/function
import gleam/result

pub const max = PositiveFloat(1.7976931348623157e308)

pub opaque type PositiveFloat {
  PositiveFloat(Float)
}

/// Creates a `PositiveFloat` from a `Float`, returning an error if the value is negative.
///
/// Returns:
/// - `Ok(PositiveFloat)` if the float is greater than zero
/// - `Error(Nil)` if the float is negative
pub fn new(f: Float) -> Result(PositiveFloat, Nil) {
  case f >. 0.0 {
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

/// Returns `True` if the first `PositiveFloat` is strictly less than the second, otherwise `False`.
pub fn is_less_than(a: PositiveFloat, b: PositiveFloat) -> Bool {
  use a <- with_value(a)
  use b <- with_value(b)
  a <. b
}

/// Returns `True` if the first `PositiveFloat` is strictly greater than the second, otherwise `False`.
pub fn is_greater_than(a: PositiveFloat, b: PositiveFloat) -> Bool {
  use a <- with_value(a)
  use b <- with_value(b)
  a >. b
}
