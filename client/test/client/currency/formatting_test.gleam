import client/currency/formatting
import gleam/option.{Some}
import gleeunit/should
import shared/currency.{Crypto, Fiat}

const fiat = Fiat(2781, "United States Dollar", "USD", "$")

const crypto = Crypto(1, "Bitcoin", "BTC", Some(1))

pub fn determine_max_precision_fiat_any_amount_test() {
  fiat
  |> formatting.determine_max_precision(1000.1234)
  |> should.equal(2)
}

pub fn determine_max_precision_fiat_amount_tiny_test() {
  fiat
  |> formatting.determine_max_precision(0.005)
  |> should.equal(2)
}

pub fn determine_max_precision_crypto_amount_above_one_test() {
  crypto
  |> formatting.determine_max_precision(1.1)
  |> should.equal(4)
}

pub fn determine_max_precision_crypto_amount_below_one_but_above_point_zero_one_test() {
  crypto
  |> formatting.determine_max_precision(0.9999)
  |> should.equal(6)
}

pub fn determine_max_precision_crypto_amount_equal_point_zero_one_test() {
  crypto
  |> formatting.determine_max_precision(0.01)
  |> should.equal(6)
}

pub fn determine_max_precision_crypto_amount_below_point_zero_one_test() {
  crypto
  |> formatting.determine_max_precision(0.0099)
  |> should.equal(8)
}

pub fn determine_max_precision_crypto_amount_zero_test() {
  crypto
  |> formatting.determine_max_precision(0.0)
  |> should.equal(0)
}

pub fn format_amount_str_fiat_trailing_zeros_stripped_test() {
  fiat
  |> formatting.format_amount_str(50.0)
  |> should.equal("50")
}

pub fn format_amount_str_crypto_above_one_test() {
  crypto
  |> formatting.format_amount_str(2.3)
  |> should.equal("2.3")
}

// this ends up displaying as 9.0e-8. should i worry about amounts this small?
// pub fn format_amount_str_crypto_below_point_zero_one_pad_test() {
//   crypto
//   |> currency.format_amount_str(0.00000009)
//   |> should.equal("0.00000009")
// }

pub fn format_amount_str_crypto_zero_amount_returns_zero_test() {
  crypto
  |> formatting.format_amount_str(0.0)
  |> should.equal("0")
}

pub fn format_amount_str_negative_amounts_treated_as_positive_test() {
  fiat
  |> formatting.format_amount_str(-123.456)
  |> should.equal("123.46")
}

pub fn format_amount_str_four_digits_before_decimal_test() {
  fiat
  |> formatting.format_amount_str(1234.0)
  |> should.equal("1,234")
}

pub fn format_amount_str_five_digits_before_decimal_test() {
  fiat
  |> formatting.format_amount_str(12_345.0)
  |> should.equal("12,345")
}

pub fn format_amount_str_six_digits_before_decimal_test() {
  fiat
  |> formatting.format_amount_str(123_456.0)
  |> should.equal("123,456")
}

pub fn format_amount_str_ten_digits_before_decimal_test() {
  fiat
  |> formatting.format_amount_str(1_234_567_890.0)
  |> should.equal("1,234,567,890")
}
