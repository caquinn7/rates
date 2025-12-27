import gleam/dynamic/decode.{type Decoder}
import gleam/float
import gleam/function
import gleam/int
import gleam/json.{type Json}
import gleam/result

pub const max = PositiveFloat(1.7976931348623157e308)

/// A positive floating-point number.
///
/// The `PositiveFloat` type guarantees that the wrapped `Float` is
/// greater than `0.0`.
pub opaque type PositiveFloat {
  PositiveFloat(Float)
}

/// Creates a `PositiveFloat` from a `Float`,
/// returning an error if the value is less than or equal to `0.0`.
/// 
/// On the JavaScript runtime, also checks that the value is not `Infinity` or `NaN`.
pub fn new(f: Float) -> Result(PositiveFloat, Nil) {
  case is_finite(f) && f >. 0.0 {
    False -> Error(Nil)
    True -> Ok(PositiveFloat(f))
  }
}

/// Panics on invalid input!
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

/// Attempts to multiply two `PositiveFloat` values,
/// returning `Error(Nil)` if the result overflows.
pub fn multiply(
  a: PositiveFloat,
  b: PositiveFloat,
) -> Result(PositiveFloat, Nil) {
  use a <- with_value(a)
  use b <- with_value(b)
  result.map(safe_multiply(a, b), PositiveFloat)
}

/// Attempts to divide two `PositiveFloat` values,
/// returning `Error(Nil)` if the result overflows.
pub fn divide(
  a: PositiveFloat,
  by b: PositiveFloat,
) -> Result(PositiveFloat, Nil) {
  use a <- with_value(a)
  use b <- with_value(b)
  result.map(safe_divide(a, b), PositiveFloat)
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

/// Converts a `PositiveFloat` to its string representation
/// by calling float.to_string on the wrapped `Float` value.
pub fn to_string(n: PositiveFloat) -> String {
  with_value(n, float.to_string)
}

pub fn encode(p: PositiveFloat) -> Json {
  json.float(unwrap(p))
}

pub fn decoder() -> Decoder(PositiveFloat) {
  use raw <- decode.then(
    decode.one_of(decode.float, or: [decode.map(decode.int, int.to_float)]),
  )
  case new(raw) {
    Error(_) -> decode.failure(PositiveFloat(0.0), "PositiveFloat")
    Ok(p) -> decode.success(p)
  }
}

/// Checks if the given float is a finite number.
///
/// On the JavaScript runtime, uses `Number.isFinite` to detect `Infinity` and `NaN`.
/// On the Erlang runtime, always returns `True` since Erlang arithmetic errors are caught
/// via exceptions rather than special float values.
@external(javascript, "../number_ffi.mjs", "isFinite")
fn is_finite(_: Float) -> Bool {
  True
}

@external(erlang, "number_ffi", "safe_multiply")
fn safe_multiply(a: Float, b: Float) -> Result(Float, Nil) {
  let c = a *. b
  case is_finite(c) {
    False -> Error(Nil)
    True -> Ok(c)
  }
}

@external(erlang, "number_ffi", "safe_divide")
fn safe_divide(a: Float, b: Float) -> Result(Float, Nil) {
  let c = a /. b
  case is_finite(c) {
    False -> Error(Nil)
    True -> Ok(c)
  }
}
