import qcheck.{type Generator}
import shared/positive_float.{type PositiveFloat}

// new

pub fn new_returns_error_if_less_than_zero_test() {
  assert positive_float.new(-1.0) == Error(Nil)
}

pub fn new_returns_error_if_equal_to_negative_zero_test() {
  assert positive_float.new(-0.0) == Error(Nil)
}

pub fn new_returns_error_if_equal_to_zero_test() {
  assert positive_float.new(0.0) == Error(Nil)
}

pub fn new_returns_ok_if_greater_than_zero_test() {
  let assert Ok(_) = positive_float.new(0.01)
}

// with_value

pub fn with_value_applies_function_to_inner_value_test() {
  let p = positive_float.from_float_unsafe(1.0)
  assert 2.0 == positive_float.with_value(p, fn(f) { f *. 2.0 })
}

// multiply

pub fn multiply_by_one_returns_self_test() {
  qcheck.given(
    max_bounded_positive_float_generator(positive_float.from_float_unsafe(0.1)),
    fn(p) {
      let one = positive_float.from_float_unsafe(1.0)
      assert p == positive_float.multiply(p, one)
    },
  )
}

pub fn multiply_test() {
  use a <- qcheck.given(multiplication_safe_generator())
  use b <- qcheck.given(multiplication_safe_generator())
  let result = positive_float.multiply(a, b)

  let a_val = positive_float.unwrap(a)
  let b_val = positive_float.unwrap(b)
  let result_val = positive_float.unwrap(result)

  assert a_val *. b_val == result_val
}

// try_divide

pub fn try_divide_by_one_returns_self_test() {
  qcheck.given(
    max_bounded_positive_float_generator(positive_float.from_float_unsafe(0.1)),
    fn(n) {
      let one = positive_float.from_float_unsafe(1.0)
      let assert Ok(result) = positive_float.try_divide(n, one)
      assert n == result
    },
  )
}

pub fn try_divide_test() {
  use a <- qcheck.given(
    max_bounded_positive_float_generator(positive_float.from_float_unsafe(0.1)),
  )
  use b <- qcheck.given(
    max_bounded_positive_float_generator(positive_float.from_float_unsafe(0.1)),
  )
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

// generators

fn max_bounded_positive_float_generator(
  min: PositiveFloat,
) -> Generator(PositiveFloat) {
  let max_float = positive_float.unwrap(positive_float.max)
  let min_float = positive_float.unwrap(min)

  min_float
  |> qcheck.bounded_float(max_float)
  |> qcheck.map(positive_float.from_float_unsafe)
}

fn multiplication_safe_generator() -> Generator(PositiveFloat) {
  // bound by sqrt of max float, safe for multiplication
  0.1
  |> qcheck.bounded_float(1.0e154)
  |> qcheck.map(positive_float.from_float_unsafe)
}
