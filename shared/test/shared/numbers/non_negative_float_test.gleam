@target(erlang)
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import qcheck.{type Generator}
import shared/numbers/non_negative_float.{
  type NonNegativeFloat, InvalidPrecision,
}
import shared/numbers/positive_float.{type PositiveFloat}

// new

pub fn new_returns_error_if_less_than_zero_test() {
  assert non_negative_float.new(-1.0) == Error(Nil)
}

pub fn new_normalizes_negative_zero_test() {
  let assert Ok(zero) = non_negative_float.new(-0.0)
  let assert Ok(positive_zero) = non_negative_float.new(0.0)

  assert zero == positive_zero
  // Check the sign bit too, since JavaScript equality treats both zeros alike.
  assert <<non_negative_float.unwrap(zero):float>> == <<0.0:float>>
  assert non_negative_float.is_zero(zero)
}

@target(javascript)
pub fn new_returns_error_if_not_a_finite_number_test() {
  let infinity = non_negative_float.unwrap(non_negative_float.max) *. 2.0
  let nan = infinity /. infinity

  assert non_negative_float.new(infinity) == Error(Nil)
  assert non_negative_float.new(nan) == Error(Nil)
}

pub fn new_returns_ok_if_greater_than_or_equal_to_zero_test() {
  let assert Ok(_) = non_negative_float.new(0.0)
  let assert Ok(_) = non_negative_float.new(0.1)
  let assert Ok(_) = non_negative_float.new(1.0)
  let assert Ok(_) = non_negative_float.new(1000.0)
}

// parse

pub fn parse_accepts_basic_numbers_test() {
  let assert Ok(n1) = non_negative_float.parse("123")
  assert non_negative_float.unwrap(n1) == 123.0

  let assert Ok(n2) = non_negative_float.parse("123.45")
  assert non_negative_float.unwrap(n2) == 123.45

  let assert Ok(n3) = non_negative_float.parse("0")
  assert non_negative_float.unwrap(n3) == 0.0
}

pub fn parse_accepts_edge_case_formats_test() {
  let assert Ok(n1) = non_negative_float.parse(".5")
  assert non_negative_float.unwrap(n1) == 0.5

  let assert Ok(n2) = non_negative_float.parse("123.")
  assert non_negative_float.unwrap(n2) == 123.0

  let assert Ok(n3) = non_negative_float.parse("0.0")
  assert non_negative_float.unwrap(n3) == 0.0
}

pub fn parse_accepts_comma_separated_input_test() {
  let assert Ok(n1) = non_negative_float.parse("1,000")
  assert non_negative_float.unwrap(n1) == 1000.0

  let assert Ok(n2) = non_negative_float.parse("1,234.56")
  assert non_negative_float.unwrap(n2) == 1234.56
}

pub fn parse_accepts_scientific_notation_test() {
  let assert Ok(n) = non_negative_float.parse("1.0e10")
  assert non_negative_float.unwrap(n) == 10_000_000_000.0
}

pub fn parse_rejects_invalid_input_test() {
  let assert Error(_) = non_negative_float.parse("abc")
  let assert Error(_) = non_negative_float.parse("")
  let assert Error(_) = non_negative_float.parse(" ")
  let assert Error(_) = non_negative_float.parse("12.3.4")
  let assert Error(_) = non_negative_float.parse("1,2,3")
  let assert Error(_) = non_negative_float.parse(".")
  let assert Error(_) = non_negative_float.parse(",")
  let assert Error(_) = non_negative_float.parse("1,")
  let assert Error(_) = non_negative_float.parse(",,1")
  let assert Error(_) = non_negative_float.parse("1e10")
}

pub fn parse_rejects_negative_numbers_test() {
  let assert Error(_) = non_negative_float.parse("-1")
  let assert Error(_) = non_negative_float.parse("-0.01")
  let assert Error(_) = non_negative_float.parse("-1,234.56")
}

pub fn parse_rejects_multiple_decimal_points_before_normalizing_test() {
  ["1.2.", "1..", "..", "1.0e2."]
  |> list.each(fn(input) {
    assert non_negative_float.parse(input) == Error(Nil)
  })
}

