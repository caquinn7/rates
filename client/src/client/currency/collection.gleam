import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/order.{type Order}
import gleam/result
import gleam/string
import shared/currency.{type Currency, Crypto, Fiat}

pub type CurrencyType {
  CryptoCurrency
  FiatCurrency
}

pub fn group(currencies: List(Currency)) -> Dict(CurrencyType, List(Currency)) {
  currencies
  |> list.group(fn(currency) {
    case currency {
      Crypto(..) -> CryptoCurrency
      Fiat(..) -> FiatCurrency
    }
  })
  |> dict.map_values(fn(currency_type, currencies) {
    currencies
    |> list.sort(fn(c1, c2) {
      let assert Ok(order) = case currency_type {
        CryptoCurrency -> sort_cryptos(c1, c2)
        FiatCurrency -> sort_fiats(c1, c2)
      }
      order
    })
  })
}

pub fn sort_cryptos(c1: Currency, c2: Currency) -> Result(Order, Nil) {
  let get_rank = fn(c) {
    case c {
      Crypto(_, _, _, rank) -> Ok(rank)
      _ -> Error(Nil)
    }
  }

  use c1_rank <- result.try(get_rank(c1))
  use c2_rank <- result.try(get_rank(c2))

  case c1_rank, c2_rank {
    Some(_), None -> order.Lt
    None, Some(_) -> order.Gt
    None, None -> string.compare(c1.name, c2.name)
    Some(r1), Some(r2) -> int.compare(r1, r2)
  }
  |> Ok
}

pub fn sort_fiats(c1: Currency, c2: Currency) -> Result(Order, Nil) {
  let is_fiat = fn(c) {
    case c {
      Fiat(..) -> Ok(c)
      _ -> Error(Nil)
    }
  }

  use c1 <- result.try(is_fiat(c1))
  use c2 <- result.try(is_fiat(c2))

  case c1.symbol, c2.symbol {
    "USD", "USD" -> order.Eq
    "USD", _ -> order.Lt
    _, "USD" -> order.Gt
    _, _ -> string.compare(c1.name, c2.name)
  }
  |> Ok
}

pub fn filter(
  currency_list: List(Currency),
  filter_str: String,
) -> List(Currency) {
  let is_match = fn(str) {
    str
    |> string.lowercase
    |> string.contains(string.lowercase(filter_str))
  }

  currency_list
  |> list.filter(fn(currency) {
    is_match(currency.name) || is_match(currency.symbol)
  })
}
