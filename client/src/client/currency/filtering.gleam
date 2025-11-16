import client/currency/collection as currency_collection
import gleam/list
import gleam/string
import shared/currency.{type Currency, Crypto, Fiat}

pub fn get_default_currencies(all_currencies: List(Currency)) -> List(Currency) {
  // want top 5 ranked cryptos
  let cryptos =
    all_currencies
    |> list.filter(fn(currency) {
      case currency {
        Crypto(..) -> True
        Fiat(..) -> False
      }
    })
    |> list.sort(currency_collection.compare_currencies)
    |> list.take(5)

  // just want USD
  let fiats =
    all_currencies
    |> list.filter(fn(currency) { currency.id == 2781 })

  cryptos
  |> list.append(fiats)
}

pub fn currency_matches_filter(currency: Currency, filter_str: String) -> Bool {
  let is_match = fn(str) {
    str
    |> string.lowercase
    |> string.contains(string.lowercase(filter_str))
  }

  is_match(currency.name) || is_match(currency.symbol)
}
