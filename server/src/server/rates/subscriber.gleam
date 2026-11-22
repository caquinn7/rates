//// Periodically sends exchange-rate results for one client subscription.
////
//// Prefers Kraken's live price store and falls back to CoinMarketCap when a pair
//// or usable price is unavailable. CMC refreshes retry Kraken selection to allow recovery.
////
//// Kraken refreshes use the configured base interval. CMC refreshes use that interval
//// or 30 seconds, whichever is longer. Recovery to Kraken restores the base interval.

import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type Initialised, type Next, type StartError}
import gleam/result
import server/rates/internal/rate_source_strategy.{
  type KrakenFallbackReason, type RateSourceStrategy, CmcStrategy,
  KrakenStrategy, PriceUnavailable, ReciprocalOutOfRange, StrategyConfig,
}
import server/rates/rate_error.{type RateError}
import server/rates/subscriber_config.{type SubscriberConfig}
import server/utils/logger.{type Logger}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

/// Each RateSubscriber instance is associated with a SubscriptionId that
/// uniquely identifies the subscription within that client's session.
pub opaque type RateSubscriber {
  RateSubscriber(id: SubscriptionId, subject: Subject(Msg))
}

/// A rate result paired with the handle of the subscriber that produced it.
pub type SubscriptionResult =
  #(RateSubscriber, Result(RateResponse, RateError))

/// Schedules an update by invoking its delivery callback after a delay in milliseconds.
/// The callback enqueues the update on the actor; it never handles it directly.
pub type Scheduler =
  fn(Int, fn() -> Nil) -> Nil

/// Messages handled by the rate subscriber actor.
type Msg {
  /// Requests a currency pair, replacing any previous subscription.
  Subscribe(RateRequest)

  /// Triggers a scheduled refresh if the reference matches the pending token.
  /// Stale or previously consumed tokens are ignored.
  GetLatestRate(Reference)

  /// Releases active Kraken interest and stops the actor.
  Stop
}

/// A validated conversion request and its current quote source.
type ActiveSubscription {
  ActiveSubscription(
    /// The source and target currency IDs for the requested conversion.
    rate_request: RateRequest,
    /// Determines the refresh interval. For Kraken, carries the resolved pair
    /// and price direction. A CoinMarketCap refresh reruns source selection.
    source: RateSourceStrategy,
  )
}

/// Runtime state owned by the subscriber actor.
/// Tracks the active subscription, messaging, and scheduling.
/// The pending token permits one scheduled refresh; stale tokens are ignored.
type State {
  State(
    /// This actor's handle, attached to results and used to queue refreshes.
    self: RateSubscriber,
    /// Destination for this subscriber's rate responses and errors.
    reply_to: Subject(SubscriptionResult),
    /// Active rate request and the source to use for the next refresh.
    active_subscription: Option(ActiveSubscription),
    /// Scheduling override; `None` uses `process.send_after`.
    scheduler: Option(Scheduler),
    /// Token identifying the next valid refresh. Old timers may still fire after
    /// resubscribing; their tokens no longer match and their messages are ignored.
    /// Consumed before fetching so a callback cannot trigger a second fetch.
    /// `None` means no refresh is currently valid.
    pending_refresh: Option(Reference),
  )
}

/// Starts an actor; call `subscribe` to begin fetching a currency pair.
/// Sends results to `reply_to` paired with the returned subscriber handle.
///
/// Kraken refreshes use the base interval from the validated config.
/// CMC refreshes wait at least 30 seconds, retaining longer configured intervals.
/// Returns `Error(StartError)` if actor initialization fails.
pub fn new(
  subscription_id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  config: SubscriberConfig,
) -> Result(RateSubscriber, StartError) {
  start(subscription_id, reply_to, config, None)
}

/// Creates a subscriber with custom scheduling, for example a manually advanced
/// scheduler in tests. Source selection and interval policy are unchanged.
pub fn new_with_scheduler(
  subscription_id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  config: SubscriberConfig,
  scheduler: Scheduler,
) -> Result(RateSubscriber, StartError) {
  start(subscription_id, reply_to, config, Some(scheduler))
}

