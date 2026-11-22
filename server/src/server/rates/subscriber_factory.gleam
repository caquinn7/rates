import gleam/erlang/process.{type Subject}
import gleam/otp/actor.{type StartError}
import gleam/result
import server/integrations/coin_market_cap/client as cmc_client
import server/integrations/kraken/client.{type KrakenClient}
import server/rates/internal/kraken_interface
import server/rates/subscriber.{type RateSubscriber, type SubscriptionResult}
import server/rates/subscriber_config.{type SubscriberConfig}
import server/utils/logger.{type Logger}
import shared/currency.{type Currency}
import shared/subscriptions/subscription_id.{type SubscriptionId}

const cmc_conversion_timeout_ms = 3000

const subscription_refresh_interval_ms = 10_000

/// Starts one subscriber linked to the caller and returns its startup result.
pub type SubscriberFactory =
  fn(SubscriptionId, Subject(SubscriptionResult)) ->
    Result(RateSubscriber, StartError)

/// Builds a factory backed by the running Kraken client and CoinMarketCap.
pub fn from_dependencies(
  get_currency: fn(Int) -> Result(Currency, Nil),
  kraken_client: KrakenClient,
  cmc_api_key: String,
  logger: Logger,
) -> Result(SubscriberFactory, String) {
  subscriber_config.new(
    get_currency,
    kraken_interface.new(kraken_client),
    cmc_client.get_conversion(cmc_api_key, _, cmc_conversion_timeout_ms),
    subscription_refresh_interval_ms,
    logger.with_source(logger, "subscriber"),
  )
  |> result.map(from_config)
}

/// Binds a validated subscriber configuration without starting an actor.
pub fn from_config(config: SubscriberConfig) -> SubscriberFactory {
  fn(id, reply_to) { subscriber.new(id, reply_to, config) }
}
