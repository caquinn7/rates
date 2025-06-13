import gleam/dict.{type Dict}
import gleam/float
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

pub fn group_by_type(
  currencies: List(Currency),
) -> Dict(CurrencyType, List(Currency)) {
  currencies
  |> list.group(fn(currency) {
    case currency {
      Crypto(..) -> CryptoCurrency
      Fiat(..) -> FiatCurrency
    }
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

pub fn sort_fiats(c1: Currency, c2: Currency) {
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

pub fn format_amount_str(currency: Currency, amount: Float) -> String {
  let amount = float.absolute_value(amount)

  let precision = determine_max_precision(currency, amount)
  let rounded = float.to_precision(amount, precision)
  let rounded_str = float.to_string(rounded)

  let assert [int_str, frac_str] = string.split(rounded_str, ".")
  let int_str = group_digits(int_str)

  let frac_str_all_zeroes =
    frac_str
    |> string.replace("0", "")
    |> string.length
    == 0

  case frac_str_all_zeroes {
    False -> int_str <> "." <> frac_str
    True -> int_str
  }
}

pub fn determine_max_precision(currency: Currency, amount: Float) -> Int {
  case currency {
    Crypto(..) -> {
      case amount {
        a if a == 0.0 -> 0
        a if a >=. 1.0 -> 4
        a if a >=. 0.01 -> 6
        _ -> 8
      }
    }
    Fiat(..) -> 2
  }
}

fn group_digits(int_str: String) -> String {
  int_str
  |> string.to_graphemes
  |> list.reverse
  |> list.sized_chunk(3)
  |> list.map(fn(chunk) {
    chunk
    |> list.reverse
    |> string.join("")
  })
  |> list.reverse
  |> string.join(",")
}
