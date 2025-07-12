import client/currency/collection.{CryptoCurrency, FiatCurrency}
import gleam/option.{None, Some}
import gleam/order
import shared/currency.{Crypto, Fiat}

pub fn group_returns_cryptos_first_test() {
  let crypto = Crypto(0, "", "", None)
  let fiat = Fiat(0, "", "", "")

  assert [#(CryptoCurrency, [crypto]), #(FiatCurrency, [fiat])]
    == collection.group([fiat, crypto])
}

pub fn find_flat_index_test() {
  let currencies = [
    Crypto(1, "", "", Some(1)),
    Fiat(4, "b", "", ""),
    Fiat(3, "a", "", ""),
    Crypto(2, "", "", Some(2)),
  ]

  let result =
    currencies
    |> collection.group
    |> collection.find_flat_index(4)

  assert Ok(3) == result
}

pub fn find_flat_index_when_currency_id_not_found_test() {
  let currencies = [Crypto(1, "", "", Some(1)), Fiat(2, "b", "", "")]

  let result =
    currencies
    |> collection.group
    |> collection.find_flat_index(of: 3)

  assert Error(Nil) == result
}

pub fn find_by_flat_index_test() {
  let currencies = [
    Crypto(1, "", "", Some(1)),
    Fiat(4, "b", "", ""),
    Fiat(3, "a", "", ""),
    Crypto(2, "", "", Some(2)),
  ]

  let result =
    currencies
    |> collection.group
    |> collection.find_by_flat_index(at: 3)

  assert Ok(Fiat(4, "b", "", "")) == result
}

pub fn find_by_flat_index_when_out_of_bounds_test() {
  let currencies = [Crypto(1, "", "", Some(1)), Fiat(2, "b", "", "")]

  let result =
    currencies
    |> collection.group
    |> collection.find_by_flat_index(at: 2)

  assert Error(Nil) == result
}

pub fn sort_cryptos_currency_not_a_crypto_test() {
  let result =
    Crypto(0, "", "", None)
    |> collection.sort_cryptos(Fiat(0, "", "", ""))

  assert Error(Nil) == result
}

pub fn sort_cryptos_first_rank_is_less_than_second_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(1))
  let crypto2 = Crypto(..crypto1, rank: Some(2))

  assert Ok(order.Lt) == collection.sort_cryptos(crypto1, crypto2)
}

pub fn sort_cryptos_first_rank_is_greater_than_first_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(2))
  let crypto2 = Crypto(..crypto1, rank: Some(1))

  assert Ok(order.Gt) == collection.sort_cryptos(crypto1, crypto2)
}

pub fn sort_cryptos_first_rank_equals_second_rank_test() {
  let crypto = Crypto(0, "", "", Some(1))
  assert Ok(order.Eq) == collection.sort_cryptos(crypto, crypto)
}

pub fn sort_cryptos_second_crypto_has_no_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(1))
  let crypto2 = Crypto(..crypto1, rank: None)

  assert Ok(order.Lt) == collection.sort_cryptos(crypto1, crypto2)
}

pub fn sort_cryptos_first_crypto_has_no_rank_test() {
  let crypto1 = Crypto(0, "", "", None)
  let crypto2 = Crypto(..crypto1, rank: Some(1))

  assert Ok(order.Gt) == collection.sort_cryptos(crypto1, crypto2)
}

pub fn sort_cryptos_both_cryptos_have_no_rank_test() {
  let crypto1 = Crypto(0, "A", "", None)
  let crypto2 = Crypto(..crypto1, name: "B", rank: None)

  assert Ok(order.Lt) == collection.sort_cryptos(crypto1, crypto2)
}

pub fn sort_fiats_currency_not_a_fiat_test() {
  let result =
    Fiat(0, "", "", "")
    |> collection.sort_fiats(Crypto(0, "", "", None))

  assert Error(Nil) == result
}

pub fn sort_fiats_orders_by_name_test() {
  let fiat1 = Fiat(0, "B", "B", "")
  let fiat2 = Fiat(..fiat1, name: "A", symbol: "A")

  assert Ok(order.Gt) == collection.sort_fiats(fiat1, fiat2)
}

pub fn sort_fiats_first_fiat_is_usd_test() {
  let fiat1 = Fiat(0, "USD", "USD", "")
  let fiat2 = Fiat(..fiat1, name: "EUR", symbol: "EUR")

  assert Ok(order.Lt) == collection.sort_fiats(fiat1, fiat2)
}

pub fn sort_fiats_second_fiat_is_usd_test() {
  let fiat1 = Fiat(0, "EUR", "EUR", "")
  let fiat2 = Fiat(..fiat1, name: "USD", symbol: "USD")

  assert Ok(order.Gt) == collection.sort_fiats(fiat1, fiat2)
}

pub fn filter_incudes_currency_when_filter_string_contains_name_test() {
  let result =
    [Crypto(0, "ABC", "DEF", None), Crypto(0, "GHI", "JKL", None)]
    |> collection.filter("ab")

  assert [Crypto(0, "ABC", "DEF", None)] == result
}

pub fn filter_includes_currency_when_filter_string_contains_symbol_test() {
  let result =
    [Crypto(0, "ABC", "DEF", None), Crypto(0, "GHI", "JKL", None)]
    |> collection.filter("jk")

  assert [Crypto(0, "GHI", "JKL", None)] == result
}

pub fn filter_includes_everything_when_filter_string_is_empty_test() {
  let result =
    [Crypto(0, "ABC", "DEF", None), Crypto(0, "GHI", "JKL", None)]
    |> collection.filter("")

  assert [Crypto(0, "ABC", "DEF", None), Crypto(0, "GHI", "JKL", None)]
    == result
}
