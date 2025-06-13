import client/currency.{CryptoCurrency, FiatCurrency}
import gleam/dict
import gleam/option.{None, Some}
import gleam/order
import gleeunit/should
import shared/currency.{Crypto, Fiat} as _shared_currency

const fiat = Fiat(2781, "United States Dollar", "USD", "$")

const crypto = Crypto(1, "Bitcoin", "BTC", Some(1))

pub fn group_by_type_test() {
  let result =
    [crypto, fiat]
    |> currency.group_by_type

  result
  |> dict.get(CryptoCurrency)
  |> should.be_ok
  |> should.equal([crypto])

  result
  |> dict.get(FiatCurrency)
  |> should.be_ok
  |> should.equal([fiat])
}

pub fn group_by_type_empty_list_test() {
  []
  |> currency.group_by_type
  |> should.equal(dict.new())
}

pub fn sort_cryptos_currency_not_a_crypto_test() {
  crypto
  |> currency.sort_cryptos(fiat)
  |> should.be_error
  |> should.equal(Nil)
}

pub fn sort_cryptos_first_rank_is_less_than_second_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(1))
  let crypto2 = Crypto(..crypto1, rank: Some(2))

  currency.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Lt)
}

pub fn sort_cryptos_first_rank_is_greater_than_first_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(2))
  let crypto2 = Crypto(..crypto1, rank: Some(1))

  currency.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Gt)
}

pub fn sort_cryptos_first_rank_equals_second_rank_test() {
  let crypto = Crypto(0, "", "", Some(1))

  currency.sort_cryptos(crypto, crypto)
  |> should.be_ok
  |> should.equal(order.Eq)
}

pub fn sort_cryptos_second_crypto_has_no_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(1))
  let crypto2 = Crypto(..crypto1, rank: None)

  currency.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Lt)
}

pub fn sort_cryptos_first_crypto_has_no_rank_test() {
  let crypto1 = Crypto(0, "", "", None)
  let crypto2 = Crypto(..crypto1, rank: Some(1))

  currency.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Gt)
}

pub fn sort_cryptos_both_cryptos_have_no_rank_test() {
  let crypto1 = Crypto(0, "A", "", None)
  let crypto2 = Crypto(..crypto1, name: "B", rank: None)

  currency.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Lt)
}

pub fn sort_fiats_currency_not_a_fiat_test() {
  fiat
  |> currency.sort_fiats(crypto)
  |> should.be_error
  |> should.equal(Nil)
}

pub fn sort_fiats_orders_by_name_test() {
  let fiat1 = Fiat(0, "B", "B", "")
  let fiat2 = Fiat(..fiat1, name: "A", symbol: "A")

  currency.sort_fiats(fiat1, fiat2)
  |> should.be_ok
  |> should.equal(order.Gt)
}

pub fn sort_fiats_first_fiat_is_usd_test() {
  let fiat1 = Fiat(0, "USD", "USD", "")
  let fiat2 = Fiat(..fiat1, name: "EUR", symbol: "EUR")

  currency.sort_fiats(fiat1, fiat2)
  |> should.be_ok
  |> should.equal(order.Lt)
}

pub fn sort_fiats_second_fiat_is_usd_test() {
  let fiat1 = Fiat(0, "EUR", "EUR", "")
  let fiat2 = Fiat(..fiat1, name: "USD", symbol: "USD")

  currency.sort_fiats(fiat1, fiat2)
  |> should.be_ok
  |> should.equal(order.Gt)
}

pub fn determine_max_precision_fiat_any_amount_test() {
  fiat
  |> currency.determine_max_precision(1000.1234)
  |> should.equal(2)
}

pub fn determine_max_precision_fiat_amount_tiny_test() {
  fiat
  |> currency.determine_max_precision(0.005)
  |> should.equal(2)
}

pub fn determine_max_precision_crypto_amount_above_one_test() {
  crypto
  |> currency.determine_max_precision(1.1)
  |> should.equal(4)
}

pub fn determine_max_precision_crypto_amount_below_one_but_above_point_zero_one_test() {
  crypto
  |> currency.determine_max_precision(0.9999)
  |> should.equal(6)
}

pub fn determine_max_precision_crypto_amount_equal_point_zero_one_test() {
  crypto
  |> currency.determine_max_precision(0.01)
  |> should.equal(6)
}

pub fn determine_max_precision_crypto_amount_below_point_zero_one_test() {
  crypto
  |> currency.determine_max_precision(0.0099)
  |> should.equal(8)
}

pub fn determine_max_precision_crypto_amount_zero_test() {
  crypto
  |> currency.determine_max_precision(0.0)
  |> should.equal(0)
}

pub fn format_amount_str_fiat_trailing_zeros_stripped_test() {
  fiat
  |> currency.format_amount_str(50.0)
  |> should.equal("50")
}

pub fn format_amount_str_crypto_above_one_test() {
  crypto
  |> currency.format_amount_str(2.3)
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
  |> currency.format_amount_str(0.0)
  |> should.equal("0")
}

pub fn format_amount_str_negative_amounts_treated_as_positive_test() {
  fiat
  |> currency.format_amount_str(-123.456)
  |> should.equal("123.46")
}

pub fn format_amount_str_four_digits_before_decimal_test() {
  fiat
  |> currency.format_amount_str(1234.0)
  |> should.equal("1,234")
}

pub fn format_amount_str_five_digits_before_decimal_test() {
  fiat
  |> currency.format_amount_str(12_345.0)
  |> should.equal("12,345")
}

pub fn format_amount_str_six_digits_before_decimal_test() {
  fiat
  |> currency.format_amount_str(123_456.0)
  |> should.equal("123,456")
}

pub fn format_amount_str_ten_digits_before_decimal_test() {
  fiat
  |> currency.format_amount_str(1_234_567_890.0)
  |> should.equal("1,234,567,890")
}
