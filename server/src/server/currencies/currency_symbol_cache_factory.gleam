import gleam/option.{type Option, Some}
import gleam/result
import server/currencies/cmc_currency_handler.{type FetchError}
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/integrations/coin_market_cap/client.{
  type CmcRequestError, type CmcResponse,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}

/// Requests cryptocurrencies with an optional symbol filter. The API key and
/// result limit are already bound; `None` requests an unfiltered listing.
pub type RequestCmcCryptosBySymbol =
  fn(Option(String)) ->
    Result(CmcResponse(List(CmcCryptoCurrency)), CmcRequestError)

/// Creates a symbol cache backed by `currency_repository` and CoinMarketCap.
///
/// Cache hits read the repository directly; misses are serialized and fetched via
/// `request_cmc_cryptos(Some(symbol))`. Successful results are inserted before
/// being returned. The repository must support concurrent reads and make inserts
/// visible to subsequent lookups.
///
/// Fetch failures are passed to `on_fetch_failed` and returned to lookup callers
/// as `Error(Nil)`. Panics if the cache actor cannot be started.
pub fn create(
  currency_repository: CurrencyRepository,
  request_cmc_cryptos: RequestCmcCryptosBySymbol,
  on_fetch_failed: fn(FetchError) -> Nil,
) -> CurrencySymbolCache {
  let get_cached = currency_repository.get_by_symbol

  let fetch_and_cache = fn(symbol) {
    let request_cryptos = fn() { request_cmc_cryptos(Some(symbol)) }

    request_cryptos
    |> cmc_currency_handler.get_cryptos
    |> result.map(fn(currencies) {
      currency_repository.insert(currencies)
      currencies
    })
    |> result.map_error(on_fetch_failed)
  }

  let assert Ok(currency_symbol_cache) =
    currency_symbol_cache.new(get_cached, fetch_and_cache)

  currency_symbol_cache
}
