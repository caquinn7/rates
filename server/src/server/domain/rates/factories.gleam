import gleam/erlang/process.{type Subject}
import server/dependencies.{type Dependencies}
import server/domain/rates/internal/subscription_manager
import server/domain/rates/rate_error.{type RateError}
import server/domain/rates/rate_service_config.{
  type RateServiceConfig, RateServiceConfig,
}
import server/domain/rates/resolver as rate_resolver
import server/domain/rates/subscriber.{type RateSubscriber} as rate_subscriber
import server/utils/logger
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub type RateSubscriberFactory =
  fn(
    SubscriptionId,
    Subject(#(SubscriptionId, Result(RateResponse, RateError))),
  ) ->
    RateSubscriber

pub fn create_rate_resolver(
  deps: Dependencies,
) -> fn(RateRequest) -> Result(RateResponse, RateError) {
  fn(rate_req) {
    let resolver_config = rate_resolver.Config(create_rate_service_config(deps))
    let assert Ok(resolver) = rate_resolver.new(resolver_config)
    rate_resolver.get_rate(resolver, rate_req, 5000)
  }
}

pub fn create_rate_subscriber_factory(
  deps: Dependencies,
) -> RateSubscriberFactory {
  fn(subscription_id, subject) {
    let assert Ok(subscription_manager) = subscription_manager.new(10_000)

    let subscriber_config =
      rate_subscriber.Config(
        create_rate_service_config(deps),
        subscription_manager:,
        logger: logger.with(deps.logger, "source", "subscriber"),
      )

    let assert Ok(rate_subscriber) =
      rate_subscriber.new(subscription_id, subject, subscriber_config)

    rate_subscriber
  }
}

fn create_rate_service_config(deps: Dependencies) -> RateServiceConfig {
  RateServiceConfig(
    currencies: deps.currencies,
    kraken_interface: deps.kraken_interface,
    request_cmc_conversion: deps.request_cmc_conversion,
    get_current_time_ms: deps.get_current_time_ms,
  )
}
