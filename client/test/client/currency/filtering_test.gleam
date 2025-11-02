import client/currency/filtering
import gleam/list
import gleam/option.{None, Some}
import shared/currency.{Crypto, Fiat}

pub fn currency_matches_filter_returns_true_when_symbol_matches_test() {
  let bitcoin = Crypto(1, "BTC", "Bitcoin", None)

  assert filtering.currency_matches_filter(bitcoin, "BTC") == True
  assert filtering.currency_matches_filter(bitcoin, "btc") == True
  assert filtering.currency_matches_filter(bitcoin, "TC") == True
}

pub fn currency_matches_filter_returns_true_when_name_matches_test() {
  let bitcoin = Crypto(1, "BTC", "Bitcoin", None)

  assert filtering.currency_matches_filter(bitcoin, "Bitcoin") == True
  assert filtering.currency_matches_filter(bitcoin, "bitcoin") == True
  assert filtering.currency_matches_filter(bitcoin, "coin") == True
}

pub fn currency_matches_filter_returns_false_when_no_match_test() {
  let bitcoin = Crypto(1, "BTC", "Bitcoin", None)

  assert filtering.currency_matches_filter(bitcoin, "ETH") == False
  assert filtering.currency_matches_filter(bitcoin, "Ethereum") == False
  assert filtering.currency_matches_filter(bitcoin, "xyz") == False
}

pub fn currency_matches_filter_works_with_fiat_test() {
  let usd = Fiat(2781, "US Dollar", "USD", "$")

  assert filtering.currency_matches_filter(usd, "USD") == True
  assert filtering.currency_matches_filter(usd, "Dollar") == True
  assert filtering.currency_matches_filter(usd, "us") == True
  assert filtering.currency_matches_filter(usd, "EUR") == False
}

pub fn get_default_currencies_returns_top_5_cryptos_plus_usd_test() {
  let currencies = [
    Crypto(1, "BTC", "Bitcoin", Some(1)),
    Crypto(2, "ETH", "Ethereum", Some(2)),
    Crypto(3, "USDT", "Tether", Some(3)),
    Crypto(4, "BNB", "BNB", Some(4)),
    Crypto(5, "SOL", "Solana", Some(5)),
    // rank 6 - should be excluded
    Crypto(6, "USDC", "USD Coin", Some(6)),
    // rank 7 - should be excluded
    Crypto(7, "XRP", "XRP", Some(7)),
    // USD - should be included
    Fiat(2781, "US Dollar", "USD", "$"),
    // EUR - should be excluded
    Fiat(2782, "Euro", "EUR", "€"),
  ]

  let expected = [
    Crypto(1, "BTC", "Bitcoin", Some(1)),
    Crypto(2, "ETH", "Ethereum", Some(2)),
    Crypto(3, "USDT", "Tether", Some(3)),
    Crypto(4, "BNB", "BNB", Some(4)),
    Crypto(5, "SOL", "Solana", Some(5)),
    Fiat(2781, "US Dollar", "USD", "$"),
  ]

  assert filtering.get_default_currencies(currencies) == expected
}

pub fn get_default_currencies_handles_fewer_than_5_cryptos_test() {
  let currencies = [
    Crypto(1, "BTC", "Bitcoin", Some(1)),
    Crypto(2, "ETH", "Ethereum", Some(2)),
    Fiat(2781, "US Dollar", "USD", "$"),
  ]

  let expected = [
    Crypto(1, "BTC", "Bitcoin", Some(1)),
    Crypto(2, "ETH", "Ethereum", Some(2)),
    Fiat(2781, "US Dollar", "USD", "$"),
  ]

  assert filtering.get_default_currencies(currencies) == expected
}

pub fn get_default_currencies_handles_no_usd_test() {
  let currencies = [
    Crypto(1, "BTC", "Bitcoin", Some(1)),
    Crypto(2, "ETH", "Ethereum", Some(2)),
    Fiat(2782, "Euro", "EUR", "€"),
  ]

  let expected = [
    Crypto(1, "BTC", "Bitcoin", Some(1)),
    Crypto(2, "ETH", "Ethereum", Some(2)),
  ]

  assert filtering.get_default_currencies(currencies) == expected
}

pub fn get_default_currencies_handles_empty_list_test() {
  let currencies = []

  let result = filtering.get_default_currencies(currencies)

  assert list.is_empty(result)
}