pub fn parse_rejects_malformed_comma_groups_test() {
  [
    ",123", "+,123", "-,123", "1,", "1,,234", "1234,567", "12,34", "1,234.5,6",
    "1.2,345", "1,a23",
  ]
  |> list.each(fn(input) {
    assert non_negative_float.parse(input) == Error(Nil)
  })
}

pub fn parse_accepts_signed_and_grouped_numbers_test() {
  [
    #("+1", 1.0),
    #("+123,456", 123_456.0),
    #("+1,234.56", 1234.56),
    #("1,234,567", 1_234_567.0),
    #("-0", 0.0),
    #("-0.0", 0.0),
    #("-0,000", 0.0),
  ]
  |> list.each(fn(pair) {
    let #(input, expected) = pair
    let assert Ok(value) = non_negative_float.parse(input)
    let actual = non_negative_float.unwrap(value)
    assert actual == expected
  })
}

pub fn parse_returns_error_for_oversized_integers_test() {
  let oversized = "1" <> string.repeat("0", 309)
  assert non_negative_float.parse(oversized) == Error(Nil)
  assert non_negative_float.parse("-" <> oversized) == Error(Nil)
}

pub fn parse_accepts_large_in_range_integer_test() {
  let large = "1" <> string.repeat("0", 308)
  let assert Ok(value) = non_negative_float.parse(large)
  assert non_negative_float.unwrap(value) == 1.0e308
}

@target(erlang)
pub fn parse_preserves_native_integer_rounding_near_max_test() {
  let max = non_negative_float.unwrap(non_negative_float.max)
  let input = int.to_string(float.truncate(max) + 1)
  let assert Ok(value) = non_negative_float.parse(input)
  assert non_negative_float.unwrap(value) == max
}

// with_value

pub fn with_value_applies_function_to_inner_value_test() {
  let n = non_negative_float.from_float_unsafe(1.0)
  assert non_negative_float.with_value(n, fn(f) { f *. 2.0 }) == 2.0
}

// is_zero

pub fn is_zero_returns_true_if_inner_value_is_zero_test() {
  let n = non_negative_float.from_float_unsafe(0.0)
  assert non_negative_float.is_zero(n)
}

pub fn is_zero_returns_false_if_inner_value_is_not_zero_test() {
  qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.1),
    ),
    fn(n) {
      assert !non_negative_float.is_zero(n)
    },
  )
}

pub fn is_zero_returns_false_for_known_small_value_test() {
  let n = non_negative_float.from_float_unsafe(0.0000000001)
  assert !non_negative_float.is_zero(n)
}

// multiply

pub fn multiply_by_one_returns_self_test() {
  qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.0),
    ),
    fn(n) {
      let one = non_negative_float.from_float_unsafe(1.0)
      assert non_negative_float.multiply(n, one) == Ok(n)
    },
  )
}

pub fn multiply_by_zero_returns_zero_test() {
  qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.0),
    ),
    fn(n) {
      let zero = non_negative_float.from_float_unsafe(0.0)
      assert non_negative_float.multiply(n, zero) == Ok(zero)
    },
  )
}

pub fn multiply_test() {
  // bound by sqrt of max float, safe for multiplication
  let float_generator = qcheck.bounded_float(0.1, 1.0e154)

  use a <- qcheck.given(qcheck.map(
    float_generator,
    non_negative_float.from_float_unsafe,
  ))
  use b <- qcheck.given(qcheck.map(
    float_generator,
    non_negative_float.from_float_unsafe,
  ))

  let assert Ok(result) = non_negative_float.multiply(a, b)

  let a = non_negative_float.unwrap(a)
  let b = non_negative_float.unwrap(b)

  assert non_negative_float.unwrap(result) == a *. b
}

pub fn multiply_by_positive_test() {
  // bound by sqrt of max float, safe for multiplication
  let float_generator = qcheck.bounded_float(0.1, 1.0e154)

  use a <- qcheck.given(qcheck.map(
    float_generator,
    non_negative_float.from_float_unsafe,
  ))
  use b <- qcheck.given(qcheck.map(
    float_generator,
    positive_float.from_float_unsafe,
  ))

  let assert Ok(result) = non_negative_float.multiply_by_positive(a, b)

  let a = non_negative_float.unwrap(a)
  let b = positive_float.unwrap(b)

  assert non_negative_float.unwrap(result) == a *. b
}

