import client/currency/formatting
import gleam/option.{Some}
import shared/currency.{Crypto, Fiat}
import shared/non_negative_float

const fiat = Fiat(2781, "United States Dollar", "USD", "$")

const crypto = Crypto(1, "Bitcoin", "BTC", Some(1))

// format_currency_amount - trailing zero removal logic

// No decimal places - integer value
pub fn format_currency_amount_integer_value_test() {
  let p = non_negative_float.from_float_unsafe(100.0)
  assert formatting.format_currency_amount(crypto, p) == "100"
}

// Single trailing zero
pub fn format_currency_amount_single_trailing_zero_test() {
  let p = non_negative_float.from_float_unsafe(1.23)
  assert formatting.format_currency_amount(crypto, p) == "1.23"
}

// Multiple trailing zeros
pub fn format_currency_amount_multiple_trailing_zeros_test() {
  let p = non_negative_float.from_float_unsafe(1.23)
  assert formatting.format_currency_amount(crypto, p) == "1.23"
}

// All zeros after decimal - should remove decimal point
pub fn format_currency_amount_all_zeros_after_decimal_test() {
  let p = non_negative_float.from_float_unsafe(42.0)
  assert formatting.format_currency_amount(crypto, p) == "42"
}

// No trailing zeros - should keep as-is
pub fn format_currency_amount_no_trailing_zeros_test() {
  let p = non_negative_float.from_float_unsafe(1.2345)
  assert formatting.format_currency_amount(crypto, p) == "1.2345"
}

// Trailing zeros in middle precision range
pub fn format_currency_amount_trailing_zeros_mid_precision_test() {
  let p = non_negative_float.from_float_unsafe(0.1234)
  assert formatting.format_currency_amount(crypto, p) == "0.1234"
}

// Very small value with trailing zeros
pub fn format_currency_amount_very_small_with_trailing_zeros_test() {
  let p = non_negative_float.from_float_unsafe(0.000012)
  assert formatting.format_currency_amount(crypto, p) == "0.000012"
}

// format_currency_amount - Comma grouping logic

// No comma needed - less than 1000
pub fn format_currency_amount_no_comma_needed_test() {
  let p = non_negative_float.from_float_unsafe(999.99)
  assert formatting.format_currency_amount(crypto, p) == "999.99"
}

// Single comma - thousands
pub fn format_currency_amount_thousands_test() {
  let p = non_negative_float.from_float_unsafe(1234.567)
  assert formatting.format_currency_amount(crypto, p) == "1,234.567"
}

// Multiple commas - millions
pub fn format_currency_amount_millions_test() {
  let p = non_negative_float.from_float_unsafe(1_234_567.89)
  assert formatting.format_currency_amount(crypto, p) == "1,234,567.89"
}

// Large number - billions
pub fn format_currency_amount_billions_test() {
  let p = non_negative_float.from_float_unsafe(1_234_567_890.12)
  assert formatting.format_currency_amount(crypto, p) == "1,234,567,890.12"
}

// Exactly at thousand boundary
pub fn format_currency_amount_exactly_thousand_test() {
  let p = non_negative_float.from_float_unsafe(1000.0)
  assert formatting.format_currency_amount(crypto, p) == "1,000"
}

// Comma grouping with trailing zero removal
pub fn format_currency_amount_comma_with_trailing_zeros_test() {
  let p = non_negative_float.from_float_unsafe(10_000.0)
  assert formatting.format_currency_amount(crypto, p) == "10,000"
}

// Comma grouping with small decimal
pub fn format_currency_amount_comma_with_small_decimal_test() {
  let p = non_negative_float.from_float_unsafe(1234.5)
  assert formatting.format_currency_amount(crypto, p) == "1,234.5"
}

// determine_max_precision - fiat

// Branch 1: a == 0.0 -> 0
pub fn determine_max_precision_fiat_amount_zero_test() {
  let p = non_negative_float.from_float_unsafe(0.0)
  assert formatting.determine_max_precision(fiat, p) == 0
}

// Branch 2: a <. 0.01 -> 8
pub fn determine_max_precision_fiat_amount_below_point_zero_one_test() {
  let p = non_negative_float.from_float_unsafe(0.0099)
  assert formatting.determine_max_precision(fiat, p) == 8
}

pub fn determine_max_precision_fiat_very_small_amount_test() {
  let p = non_negative_float.from_float_unsafe(0.00000001)
  assert formatting.determine_max_precision(fiat, p) == 8
}

// Branch 3: _ -> 2
pub fn determine_max_precision_fiat_amount_exactly_point_zero_one_test() {
  let p = non_negative_float.from_float_unsafe(0.01)
  assert formatting.determine_max_precision(fiat, p) == 2
}

pub fn determine_max_precision_fiat_normal_amount_test() {
  let p = non_negative_float.from_float_unsafe(1.0)
  assert formatting.determine_max_precision(fiat, p) == 2
}

pub fn determine_max_precision_fiat_large_amount_test() {
  let p = non_negative_float.from_float_unsafe(100.5)
  assert formatting.determine_max_precision(fiat, p) == 2
}

// determine_max_precision - crypto

// Branch 1: a == 0.0 -> 0
pub fn determine_max_precision_crypto_amount_zero_test() {
  let p = non_negative_float.from_float_unsafe(0.0)
  assert formatting.determine_max_precision(crypto, p) == 0
}

// Branch 2: a >=. 1.0 -> 4
pub fn determine_max_precision_crypto_amount_exactly_one_test() {
  let p = non_negative_float.from_float_unsafe(1.0)
  assert formatting.determine_max_precision(crypto, p) == 4
}

pub fn determine_max_precision_crypto_amount_above_one_test() {
  let p = non_negative_float.from_float_unsafe(1.1)
  assert formatting.determine_max_precision(crypto, p) == 4
}

pub fn determine_max_precision_crypto_large_amount_test() {
  let p = non_negative_float.from_float_unsafe(1_000_000.0)
  assert formatting.determine_max_precision(crypto, p) == 4
}

// Branch 3: a >=. 0.01 -> 6
pub fn determine_max_precision_crypto_amount_equal_point_zero_one_test() {
  let p = non_negative_float.from_float_unsafe(0.01)
  assert formatting.determine_max_precision(crypto, p) == 6
}

pub fn determine_max_precision_crypto_amount_mid_range_test() {
  let p = non_negative_float.from_float_unsafe(0.5)
  assert formatting.determine_max_precision(crypto, p) == 6
}

pub fn determine_max_precision_crypto_amount_below_one_but_above_point_zero_one_test() {
  let p = non_negative_float.from_float_unsafe(0.9999)
  assert formatting.determine_max_precision(crypto, p) == 6
}

// Branch 4: _ -> 8 (< 0.01)
pub fn determine_max_precision_crypto_amount_below_point_zero_one_test() {
  let p = non_negative_float.from_float_unsafe(0.0099)
  assert formatting.determine_max_precision(crypto, p) == 8
}

pub fn determine_max_precision_crypto_very_small_amount_test() {
  let p = non_negative_float.from_float_unsafe(0.00000001)
  assert formatting.determine_max_precision(crypto, p) == 8
}

// epsilon

pub fn determine_max_precision_crypto_epsilon_near_point_zero_one_test() {
  let p = non_negative_float.from_float_unsafe(0.01 -. 5.0e-13)
  assert formatting.determine_max_precision(crypto, p) == 6
}

pub fn determine_max_precision_crypto_epsilon_near_one_test() {
  let p = non_negative_float.from_float_unsafe(1.0 -. 5.0e-13)
  assert formatting.determine_max_precision(crypto, p) == 4
}
