import gleam/erlang/process.{type Subject}
import server/rates/subscriber.{type RateSubscriber, type SubscriptionResult}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub type SubscriberFactory =
  fn(SubscriptionId, Subject(SubscriptionResult)) -> RateSubscriber

/// Binds a subscriber configuration without starting an actor. Each invocation
/// of the returned function starts a separate subscriber linked to its caller.
pub fn create(config: subscriber.Config) -> SubscriberFactory {
  fn(subscription_id, subject) {
    let assert Ok(rate_subscriber) =
      subscriber.new(subscription_id, subject, config)

    rate_subscriber
  }
}
