import gleam/option.{type Option, Some}
import gleam/result
import server/currencies/cmc_currency_handler.{type FetchError}
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/integrations/coin_market_cap/client.{
  type CmcListResponse, type CmcRequestError,
}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}

pub fn create(
  currency_repository: CurrencyRepository,
  request_cmc_cryptos: fn(Option(String)) ->
    Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
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
