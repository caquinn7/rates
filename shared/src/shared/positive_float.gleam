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
/// finite and greater than `0.0`.
pub opaque type PositiveFloat {
  PositiveFloat(Float)
}

/// Creates a `PositiveFloat` from a `Float`,
/// returning an error if the value is less than or equal to `0.0`.
/// 
/// On the JavaScript runtime, also checks that the value is not `Infinity` or `NaN`.
pub fn new(f: Float) -> Result(PositiveFloat, Nil) {
  case is_finite(f) && f >. 0.0 {
    True -> Ok(PositiveFloat(f))
    False -> Error(Nil)
  }
}

/// Panics on invalid input!
pub fn from_float_unsafe(x: Float) -> PositiveFloat {
  case new(x) {
    Ok(p) -> p
    Error(_) -> panic as "Expected a positive, finite value"
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
pub fn with_value(p: PositiveFloat, f: fn(Float) -> a) -> a {
  let PositiveFloat(value) = p
  f(value)
}

pub fn unwrap(p: PositiveFloat) -> Float {
  with_value(p, function.identity)
}

/// Attempts to multiply two `PositiveFloat` values,
/// returning `Error(Nil)` if the result overflows or underflows to zero.
pub fn multiply(
  a: PositiveFloat,
  b: PositiveFloat,
) -> Result(PositiveFloat, Nil) {
  use a <- with_value(a)
  use b <- with_value(b)
  result.try(safe_multiply(a, b), new)
}

/// Attempts to divide two `PositiveFloat` values,
/// returning `Error(Nil)` if the result overflows or underflows to zero.
pub fn divide(
  a: PositiveFloat,
  by b: PositiveFloat,
) -> Result(PositiveFloat, Nil) {
  use a <- with_value(a)
  use b <- with_value(b)
  result.try(safe_divide(a, b), new)
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
/// by calling `float.to_string` on the wrapped `Float` value.
pub fn to_string(n: PositiveFloat) -> String {
  with_value(n, float.to_string)
}

pub fn encode(p: PositiveFloat) -> Json {
  json.float(unwrap(p))
}

/// Decodes a positive, finite number from an `Int` or `Float`.
///
/// Integers are converted to floats and may be rounded.
/// Fails for zero, negative or non-finite values, integers too large to convert
/// to a finite float, and non-numeric inputs.
pub fn decoder() -> Decoder(PositiveFloat) {
  let int_decoder = {
    use raw <- decode.then(decode.int)
    case safe_int_to_float(raw) {
      Ok(value) -> decode.success(value)
      Error(_) -> decode.failure(1.0, "Float")
    }
  }
  use raw <- decode.then(decode.one_of(decode.float, or: [int_decoder]))
  case new(raw) {
    Ok(p) -> decode.success(p)
    // Downstream callbacks may receive this placeholder while errors are
    // collected, so it must uphold the PositiveFloat invariant.
    Error(_) -> decode.failure(PositiveFloat(1.0), "PositiveFloat")
  }
}

@external(erlang, "number_ffi", "safe_int_to_float")
fn safe_int_to_float(value: Int) -> Result(Float, Nil) {
  let value = int.to_float(value)
  case is_finite(value) {
    True -> Ok(value)
    False -> Error(Nil)
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
    True -> Ok(c)
    False -> Error(Nil)
  }
}

@external(erlang, "number_ffi", "safe_divide")
fn safe_divide(a: Float, b: Float) -> Result(Float, Nil) {
  let c = a /. b
  case is_finite(c) {
    True -> Ok(c)
    False -> Error(Nil)
  }
}
