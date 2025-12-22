import gleam/option.{type Option}
import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/integrations/coin_market_cap/client.{
  type CmcConversionParameters, type CmcListResponse, type CmcRequestError,
  type CmcResponse,
}
import server/integrations/coin_market_cap/cmc_conversion.{type CmcConversion}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}
import server/rates/internal/kraken_interface.{type KrakenInterface}
import server/utils/logger.{type Logger}

pub type Dependencies {
  Dependencies(
    currency_repository: CurrencyRepository,
    currency_symbol_cache: CurrencySymbolCache,
    subscription_refresh_interval_ms: Int,
    kraken_interface: KrakenInterface,
    request_cmc_cryptos: fn(Option(String)) ->
      Result(CmcListResponse(CmcCryptoCurrency), CmcRequestError),
    request_cmc_conversion: fn(CmcConversionParameters) ->
      Result(CmcResponse(CmcConversion), CmcRequestError),
    get_current_time_ms: fn() -> Int,
    logger: Logger,
  )
}