fn start(
  subscription_id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  config: SubscriberConfig,
  scheduler: Option(Scheduler),
) -> Result(RateSubscriber, StartError) {
  actor.new_with_initialiser(100, initialiser(
    _,
    subscription_id,
    reply_to,
    scheduler,
  ))
  |> actor.on_message(fn(state, msg) { handle_msg(config, state, msg) })
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn initialiser(
  subject: Subject(Msg),
  id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  scheduler: Option(Scheduler),
) -> Result(Initialised(State, Msg, RateSubscriber), String) {
  let self = RateSubscriber(id:, subject:)
  let state =
    State(
      self:,
      reply_to:,
      active_subscription: None,
      scheduler:,
      pending_refresh: None,
    )

  state
  |> actor.initialised
  |> actor.returning(self)
  |> Ok
}

/// Returns the client-supplied ID associated with this subscriber.
pub fn subscription_id(rate_subscriber: RateSubscriber) -> SubscriptionId {
  rate_subscriber.id
}

/// Queues a request to fetch and periodically refresh a currency pair,
/// replacing the subscriber's previous request.
pub fn subscribe(subscriber: RateSubscriber, rate_request: RateRequest) -> Nil {
  actor.send(subscriber.subject, Subscribe(rate_request))
}

/// Queues a stop request, releasing any active Kraken subscription before exit.
pub fn stop(subscriber: RateSubscriber) -> Nil {
  actor.send(subscriber.subject, Stop)
}

fn handle_msg(
  config: SubscriberConfig,
  state: State,
  msg: Msg,
) -> Next(State, Msg) {
  case msg {
    Subscribe(rate_request) -> handle_subscribe(config, state, rate_request)
    GetLatestRate(refresh_token) ->
      handle_get_latest_rate(config, state, refresh_token)
    Stop -> {
      release_kraken_interest(config, state.active_subscription)
      actor.stop()
    }
  }
}

fn handle_subscribe(
  config: SubscriberConfig,
  state: State,
  rate_request: RateRequest,
) -> Next(State, Msg) {
  release_kraken_interest(config, state.active_subscription)
  let state = State(..state, active_subscription: None, pending_refresh: None)
  let kraken = subscriber_config.get_kraken_interface(config)

  let strategy =
    rate_source_strategy.determine_strategy(
      rate_request,
      subscriber_config.get_currency_lookup(config),
      kraken.get_kraken_symbol,
    )

  case strategy {
    Ok(source) -> {
      case source {
        KrakenStrategy(symbol) -> kraken.subscribe(symbol)
        CmcStrategy -> Nil
      }

      fetch_reply_and_reschedule(
        config,
        state,
        ActiveSubscription(rate_request, source),
      )
    }

    Error(error) -> {
      process.send(state.reply_to, #(state.self, Error(error)))
      actor.continue(state)
    }
  }
}

fn handle_get_latest_rate(
  config: SubscriberConfig,
  state: State,
  refresh_token: Reference,
) -> Next(State, Msg) {
  // Tokens identify individual refreshes, even when the subscription is unchanged.
  case state.pending_refresh, state.active_subscription {
    Some(pending), Some(subscription) if pending == refresh_token -> {
      let state = State(..state, pending_refresh: None)

      case subscription.source {
        // Retry source selection at each CoinMarketCap refresh so Kraken can recover.
        CmcStrategy ->
          handle_subscribe(config, state, subscription.rate_request)
        KrakenStrategy(_) ->
          fetch_reply_and_reschedule(config, state, subscription)
      }
    }

    _, _ -> actor.continue(state)
  }
}

fn release_kraken_interest(
  config: SubscriberConfig,
  subscription: Option(ActiveSubscription),
) -> Nil {
  case subscription {
    Some(ActiveSubscription(_, KrakenStrategy(symbol))) -> {
      let kraken = subscriber_config.get_kraken_interface(config)
      kraken.unsubscribe(symbol)
    }
    _ -> Nil
  }
}

fn fetch_reply_and_reschedule(
  config: SubscriberConfig,
  state: State,
  subscription: ActiveSubscription,
) -> Next(State, Msg) {
  let ActiveSubscription(rate_request:, source:) = subscription
  let kraken = subscriber_config.get_kraken_interface(config)
  let strategy_config =
    StrategyConfig(
      check_for_kraken_price: kraken.check_for_price,
      request_cmc_conversion: subscriber_config.get_cmc_conversion_fetcher(
        config,
      ),
      on_kraken_fallback: log_kraken_fallback(
        subscriber_config.get_logger(config),
        state.self.id,
        rate_request,
        _,
      ),
    )
  let #(result, next_source) =
    rate_source_strategy.execute_strategy(source, rate_request, strategy_config)

  process.send(state.reply_to, #(state.self, result))

  case source, next_source {
    KrakenStrategy(symbol), CmcStrategy -> kraken.unsubscribe(symbol)
    _, _ -> Nil
  }

  let base_refresh_interval_ms =
    subscriber_config.get_base_refresh_interval_ms(config)
  let delay_ms = case next_source {
    KrakenStrategy(_) -> base_refresh_interval_ms
    CmcStrategy -> int.max(base_refresh_interval_ms, 30_000)
  }
  let active_subscription = Some(ActiveSubscription(rate_request, next_source))

  State(..state, active_subscription:)
  |> schedule_next_update(delay_ms)
  |> actor.continue
}

fn schedule_next_update(state: State, delay_ms: Int) -> State {
  let refresh_token = reference.new()

  case state.scheduler {
    Some(schedule) ->
      schedule(delay_ms, fn() {
        actor.send(state.self.subject, GetLatestRate(refresh_token))
      })

    None -> {
      let _ =
        process.send_after(
          state.self.subject,
          delay_ms,
          GetLatestRate(refresh_token),
        )
      Nil
    }
  }

  State(..state, pending_refresh: Some(refresh_token))
}

fn log_kraken_fallback(
  logger: Logger,
  subscription_id: SubscriptionId,
  rate_req: RateRequest,
  reason: KrakenFallbackReason,
) -> Nil {
  let message = case reason {
    PriceUnavailable ->
      "Timed out waiting for kraken price. Falling back to CMC"
    ReciprocalOutOfRange ->
      "Reversed Kraken price is out of range. Falling back to CMC"
  }

  logger
  |> logger.with("subscription_id", subscription_id.to_string(subscription_id))
  |> logger.with("rate_request.from", int.to_string(rate_req.from))
  |> logger.with("rate_request.to", int.to_string(rate_req.to))
  |> logger.warning(message)
}
