import client/currency/formatting
import client/positive_float

// format_currency_amount tests - focus on trailing zero removal logic

// Zero amount returns "0" (no decimal point)
pub fn format_currency_amount_zero_test() {
  let p = positive_float.from_float_unsafe(0.0)
  assert formatting.format_currency_amount(p) == "0"
}

// Trailing zeros removed - all zeros after decimal point
pub fn format_currency_amount_whole_number_test() {
  let p = positive_float.from_float_unsafe(5.0)
  assert formatting.format_currency_amount(p) == "5"
}

// Trailing zeros removed - some significant digits remain
pub fn format_currency_amount_trailing_zeros_removed_test() {
  let p = positive_float.from_float_unsafe(1.23)
  assert formatting.format_currency_amount(p) == "1.23"
}

// No trailing zeros - all digits significant
pub fn format_currency_amount_no_trailing_zeros_test() {
  let p = positive_float.from_float_unsafe(1.2346)
  assert formatting.format_currency_amount(p) == "1.2346"
}

// Single significant digit after decimal
pub fn format_currency_amount_single_decimal_test() {
  let p = positive_float.from_float_unsafe(1.5)
  assert formatting.format_currency_amount(p) == "1.5"
}

// Very small amount with trailing zeros
pub fn format_currency_amount_small_with_trailing_zeros_test() {
  let p = positive_float.from_float_unsafe(0.001)
  assert formatting.format_currency_amount(p) == "0.001"
}

// determine_max_precision tests

// Branch 1: a == 0.0 -> 0
pub fn determine_max_precision_amount_zero_test() {
  let p = positive_float.from_float_unsafe(0.0)
  assert formatting.determine_max_precision(p) == 0
}

// Branch 2: a >=. 1.0 -> 4
pub fn determine_max_precision_amount_exactly_one_test() {
  let p = positive_float.from_float_unsafe(1.0)
  assert formatting.determine_max_precision(p) == 4
}

pub fn determine_max_precision_amount_above_one_test() {
  let p = positive_float.from_float_unsafe(1.1)
  assert formatting.determine_max_precision(p) == 4
}

pub fn determine_max_precision_large_amount_test() {
  let p = positive_float.from_float_unsafe(1_000_000.0)
  assert formatting.determine_max_precision(p) == 4
}

// Branch 3: a >=. 0.01 -> 6
pub fn determine_max_precision_amount_equal_point_zero_one_test() {
  let p = positive_float.from_float_unsafe(0.01)
  assert formatting.determine_max_precision(p) == 6
}

pub fn determine_max_precision_amount_mid_range_test() {
  let p = positive_float.from_float_unsafe(0.5)
  assert formatting.determine_max_precision(p) == 6
}

pub fn determine_max_precision_amount_below_one_but_above_point_zero_one_test() {
  let p = positive_float.from_float_unsafe(0.9999)
  assert formatting.determine_max_precision(p) == 6
}

// Branch 4: _ -> 8 (< 0.01)
pub fn determine_max_precision_amount_below_point_zero_one_test() {
  let p = positive_float.from_float_unsafe(0.0099)
  assert formatting.determine_max_precision(p) == 8
}

pub fn determine_max_precision_very_small_amount_test() {
  let p = positive_float.from_float_unsafe(0.00000001)
  assert formatting.determine_max_precision(p) == 8
}
