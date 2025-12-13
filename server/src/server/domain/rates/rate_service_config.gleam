import server/domain/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/domain/rates/internal/kraken_interface.{type KrakenInterface}
import shared/currency.{type Currency}

/// Contains the common dependencies needed by both subscriber and resolver
pub type RateServiceConfig {
  RateServiceConfig(
    get_currency: fn(Int) -> Result(Currency, Nil),
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
    get_current_time_ms: fn() -> Int,
  )
}
