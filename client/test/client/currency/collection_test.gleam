import client/currency/collection.{CryptoCurrency, FiatCurrency}
import gleam/list
import gleam/option.{None, Some}
import gleam/order.{Eq, Gt, Lt}
import shared/currency.{Crypto, Fiat}

pub fn from_list_groups_currencies_by_type_test() {
  let result =
    [Crypto(1, "", "", None), Fiat(3, "", "", ""), Crypto(2, "", "", None)]
    |> collection.from_list
    |> collection.to_list

  assert 2 == list.length(result)

  let assert Ok(cryptos) = list.key_find(result, CryptoCurrency)
  assert 2 == list.length(cryptos)

  let assert Ok(fiats) = list.key_find(result, FiatCurrency)
  assert 1 == list.length(fiats)
}

pub fn from_list_when_only_cryptos_test() {
  let currencies = [Crypto(1, "", "", Some(2)), Crypto(2, "", "", Some(1))]

  let result =
    currencies
    |> collection.from_list
    |> collection.to_list

  assert [
      #(CryptoCurrency, list.sort(currencies, collection.compare_currencies)),
      #(FiatCurrency, []),
    ]
    == result
}

pub fn from_list_when_only_fiats_test() {
  let currencies = [Fiat(1, "", "EUR", ""), Fiat(2, "", "USD", "")]

  let result =
    currencies
    |> collection.from_list
    |> collection.to_list

  assert [
      #(CryptoCurrency, []),
      #(FiatCurrency, list.sort(currencies, collection.compare_currencies)),
    ]
    == result
}

