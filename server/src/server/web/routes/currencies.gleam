import gleam/bool
import gleam/json
import gleam/list
import gleam/regexp
import gleam/result
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import shared/currency
import wisp

/// Returns currencies matching the `symbol` query parameter as a JSON array.
///
/// Requires a nonempty ASCII alphanumeric symbol, passed to the cache unchanged.
/// Returns 400 for missing or invalid symbols, or 500 if the lookup fails.
/// HTTP method enforcement is handled by the router.
pub fn get(req: wisp.Request, cache: CurrencySymbolCache) -> wisp.Response {
  let symbol =
    req
    |> wisp.get_query
    |> list.key_find("symbol")
    |> result.unwrap("")

  use <- bool.lazy_guard(symbol == "", fn() {
    wisp.response(400)
    |> wisp.json_body("{\"error\": \"Query parameter 'symbol' is required.\"}")
  })

  // Erlang's `$` can match before a final newline; require the whole string.
  let assert Ok(re) = regexp.from_string("\\A[a-zA-Z0-9]+\\z")
  let symbol_valid = regexp.check(re, symbol)
  use <- bool.lazy_guard(!symbol_valid, fn() {
    wisp.response(400)
    |> wisp.json_body(
      "{\"error\": \"'symbol' should only include one or more alphanumeric characters.\"}",
    )
  })

  case currency_symbol_cache.get_by_symbol(cache, symbol) {
    Ok(currencies) ->
      currencies
      |> json.array(currency.encode)
      |> json.to_string
      |> wisp.json_response(200)
    Error(_) -> wisp.internal_server_error()
  }
}
