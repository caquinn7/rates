import client/currency/formatting
import gleam/option.{Some}
import shared/currency.{Crypto, Fiat}

const fiat = Fiat(2781, "United States Dollar", "USD", "$")

const crypto = Crypto(1, "Bitcoin", "BTC", Some(1))

pub fn parse_amount_str_when_not_a_number_test() {
  assert Error(Nil) == formatting.parse_amount("")
}

pub fn parse_amount_str_when_int_test() {
  assert Ok(1.0) == formatting.parse_amount("1")
}

pub fn parse_amount_str_when_float_test() {
  assert Ok(1.23) == formatting.parse_amount("1.23")
}

pub fn parse_amount_str_when_ends_with_decimal_test() {
  assert Ok(1.0) == formatting.parse_amount("1.")
}

pub fn parse_amount_str_when_starts_with_decimal_test() {
  assert Ok(0.1) == formatting.parse_amount(".1")
}

pub fn parse_amount_str_when_has_commas_test() {
  assert Ok(1_000_000.0) == formatting.parse_amount("1,000,000")
}

pub fn format_amount_str_fiat_trailing_zeros_stripped_test() {
  assert "50" == formatting.format_amount_str(fiat, 50.0)
}

pub fn format_amount_str_crypto_above_one_test() {
  assert "2.3" == formatting.format_amount_str(crypto, 2.3)
}

// this ends up displaying as 9.0e-8. should i worry about amounts this small?
// pub fn format_amount_str_crypto_below_point_zero_one_pad_test() {
//   crypto
//   |> currency.format_amount_str(0.00000009)
//   |> should.equal("0.00000009")
// }

pub fn format_amount_str_crypto_zero_amount_returns_zero_test() {
  assert "0" == formatting.format_amount_str(crypto, 0.0)
}

pub fn format_amount_str_negative_amounts_treated_as_positive_test() {
  assert "123.46" == formatting.format_amount_str(fiat, -123.456)
}

pub fn format_amount_str_four_digits_before_decimal_test() {
  assert "1,234" == formatting.format_amount_str(fiat, 1234.0)
}

pub fn format_amount_str_five_digits_before_decimal_test() {
  assert "12,345" == formatting.format_amount_str(fiat, 12_345.0)
}

pub fn format_amount_str_six_digits_before_decimal_test() {
  assert "123,456" == formatting.format_amount_str(fiat, 123_456.0)
}

pub fn format_amount_str_ten_digits_before_decimal_test() {
  assert "1,234,567,890" == formatting.format_amount_str(fiat, 1_234_567_890.0)
}

pub fn determine_max_precision_fiat_any_amount_test() {
  assert 2 == formatting.determine_max_precision(fiat, 1000.1234)
}

pub fn determine_max_precision_fiat_amount_tiny_test() {
  assert 2 == formatting.determine_max_precision(fiat, 0.005)
}

pub fn determine_max_precision_crypto_amount_above_one_test() {
  assert 4 == formatting.determine_max_precision(crypto, 1.1)
}

pub fn determine_max_precision_crypto_amount_below_one_but_above_point_zero_one_test() {
  assert 6 == formatting.determine_max_precision(crypto, 0.9999)
}

pub fn determine_max_precision_crypto_amount_equal_point_zero_one_test() {
  assert 6 == formatting.determine_max_precision(crypto, 0.01)
}

pub fn determine_max_precision_crypto_amount_below_point_zero_one_test() {
  assert 8 == formatting.determine_max_precision(crypto, 0.0099)
}

pub fn determine_max_precision_crypto_amount_zero_test() {
  assert 0 == formatting.determine_max_precision(crypto, 0.0)
}
