// import gleam/result
// import gleam/string

// pub opaque type CurrencyPair {
//   CurrencyPair(base: String, quote: String)
// }

// pub fn new(base: String, quote: String) -> Result(CurrencyPair, Nil) {
//   let validate_str = fn(str) {
//     case string.is_empty(str) {
//       False -> Ok(string.trim(str))
//       True -> Error(Nil)
//     }
//   }

//   use base <- result.try(validate_str(base))
//   use quote <- result.try(validate_str(quote))
//   Ok(CurrencyPair(base:, quote:))
// }

// pub fn to_symbol(currency_pair: CurrencyPair) -> String {
//   currency_pair.base <> "/" <> currency_pair.quote
// }
