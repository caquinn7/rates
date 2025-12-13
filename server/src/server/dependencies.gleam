import gleam/option.{type Option}
import server/domain/currencies/currency_interface.{type CurrencyInterface}
import server/domain/rates/internal/kraken_interface.{type KrakenInterface}
import server/integrations/coin_market_cap/client.{
  type CmcConversionParameters, type CmcListResponse, type CmcRequestError,
  type CmcResponse,
}
import server/integrations/coin_market_cap/cmc_conversion.{type CmcConversion}
import server/integrations/coin_market_cap/cmc_crypto_currency.{
  type CmcCryptoCurrency,
}
import server/utils/logger.{type Logger}

pub type Dependencies {
  Dependencies(
    currency_interface: CurrencyInterface,
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
