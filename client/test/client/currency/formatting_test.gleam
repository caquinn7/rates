import client/currency/formatting
import client/positive_float
import gleam/option.{Some}
import shared/currency.{Crypto, Fiat}

const fiat = Fiat(2781, "United States Dollar", "USD", "$")

const crypto = Crypto(1, "Bitcoin", "BTC", Some(1))

pub fn fiat_always_two_decimal_places_test() {
  let p = positive_float.from_float_unsafe(1234.5678)
  assert "1,234.57" == formatting.format_currency_amount(fiat, p)
}

pub fn crypto_zero_amount_no_fractional_test() {
  let p = positive_float.from_float_unsafe(0.0)
  assert "0" == formatting.format_currency_amount(crypto, p)
}

pub fn crypto_four_decimals_for_one_or_more_test() {
  let p = positive_float.from_float_unsafe(1.23456789)
  assert "1.2346" == formatting.format_currency_amount(crypto, p)
}

pub fn crypto_six_decimals_between_point01_and_1_test() {
  let p = positive_float.from_float_unsafe(0.123456789)
  assert "0.123457" == formatting.format_currency_amount(crypto, p)
}

pub fn crypto_eight_decimals_below_point01_test() {
  let p = positive_float.from_float_unsafe(0.000000123456789)
  assert "0.00000012" == formatting.format_currency_amount(crypto, p)
}

pub fn determine_max_precision_fiat_any_amount_test() {
  let p = positive_float.from_float_unsafe(1000.1234)
  assert 2 == formatting.determine_max_precision(fiat, p)
}

pub fn determine_max_precision_fiat_amount_tiny_test() {
  let p = positive_float.from_float_unsafe(0.005)
  assert 2 == formatting.determine_max_precision(fiat, p)
}

pub fn determine_max_precision_crypto_amount_above_one_test() {
  let p = positive_float.from_float_unsafe(1.1)
  assert 4 == formatting.determine_max_precision(crypto, p)
}

pub fn determine_max_precision_crypto_amount_below_one_but_above_point_zero_one_test() {
  let p = positive_float.from_float_unsafe(0.9999)
  assert 6 == formatting.determine_max_precision(crypto, p)
}

pub fn determine_max_precision_crypto_amount_equal_point_zero_one_test() {
  let p = positive_float.from_float_unsafe(0.01)
  assert 6 == formatting.determine_max_precision(crypto, p)
}

pub fn determine_max_precision_crypto_amount_below_point_zero_one_test() {
  let p = positive_float.from_float_unsafe(0.0099)
  assert 8 == formatting.determine_max_precision(crypto, p)
}

pub fn determine_max_precision_crypto_amount_zero_test() {
  let p = positive_float.from_float_unsafe(0.0)
  assert 0 == formatting.determine_max_precision(crypto, p)
}