pub fn from_list_when_list_is_empty_test() {
  let result =
    []
    |> collection.from_list
    |> collection.to_list

  assert [#(CryptoCurrency, []), #(FiatCurrency, [])] == result
}

pub fn index_of_when_currency_id_found_test() {
  let currencies = [
    Crypto(1, "", "", Some(1)),
    Fiat(4, "b", "", ""),
    Fiat(3, "a", "", ""),
    Crypto(2, "", "", Some(2)),
  ]

  let result =
    currencies
    |> collection.from_list
    |> collection.index_of(4)

  assert Ok(3) == result
}

pub fn index_of_when_currency_id_not_found_test() {
  let currencies = [Crypto(1, "", "", Some(1)), Fiat(2, "b", "", "")]

  let result =
    currencies
    |> collection.from_list
    |> collection.index_of(3)

  assert Error(Nil) == result
}

pub fn at_index_when_index_valid_test() {
  let currencies = [
    Crypto(1, "", "", Some(1)),
    Fiat(4, "b", "", ""),
    Fiat(3, "a", "", ""),
    Crypto(2, "", "", Some(2)),
  ]

  let result =
    currencies
    |> collection.from_list
    |> collection.at_index(3)

  assert Ok(Fiat(4, "b", "", "")) == result
}

pub fn at_index_when_out_of_bounds_test() {
  let currencies = [Crypto(1, "", "", Some(1)), Fiat(2, "b", "", "")]

  let result =
    currencies
    |> collection.from_list
    |> collection.at_index(2)

  assert Error(Nil) == result
}

pub fn flatten_test() {
  let currencies = [
    Crypto(1, "", "", None),
    Fiat(3, "", "", ""),
    Crypto(2, "", "", None),
  ]

  let result =
    currencies
    |> collection.from_list
    |> collection.flatten

  assert list.sort(currencies, collection.compare_currencies) == result
}

pub fn flatten_empty_collection_test() {
  let result =
    []
    |> collection.from_list
    |> collection.flatten

  assert [] == result
}

pub fn length_test() {
  let currencies = [
    Crypto(1, "", "", None),
    Fiat(3, "", "", ""),
    Crypto(2, "", "", None),
  ]

  let result =
    currencies
    |> collection.from_list
    |> collection.length

  assert 3 == result
}

pub fn length_of_empty_collection_test() {
  let result =
    []
    |> collection.from_list
    |> collection.length

  assert 0 == result
}

pub fn index_map_flat_index_is_sequential_across_groups_test() {
  let currencies = [
    Crypto(1, "", "", None),
    Fiat(2, "", "", ""),
    Fiat(3, "", "", ""),
    Crypto(4, "", "", None),
  ]

  let result =
    currencies
    |> collection.from_list
    |> collection.index_map(fn(_) { "group" }, fn(_, index) { index })
    |> list.flat_map(fn(pair) {
      let #(_, values) = pair
      values
    })

  assert [0, 1, 2, 3] == result
}

pub fn index_map_preserves_group_structure_test() {
  let currencies = [
    Crypto(10, "", "", None),
    Crypto(20, "", "", None),
    Fiat(30, "", "", ""),
  ]

  let grouped = collection.from_list(currencies)

  let result =
    collection.index_map(
      grouped,
      collection.currency_type_to_string,
      fn(currency, index) { #(currency.id, index) },
    )

  let assert Ok(crypto_group) = list.key_find(result, "Crypto")
  let assert Ok(fiat_group) = list.key_find(result, "Fiat")

  assert [#(10, 0), #(20, 1)] == crypto_group
  assert [#(30, 2)] == fiat_group
}

pub fn index_map_with_empty_collection_returns_empty_lists_test() {
  let collection = collection.from_list([])

  let result =
    collection.index_map(
      collection,
      collection.currency_type_to_string,
      fn(_, _) { "should not be called" },
    )

  assert [#("Crypto", []), #("Fiat", [])] == result
}

pub fn compare_currencies_crypto_and_fiat_test() {
  assert Lt
    == collection.compare_currencies(
      Crypto(1, "", "", None),
      Fiat(2, "", "", ""),
    )
}

pub fn compare_currencies_fiat_and_crypto_test() {
  assert Gt
    == collection.compare_currencies(
      Fiat(2, "", "", ""),
      Crypto(1, "", "", None),
    )
}

pub fn compare_currencies_compare_cryptos_when_second_crypto_has_no_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(1))
  let crypto2 = Crypto(..crypto1, rank: None)
  assert Lt == collection.compare_currencies(crypto1, crypto2)
}

pub fn compare_currencies_compare_cryptos_when_first_crypto_has_no_rank_test() {
  let crypto1 = Crypto(0, "", "", None)
  let crypto2 = Crypto(..crypto1, rank: Some(1))
  assert Gt == collection.compare_currencies(crypto1, crypto2)
}

pub fn compare_currencies_compare_cryptos_when_first_rank_less_than_second_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(1))
  let crypto2 = Crypto(..crypto1, rank: Some(2))
  assert Lt == collection.compare_currencies(crypto1, crypto2)
}

pub fn compare_currencies_compare_cryptos_when_first_rank_greater_than_second_rank_test() {
  let crypto1 = Crypto(0, "", "", Some(2))
  let crypto2 = Crypto(..crypto1, rank: Some(1))
  assert Gt == collection.compare_currencies(crypto1, crypto2)
}

pub fn compare_currencies_compares_cryptos_by_name_when_ranks_are_equal_test() {
  let crypto1 = Crypto(0, "A", "", Some(1))
  let crypto2 = Crypto(..crypto1, name: "B", rank: Some(1))
  assert Lt == collection.compare_currencies(crypto1, crypto2)
}

pub fn compare_currencies_compares_cryptos_by_name_when_neither_has_rank_test() {
  let crypto1 = Crypto(0, "A", "", None)
  let crypto2 = Crypto(..crypto1, name: "B", rank: None)
  assert Lt == collection.compare_currencies(crypto1, crypto2)
}

pub fn compare_currencies_compare_fiats_when_both_are_usd_test() {
  let fiat1 = Fiat(0, "", "USD", "")
  let fiat2 = Fiat(..fiat1, id: 1)
  assert Eq == collection.compare_currencies(fiat1, fiat2)
}

pub fn compare_currencies_compare_fiats_when_first_is_usd_test() {
  let fiat1 = Fiat(0, "", "USD", "")
  let fiat2 = Fiat(1, "", "EUR", "")
  assert Lt == collection.compare_currencies(fiat1, fiat2)
}

pub fn compare_currencies_compare_fiats_when_second_is_usd_test() {
  let fiat1 = Fiat(0, "", "EUR", "")
  let fiat2 = Fiat(1, "", "USD", "")
  assert Gt == collection.compare_currencies(fiat1, fiat2)
}

pub fn compare_currencies_non_usd_fiats_ordered_by_name_lexically_test() {
  let fiat1 = Fiat(0, "B", "", "")
  let fiat2 = Fiat(..fiat1, name: "A")
  assert Gt == collection.compare_currencies(fiat1, fiat2)
}
