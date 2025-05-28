import gleam/float
import gleam/list
import gleam/string
import shared/currency.{type Currency, Crypto, Fiat}

pub fn format_amount_str(currency: Currency, amount: Float) -> String {
  let amount = float.absolute_value(amount)

  let precision = determine_precision(currency, amount)
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

pub fn determine_precision(currency: Currency, amount: Float) -> Int {
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