// divide

pub fn divide_by_zero_returns_error_test() {
  let n1 = non_negative_float.from_float_unsafe(1.0)
  let n2 = non_negative_float.from_float_unsafe(0.0)
  assert non_negative_float.divide(n1, n2) == Error(Nil)
}

pub fn divide_by_negative_zero_returns_error_test() {
  let one = non_negative_float.from_float_unsafe(1.0)
  let negative_zero = non_negative_float.from_float_unsafe(-0.0)
  assert non_negative_float.divide(one, negative_zero) == Error(Nil)
}

pub fn divide_zero_by_zero_returns_error_test() {
  let zero = non_negative_float.from_float_unsafe(0.0)
  assert non_negative_float.divide(zero, zero) == Error(Nil)
}

pub fn divide_returns_error_on_overflow_test() {
  let large = non_negative_float.from_float_unsafe(1.0e308)
  let small = non_negative_float.from_float_unsafe(1.0e-308)
  assert non_negative_float.divide(large, small) == Error(Nil)
}

pub fn divide_allows_underflow_to_zero_test() {
  let small = non_negative_float.from_float_unsafe(1.0e-300)
  let large = non_negative_float.from_float_unsafe(1.0e300)
  let zero = non_negative_float.from_float_unsafe(0.0)
  assert non_negative_float.divide(small, large) == Ok(zero)
}

pub fn divide_zero_by_any_is_zero_test() {
  qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.1),
    ),
    fn(n) {
      let zero = non_negative_float.from_float_unsafe(0.0)
      let assert Ok(result) = non_negative_float.divide(zero, n)
      assert non_negative_float.is_zero(result)
    },
  )
}

pub fn divide_by_one_returns_self_test() {
  qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.0),
    ),
    fn(n) {
      let one = non_negative_float.from_float_unsafe(1.0)
      assert non_negative_float.divide(n, one) == Ok(n)
    },
  )
}

pub fn divide_test() {
  // Keep values moderate - even 1e100 / 0.1 = 1e101 is well within bounds
  let float_generator = qcheck.bounded_float(0.1, 1.0e100)

  use a <- qcheck.given(qcheck.map(
    float_generator,
    non_negative_float.from_float_unsafe,
  ))

  use b <- qcheck.given(qcheck.map(
    float_generator,
    non_negative_float.from_float_unsafe,
  ))

  let assert Ok(result) = non_negative_float.divide(a, b)

  let a = non_negative_float.unwrap(a)
  let b = non_negative_float.unwrap(b)

  assert non_negative_float.unwrap(result) == a /. b
}

// divide_by_positive

pub fn divide_by_positive_test() {
  let bounded_float = qcheck.bounded_float(0.1, 1.0e100)

  use a <- qcheck.given(qcheck.map(
    bounded_float,
    non_negative_float.from_float_unsafe,
  ))

  use b <- qcheck.given(qcheck.map(
    bounded_float,
    positive_float.from_float_unsafe,
  ))

  let assert Ok(result) = non_negative_float.divide_by_positive(a, b)

  let a = non_negative_float.unwrap(a)
  let b = positive_float.unwrap(b)

  assert non_negative_float.unwrap(result) == a /. b
}

// is_less_than

pub fn is_less_than_returns_true_when_first_value_is_less_than_second_test() {
  let a = non_negative_float.from_float_unsafe(0.01)
  let b = non_negative_float.from_float_unsafe(0.02)

  assert non_negative_float.is_less_than(a, b)
}

pub fn is_less_than_returns_false_when_first_value_is_equal_to_second_test() {
  let a = non_negative_float.from_float_unsafe(0.01)
  assert !non_negative_float.is_less_than(a, a)
}

pub fn is_less_than_returns_false_when_first_value_is_less_than_second_test() {
  let a = non_negative_float.from_float_unsafe(0.01)
  let b = non_negative_float.from_float_unsafe(0.02)

  assert !non_negative_float.is_less_than(b, a)
}

// is_greater_than

pub fn is_greater_than_returns_true_when_first_value_is_greater_than_second_test() {
  let a = non_negative_float.from_float_unsafe(0.02)
  let b = non_negative_float.from_float_unsafe(0.01)

  assert non_negative_float.is_greater_than(a, b)
}

