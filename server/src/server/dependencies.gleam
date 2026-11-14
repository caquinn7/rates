import server/currencies/currency_repository.{type CurrencyRepository}
import server/currencies/currency_symbol_cache.{type CurrencySymbolCache}
import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/internal/kraken_interface.{type KrakenInterface}
import server/utils/logger.{type Logger}

pub type Dependencies {
  Dependencies(
    currency_repository: CurrencyRepository,
    currency_symbol_cache: CurrencySymbolCache,
    subscription_refresh_interval_ms: Int,
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
    logger: Logger,
  )
}
