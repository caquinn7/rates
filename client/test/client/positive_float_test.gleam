import client/positive_float.{InvalidPrecision}
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
  assert 123.0 == positive_float.unwrap(p1)

  let assert Ok(p2) = positive_float.parse("123.45")
  assert 123.45 == positive_float.unwrap(p2)

  let assert Ok(p3) = positive_float.parse("0")
  assert 0.0 == positive_float.unwrap(p3)
}

pub fn parse_accepts_edge_case_formats_test() {
  let assert Ok(p1) = positive_float.parse(".5")
  assert 0.5 == positive_float.unwrap(p1)

  let assert Ok(p2) = positive_float.parse("123.")
  assert 123.0 == positive_float.unwrap(p2)

  let assert Ok(p3) = positive_float.parse("0.0")
  assert 0.0 == positive_float.unwrap(p3)
}

pub fn parse_accepts_comma_separated_input_test() {
  let assert Ok(p1) = positive_float.parse("1,000")
  assert 1000.0 == positive_float.unwrap(p1)

  let assert Ok(p2) = positive_float.parse("1,234.56")
  assert 1234.56 == positive_float.unwrap(p2)
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
  let p = positive_float.from_float_unsafe(1.0)
  assert 2.0 == positive_float.with_value(p, fn(f) { f *. 2.0 })
}

// is_zero

pub fn is_zero_returns_true_if_inner_value_is_zero_test() {
  let p = positive_float.from_float_unsafe(0.0)
  assert positive_float.is_zero(p)
}

pub fn is_zero_returns_false_if_inner_value_is_not_zero_test() {
  qcheck.given(max_bounded_positive_float(0.1), fn(p) {
    assert !positive_float.is_zero(p)
  })
}

pub fn is_zero_returns_false_for_known_small_value_test() {
  let p = positive_float.from_float_unsafe(0.0000000001)
  assert !positive_float.is_zero(p)
}

// multiply

pub fn multiply_by_one_returns_self_test() {
  qcheck.given(max_bounded_positive_float(0.0), fn(p) {
    let one = positive_float.from_float_unsafe(1.0)
    assert p == positive_float.multiply(p, one)
  })
}

pub fn multiply_by_zero_returns_zero_test() {
  qcheck.given(max_bounded_positive_float(0.0), fn(p) {
    let zero = positive_float.from_float_unsafe(0.0)
    assert zero == positive_float.multiply(p, zero)
  })
}

pub fn multiply_test() {
  use a <- qcheck.given(max_bounded_positive_float(0.0))
  use b <- qcheck.given(max_bounded_positive_float(0.0))
  let result = positive_float.multiply(a, b)

  let a_val = positive_float.unwrap(a)
  let b_val = positive_float.unwrap(b)
  let result_val = positive_float.unwrap(result)

  assert a_val *. b_val == result_val
}

// try_divide

pub fn try_divide_by_zero_returns_error_test() {
  let p1 = positive_float.from_float_unsafe(1.0)
  let p2 = positive_float.from_float_unsafe(0.0)
  assert Error(Nil) == positive_float.try_divide(p1, p2)
}

pub fn try_divide_zero_by_any_is_zero_test() {
  qcheck.given(max_bounded_positive_float(0.1), fn(p) {
    let zero = positive_float.from_float_unsafe(0.0)
    let assert Ok(result) = positive_float.try_divide(zero, p)
    assert 0.0 == positive_float.unwrap(result)
  })
}

pub fn try_divide_by_one_returns_self_test() {
  qcheck.given(max_bounded_positive_float(0.0), fn(p) {
    let one = positive_float.from_float_unsafe(1.0)
    let assert Ok(result) = positive_float.try_divide(p, one)
    assert p == result
  })
}

pub fn try_divide_test() {
  use a <- qcheck.given(max_bounded_positive_float(0.0))
  use b <- qcheck.given(max_bounded_positive_float(0.1))
  let assert Ok(result) = positive_float.try_divide(a, b)

  let a_val = positive_float.unwrap(a)
  let b_val = positive_float.unwrap(b)

  assert a_val /. b_val == positive_float.unwrap(result)
}

// is_less_than

pub fn is_less_than_returns_true_when_first_value_is_less_than_second_test() {
  let a = positive_float.from_float_unsafe(0.01)
  let b = positive_float.from_float_unsafe(0.02)

  assert positive_float.is_less_than(a, b)
}

pub fn is_less_than_returns_false_when_first_value_is_equal_to_second_test() {
  let a = positive_float.from_float_unsafe(0.01)
  assert !positive_float.is_less_than(a, a)
}

pub fn is_less_than_returns_false_when_first_value_is_less_than_second_test() {
  let a = positive_float.from_float_unsafe(0.01)
  let b = positive_float.from_float_unsafe(0.02)

  assert !positive_float.is_less_than(b, a)
}

// is_greater_than

pub fn is_greater_than_returns_true_when_first_value_is_greater_than_second_test() {
  let a = positive_float.from_float_unsafe(0.02)
  let b = positive_float.from_float_unsafe(0.01)

  assert positive_float.is_greater_than(a, b)
}

pub fn is_greater_than_returns_false_when_first_value_is_equal_to_second_test() {
  let a = positive_float.from_float_unsafe(0.01)
  assert !positive_float.is_greater_than(a, a)
}

pub fn is_greater_than_returns_false_when_first_value_is_less_than_second_test() {
  let a = positive_float.from_float_unsafe(0.01)
  let b = positive_float.from_float_unsafe(0.02)

  assert !positive_float.is_greater_than(a, b)
}

// to_fixed_string

pub fn to_fixed_string_formats_correctly_test() {
  let p = positive_float.from_float_unsafe(1234.5678)
  let assert Ok("1234.57") = positive_float.to_fixed_string(p, 2)

  let assert Ok("1234.568") = positive_float.to_fixed_string(p, 3)
  let assert Ok("1234.567800") = positive_float.to_fixed_string(p, 6)
}

pub fn to_fixed_string_precision_zero_test() {
  let p1 = positive_float.from_float_unsafe(1234.5678)
  let assert Ok("1235") = positive_float.to_fixed_string(p1, 0)

  let p2 = positive_float.from_float_unsafe(0.0)
  let assert Ok("0") = positive_float.to_fixed_string(p2, 0)
}

pub fn to_fixed_string_invalid_precision_test() {
  let p = positive_float.from_float_unsafe(123.45)

  let assert Error(InvalidPrecision) = positive_float.to_fixed_string(p, -1)
  let assert Error(InvalidPrecision) = positive_float.to_fixed_string(p, 101)
}

// generators

fn max_bounded_raw_float(min) {
  let max_float =
    positive_float.max()
    |> positive_float.unwrap

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
