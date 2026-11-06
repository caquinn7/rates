//// Runtime operations shared by the numeric types.
//// Callers retain responsibility for their type-specific invariant checks.

import gleam/int

/// Converts an integer using native rounding, rejecting non-finite results.
@external(erlang, "number_ffi", "safe_int_to_float")
pub fn safe_int_to_float(value: Int) -> Result(Float, Nil) {
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
@external(javascript, "./number_ffi.mjs", "isFinite")
pub fn is_finite(_: Float) -> Bool {
  True
}

/// Multiplies floats, allowing zero, including underflow to zero.
@external(erlang, "number_ffi", "safe_multiply")
pub fn safe_multiply(a: Float, b: Float) -> Result(Float, Nil) {
  let c = a *. b
  case is_finite(c) {
    True -> Ok(c)
    False -> Error(Nil)
  }
}

/// Divides floats, allowing underflow to zero. Callers must reject zero divisors.
@external(erlang, "number_ffi", "safe_divide")
pub fn safe_divide(a: Float, b: Float) -> Result(Float, Nil) {
  let c = a /. b
  case is_finite(c) {
    True -> Ok(c)
    False -> Error(Nil)
  }
}
