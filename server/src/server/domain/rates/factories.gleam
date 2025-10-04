import gleam/erlang/process.{type Subject}
import server/domain/rates/internal/subscription_manager
import server/domain/rates/rate_error.{type RateError}
import server/domain/rates/rate_service_config.{type RateServiceConfig}
import server/domain/rates/resolver as rate_resolver
import server/domain/rates/subscriber.{type RateSubscriber} as rate_subscriber
import server/utils/logger.{type Logger}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub fn create_rate_resolver(
  rate_service_config: RateServiceConfig,
) -> fn(RateRequest) -> Result(RateResponse, RateError) {
  fn(rate_req) {
    let resolver_config = rate_resolver.Config(rate_service_config)
    let assert Ok(resolver) = rate_resolver.new(resolver_config)
    rate_resolver.get_rate(resolver, rate_req, 5000)
  }
}

pub fn create_rate_subscriber_factory(
  rate_service_config: RateServiceConfig,
  logger: Logger,
) -> fn(
  SubscriptionId,
  Subject(#(SubscriptionId, Result(RateResponse, RateError))),
) ->
  RateSubscriber {
  fn(subscription_id, subject) {
    let assert Ok(subscription_manager) = subscription_manager.new(10_000)

    let subscriber_config =
      rate_subscriber.Config(
        rate_service_config,
        subscription_manager:,
        logger: logger.with(logger, "source", "subscriber"),
      )

    let assert Ok(rate_subscriber) =
      rate_subscriber.new(subscription_id, subject, subscriber_config)

    rate_subscriber
  }
}
