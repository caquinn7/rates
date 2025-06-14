import client/currency/collection
import gleam/option.{None, Some}
import gleam/order
import gleeunit/should
import shared/currency.{Crypto, Fiat}

pub fn sort_cryptos_currency_not_a_crypto_test() {
  Crypto(0, "", "", None)
  |> collection.sort_cryptos(Fiat(0, "", "", ""))
  |> should.be_error
  |> should.equal(Nil)
}

pub fn sort_cryptos_first_rank_is_less_than_second_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(1))
  let crypto2 = Crypto(..crypto1, rank: Some(2))

  collection.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Lt)
}

pub fn sort_cryptos_first_rank_is_greater_than_first_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(2))
  let crypto2 = Crypto(..crypto1, rank: Some(1))

  collection.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Gt)
}

pub fn sort_cryptos_first_rank_equals_second_rank_test() {
  let crypto = Crypto(0, "", "", Some(1))

  collection.sort_cryptos(crypto, crypto)
  |> should.be_ok
  |> should.equal(order.Eq)
}

pub fn sort_cryptos_second_crypto_has_no_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(1))
  let crypto2 = Crypto(..crypto1, rank: None)

  collection.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Lt)
}

pub fn sort_cryptos_first_crypto_has_no_rank_test() {
  let crypto1 = Crypto(0, "", "", None)
  let crypto2 = Crypto(..crypto1, rank: Some(1))

  collection.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Gt)
}

pub fn sort_cryptos_both_cryptos_have_no_rank_test() {
  let crypto1 = Crypto(0, "A", "", None)
  let crypto2 = Crypto(..crypto1, name: "B", rank: None)

  collection.sort_cryptos(crypto1, crypto2)
  |> should.be_ok
  |> should.equal(order.Lt)
}

pub fn sort_fiats_currency_not_a_fiat_test() {
  Fiat(0, "", "", "")
  |> collection.sort_fiats(Crypto(0, "", "", None))
  |> should.be_error
  |> should.equal(Nil)
}

pub fn sort_fiats_orders_by_name_test() {
  let fiat1 = Fiat(0, "B", "B", "")
  let fiat2 = Fiat(..fiat1, name: "A", symbol: "A")

  collection.sort_fiats(fiat1, fiat2)
  |> should.be_ok
  |> should.equal(order.Gt)
}

pub fn sort_fiats_first_fiat_is_usd_test() {
  let fiat1 = Fiat(0, "USD", "USD", "")
  let fiat2 = Fiat(..fiat1, name: "EUR", symbol: "EUR")

  collection.sort_fiats(fiat1, fiat2)
  |> should.be_ok
  |> should.equal(order.Lt)
}

pub fn sort_fiats_second_fiat_is_usd_test() {
  let fiat1 = Fiat(0, "EUR", "EUR", "")
  let fiat2 = Fiat(..fiat1, name: "USD", symbol: "USD")

  collection.sort_fiats(fiat1, fiat2)
  |> should.be_ok
  |> should.equal(order.Gt)
}

pub fn filter_incudes_currency_when_filter_string_contains_name_test() {
  [Crypto(0, "ABC", "DEF", None), Crypto(0, "GHI", "JKL", None)]
  |> collection.filter("ab")
  |> should.equal([Crypto(0, "ABC", "DEF", None)])
}

pub fn filter_includes_currency_when_filter_string_contains_symbol_test() {
  [Crypto(0, "ABC", "DEF", None), Crypto(0, "GHI", "JKL", None)]
  |> collection.filter("jk")
  |> should.equal([Crypto(0, "GHI", "JKL", None)])
}

pub fn filter_includes_everything_when_filter_string_is_empty_test() {
  [Crypto(0, "ABC", "DEF", None), Crypto(0, "GHI", "JKL", None)]
  |> collection.filter("")
  |> should.equal([Crypto(0, "ABC", "DEF", None), Crypto(0, "GHI", "JKL", None)])
}
