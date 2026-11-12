import gleam/erlang/process.{type Subject}
import server/dependencies.{type Dependencies}
import server/rates/internal/subscription_manager
import server/rates/rate_error.{type RateError}
import server/rates/subscriber.{type RateSubscriber}
import server/utils/logger
import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub fn create(
  deps: Dependencies,
) -> fn(
  SubscriptionId,
  Subject(#(SubscriptionId, Result(RateResponse, RateError))),
) -> RateSubscriber {
  fn(subscription_id, subject) {
    let assert Ok(subscription_manager) =
      subscription_manager.new(deps.subscription_refresh_interval_ms)

    let subscriber_config =
      subscriber.Config(
        get_currency: deps.currency_repository.get_by_id,
        kraken_interface: deps.kraken_interface,
        request_cmc_conversion: deps.request_cmc_conversion,
        subscription_manager:,
        logger: logger.with(deps.logger, "source", "subscriber"),
      )

    let assert Ok(rate_subscriber) =
      subscriber.new(subscription_id, subject, subscriber_config)

    rate_subscriber
  }
}
