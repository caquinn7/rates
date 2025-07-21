import gleam/bool
import gleam/float
import gleam/int
import gleam/list
import gleam/pair
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

  use <- bool.guard(!is_valid_comma_grouping(int_part), Error(Nil))

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

/// Returns the largest possible `PositiveFloat` representable in JavaScript.
pub fn max() -> PositiveFloat {
  PositiveFloat(max_float())
}

/// Returns `True` if the inner value is exactly `0.0`, otherwise `False`.
pub fn is_zero(p: PositiveFloat) -> Bool {
  with_value(p, fn(f) { f == 0.0 })
}

/// Converts a `PositiveFloat` to a human-friendly string with comma separators.
///
/// Example:
/// ```gleam
/// to_display_string(PositiveFloat(1234567.89)) == "1,234,567.89"
/// ```
pub fn to_display_string(amount: PositiveFloat) -> String {
  let split_decimal_string = fn(amount) {
    let assert [int_str, frac_str] =
      amount
      |> with_value(float.to_string)
      |> string.split(".")

    #(int_str, frac_str)
  }

  let group_digits_with_commas = fn(int_str) {
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

  let rebuild_string = fn(string_parts) {
    let #(int_str, frac_str) = string_parts
    int_str <> "." <> frac_str
  }

  amount
  |> split_decimal_string
  |> pair.map_first(group_digits_with_commas)
  |> rebuild_string
}

@external(javascript, "../number_ffi.mjs", "max_number")
fn max_float() -> Float
