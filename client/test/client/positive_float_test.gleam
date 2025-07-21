import client/positive_float
import gleam/function
import qcheck

// new

pub fn new_returns_error_if_less_than_zero_test() {
  assert Error(Nil) == positive_float.new(-1.0)
}

pub fn new_returns_ok_if_equal_to_zero_test() {
  let assert Ok(_) = positive_float.new(0.0)
}

pub fn new_returns_ok_if_equal_to_negative_zero_test() {
  let assert Ok(_) = positive_float.new(-0.0)
}

pub fn new_returns_ok_if_greater_than_or_equal_to_zero_test() {
  qcheck.given(max_bounded_raw_float(0.0), fn(f) {
    let assert Ok(_) = positive_float.new(f)
    Nil
  })
}

// parse

pub fn parse_accepts_basic_numbers_test() {
  let assert Ok(p1) = positive_float.parse("123")
  assert 123.0 == positive_float.with_value(p1, function.identity)

  let assert Ok(p2) = positive_float.parse("123.45")
  assert 123.45 == positive_float.with_value(p2, function.identity)

  let assert Ok(p3) = positive_float.parse("0")
  assert 0.0 == positive_float.with_value(p3, function.identity)
}

pub fn parse_accepts_edge_case_formats_test() {
  let assert Ok(p1) = positive_float.parse(".5")
  assert 0.5 == positive_float.with_value(p1, function.identity)

  let assert Ok(p2) = positive_float.parse("123.")
  assert 123.0 == positive_float.with_value(p2, function.identity)

  let assert Ok(p3) = positive_float.parse("0.0")
  assert 0.0 == positive_float.with_value(p3, function.identity)
}

pub fn parse_accepts_comma_separated_input_test() {
  let assert Ok(p1) = positive_float.parse("1,000")
  assert 1000.0 == positive_float.with_value(p1, function.identity)

  let assert Ok(p2) = positive_float.parse("1,234.56")
  assert 1234.56 == positive_float.with_value(p2, function.identity)
}

pub fn parse_rejects_invalid_input_test() {
  let assert Error(_) = positive_float.parse("abc")
  let assert Error(_) = positive_float.parse("")
  let assert Error(_) = positive_float.parse(" ")
  let assert Error(_) = positive_float.parse("12.3.4")
  let assert Error(_) = positive_float.parse("1,2,3")
  let assert Error(_) = positive_float.parse(".")
  let assert Error(_) = positive_float.parse(",")
  let assert Error(_) = positive_float.parse("1,")
  let assert Error(_) = positive_float.parse(",,1")
  let assert Error(_) = positive_float.parse("1e10")
}

pub fn parse_rejects_negative_numbers_test() {
  let assert Error(_) = positive_float.parse("-1")
  let assert Error(_) = positive_float.parse("-0.01")
  let assert Error(_) = positive_float.parse("-1,234.56")
}

// with_value

pub fn with_value_applies_function_to_inner_value_test() {
  let assert Ok(p) = positive_float.new(1.0)
  assert 2.0 == positive_float.with_value(p, fn(f) { f *. 2.0 })
}

// is_zero

pub fn is_zero_returns_true_if_inner_value_is_zero_test() {
  let assert Ok(p) = positive_float.new(0.0)
  assert positive_float.is_zero(p)
}

pub fn is_zero_returns_false_if_inner_value_is_not_zero_test() {
  qcheck.given(max_bounded_positive_float(0.1), fn(p) {
    assert !positive_float.is_zero(p)
  })
}

pub fn is_zero_returns_false_for_known_small_value_test() {
  let assert Ok(p) = positive_float.new(0.0000000001)
  assert !positive_float.is_zero(p)
}

// to_display_string

pub fn formats_integer_with_commas_test() {
  let assert Ok(p) = positive_float.new(1_234_567.0)
  assert "1,234,567.0" == positive_float.to_display_string(p)
}

pub fn retains_fractional_part_test() {
  let assert Ok(p) = positive_float.new(1234.567)
  assert "1,234.567" == positive_float.to_display_string(p)
}

pub fn formats_zero_correctly_test() {
  let assert Ok(p) = positive_float.new(0.0)
  assert "0.0" == positive_float.to_display_string(p)
}

pub fn formats_small_fraction_test() {
  let assert Ok(p) = positive_float.new(0.001)
  assert "0.001" == positive_float.to_display_string(p)
}

pub fn no_commas_for_short_int_test() {
  let assert Ok(p) = positive_float.new(123.45)
  assert "123.45" == positive_float.to_display_string(p)
}

pub fn formats_large_number_test() {
  let assert Ok(p) = positive_float.new(1_234_567_890_123.0)
  assert "1,234,567,890,123.0" == positive_float.to_display_string(p)
}

pub fn preserves_trailing_zeros_test() {
  let assert Ok(p) = positive_float.new(1000.05)
  assert "1,000.05" == positive_float.to_display_string(p)
}

// generators

fn max_bounded_raw_float(min) {
  let max_float =
    positive_float.max()
    |> positive_float.with_value(function.identity)

  qcheck.bounded_float(min, max_float)
}

fn positive_float(raw_float_generator) {
  raw_float_generator
  |> qcheck.map(fn(f) {
    let assert Ok(p) = positive_float.new(f)
    p
  })
}

fn max_bounded_positive_float(min) {
  min
  |> max_bounded_raw_float
  |> positive_float
}
