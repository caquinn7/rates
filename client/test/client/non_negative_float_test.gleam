import client/non_negative_float.{type NonNegativeFloat, InvalidPrecision}
import qcheck.{type Generator}

// new

pub fn new_returns_error_if_less_than_zero_test() {
  assert Error(Nil) == non_negative_float.new(-1.0)
}

pub fn new_returns_ok_if_equal_to_negative_zero_test() {
  let assert Ok(_) = non_negative_float.new(-0.0)
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
  assert 123.0 == non_negative_float.unwrap(n1)

  let assert Ok(n2) = non_negative_float.parse("123.45")
  assert 123.45 == non_negative_float.unwrap(n2)

  let assert Ok(n3) = non_negative_float.parse("0")
  assert 0.0 == non_negative_float.unwrap(n3)
}

pub fn parse_accepts_edge_case_formats_test() {
  let assert Ok(n1) = non_negative_float.parse(".5")
  assert 0.5 == non_negative_float.unwrap(n1)

  let assert Ok(n2) = non_negative_float.parse("123.")
  assert 123.0 == non_negative_float.unwrap(n2)

  let assert Ok(n3) = non_negative_float.parse("0.0")
  assert 0.0 == non_negative_float.unwrap(n3)
}

pub fn parse_accepts_comma_separated_input_test() {
  let assert Ok(n1) = non_negative_float.parse("1,000")
  assert 1000.0 == non_negative_float.unwrap(n1)

  let assert Ok(n2) = non_negative_float.parse("1,234.56")
  assert 1234.56 == non_negative_float.unwrap(n2)
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

// with_value

pub fn with_value_applies_function_to_inner_value_test() {
  let n = non_negative_float.from_float_unsafe(1.0)
  assert 2.0 == non_negative_float.with_value(n, fn(f) { f *. 2.0 })
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

// pub fn infinity_test() {
//   non_negative_float.max()
//   |> echo
//   |> non_negative_float.multiply(non_negative_float.from_float_unsafe(2.0))
//   |> echo
// }

pub fn multiply_by_one_returns_self_test() {
  qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.0),
    ),
    fn(n) {
      let one = non_negative_float.from_float_unsafe(1.0)
      assert n == non_negative_float.multiply(n, one)
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
      assert zero == non_negative_float.multiply(n, zero)
    },
  )
}

pub fn multiply_test() {
  use a <- qcheck.given(multiplication_safe_generator())
  use b <- qcheck.given(multiplication_safe_generator())
  let result = non_negative_float.multiply(a, b)

  let a_val = non_negative_float.unwrap(a)
  let b_val = non_negative_float.unwrap(b)
  let result_val = non_negative_float.unwrap(result)

  assert a_val *. b_val == result_val
}

// try_divide

pub fn try_divide_by_zero_returns_error_test() {
  let n1 = non_negative_float.from_float_unsafe(1.0)
  let n2 = non_negative_float.from_float_unsafe(0.0)
  assert Error(Nil) == non_negative_float.try_divide(n1, n2)
}

pub fn try_divide_zero_by_any_is_zero_test() {
  qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.1),
    ),
    fn(n) {
      let zero = non_negative_float.from_float_unsafe(0.0)
      let assert Ok(result) = non_negative_float.try_divide(zero, n)
      assert 0.0 == non_negative_float.unwrap(result)
    },
  )
}

pub fn try_divide_by_one_returns_self_test() {
  qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.0),
    ),
    fn(n) {
      let one = non_negative_float.from_float_unsafe(1.0)
      let assert Ok(result) = non_negative_float.try_divide(n, one)
      assert n == result
    },
  )
}

pub fn try_divide_test() {
  use a <- qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.0),
    ),
  )
  use b <- qcheck.given(
    max_bounded_non_negative_float_generator(
      non_negative_float.from_float_unsafe(0.1),
    ),
  )
  let assert Ok(result) = non_negative_float.try_divide(a, b)

  let a_val = non_negative_float.unwrap(a)
  let b_val = non_negative_float.unwrap(b)

  assert a_val /. b_val == non_negative_float.unwrap(result)
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
  let p = non_negative_float.from_float_unsafe(123.45)

  let assert Error(InvalidPrecision) = non_negative_float.to_fixed_string(p, -1)
  let assert Error(InvalidPrecision) =
    non_negative_float.to_fixed_string(p, 101)
}

// generators

fn max_bounded_non_negative_float_generator(
  min: NonNegativeFloat,
) -> Generator(NonNegativeFloat) {
  let max_float = non_negative_float.unwrap(non_negative_float.max())
  let min_float = non_negative_float.unwrap(min)

  min_float
  |> qcheck.bounded_float(max_float)
  |> qcheck.map(non_negative_float.from_float_unsafe)
}

fn multiplication_safe_generator() -> Generator(NonNegativeFloat) {
  // bound by sqrt of max float, safe for multiplication
  0.0
  |> qcheck.bounded_float(1.0e154)
  |> qcheck.map(non_negative_float.from_float_unsafe)
}