pub fn is_greater_than_returns_false_when_first_value_is_equal_to_second_test() {
  let a = non_negative_float.from_float_unsafe(0.01)
  assert !non_negative_float.is_greater_than(a, a)
}

pub fn is_greater_than_returns_false_when_first_value_is_less_than_second_test() {
  let a = non_negative_float.from_float_unsafe(0.01)
  let b = non_negative_float.from_float_unsafe(0.02)

  assert !non_negative_float.is_greater_than(a, b)
}

// to_fixed_string

pub fn to_fixed_string_formats_correctly_test() {
  let n = non_negative_float.from_float_unsafe(1234.5678)
  let assert Ok("1234.57") = non_negative_float.to_fixed_string(n, 2)

  let assert Ok("1234.568") = non_negative_float.to_fixed_string(n, 3)
  let assert Ok("1234.567800") = non_negative_float.to_fixed_string(n, 6)
}

pub fn to_fixed_string_precision_zero_test() {
  let n1 = non_negative_float.from_float_unsafe(1234.5678)
  let assert Ok("1235") = non_negative_float.to_fixed_string(n1, 0)

  let n2 = non_negative_float.from_float_unsafe(0.0)
  let assert Ok("0") = non_negative_float.to_fixed_string(n2, 0)
}

pub fn to_fixed_string_invalid_precision_test() {
  let n = non_negative_float.from_float_unsafe(123.45)

  let assert Error(InvalidPrecision) = non_negative_float.to_fixed_string(n, -1)
  let assert Error(InvalidPrecision) =
    non_negative_float.to_fixed_string(n, 101)
}

pub fn to_fixed_string_handles_large_values_at_all_supported_precisions_test() {
  // These fixtures contain the exact integer represented by each binary float.
  [
    #(9.999999999999999e20, "999999999999999868928"),
    #(1.0e21, "1000000000000000000000"),
    #(1.0000000000000001e21, "1000000000000000131072"),
    #(
      1.0e200,
      "99999999999999996973312221251036165947450327545502362648241750950346848435554075534196338404706251868027512415973882408182135734368278484639385041047239877871023591066789981811181813306167128854888448",
    ),
    #(
      1.7976931348623157e308,
      "179769313486231570814527423731704356798070567525844996598917476803157260780028538760589558632766878171540458953514382464234321326889464182768467546703537516986049910576551282076245490090389328944075868508455133942304583236903222948165808559332123348274797826204144723168738177180919299881250404026184124858368",
    ),
  ]
  |> list.each(fn(pair) {
    let #(raw, whole) = pair
    let value = non_negative_float.from_float_unsafe(raw)

    int.range(0, 101, Nil, fn(_, precision) {
      let expected = case precision {
        0 -> whole
        _ -> whole <> "." <> string.repeat("0", precision)
      }
      assert non_negative_float.to_fixed_string(value, precision)
        == Ok(expected)
    })
  })
}

pub fn to_fixed_string_formats_zero_and_tiny_values_at_max_precision_test() {
  let zero = non_negative_float.from_float_unsafe(0.0)
  let tiny = non_negative_float.from_float_unsafe(1.0e-310)
  let expected = "0." <> string.repeat("0", 100)
  assert non_negative_float.to_fixed_string(zero, 100) == Ok(expected)
  assert non_negative_float.to_fixed_string(tiny, 100) == Ok(expected)
}

// generators

pub fn max_bounded_positive_float_generator(
  min: PositiveFloat,
) -> Generator(PositiveFloat) {
  let max_float = positive_float.unwrap(positive_float.max)
  let min_float = positive_float.unwrap(min)

  min_float
  |> qcheck.bounded_float(max_float)
  |> qcheck.map(positive_float.from_float_unsafe)
}

fn max_bounded_non_negative_float_generator(
  min: NonNegativeFloat,
) -> Generator(NonNegativeFloat) {
  let max_float = non_negative_float.unwrap(non_negative_float.max)
  let min_float = non_negative_float.unwrap(min)

  min_float
  |> qcheck.bounded_float(max_float)
  |> qcheck.map(non_negative_float.from_float_unsafe)
}
