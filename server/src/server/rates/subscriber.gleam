//// Periodically sends exchange-rate results for one client subscription.
////
//// Prefers Kraken's live price store and falls back to CoinMarketCap when a pair
//// or usable price is unavailable. CMC refreshes retry Kraken selection to allow recovery.
////
//// Kraken refreshes use the configured base interval. CMC refreshes use that interval
//// or 30 seconds, whichever is longer. Recovery to Kraken restores the base interval.

import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/erlang/reference.{type Reference}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type Initialised, type Next, type StartError}
import gleam/result
import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/internal/kraken_interface.{type KrakenInterface}
import server/rates/internal/rate_source_strategy.{
  type KrakenFallbackReason, type RateSourceStrategy, CmcStrategy,
  KrakenStrategy, PriceUnavailable, ReciprocalOutOfRange, StrategyConfig,
}
import server/rates/rate_error.{type RateError}
import server/utils/logger.{type Logger}
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

/// Each RateSubscriber instance is associated with a SubscriptionId that
/// uniquely identifies the subscription within that client's session.
pub opaque type RateSubscriber {
  RateSubscriber(id: SubscriptionId, subject: Subject(Msg))
}

/// Dependencies and initial subscription settings for a rate subscriber.
/// Includes currency lookup, Kraken and CMC access, logging, and the base
/// refresh interval in milliseconds.
pub type Config {
  Config(
    get_currency: fn(Int) -> Result(Currency, Nil),
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
    base_refresh_interval_ms: Int,
    logger: Logger,
  )
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

/// Provider dependencies and timing settings shared by message handlers.
/// Created at startup and reused for the lifetime of the subscriber actor.
type Context {
  Context(
    get_currency: fn(Int) -> Result(Currency, Nil),
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
    base_refresh_interval_ms: Int,
  )
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
/// Tracks the active subscription, messaging, logging, and scheduling dependencies.
/// The pending token permits one scheduled refresh; stale tokens are ignored.
type State {
  State(
    /// This actor's handle, attached to results and used to queue refreshes.
    self: RateSubscriber,
    /// Destination for this subscriber's rate responses and errors.
    reply_to: Subject(SubscriptionResult),
    /// Active rate request and the source to use for the next refresh.
    active_subscription: Option(ActiveSubscription),
    /// Logger for diagnostics, including Kraken fallback reasons.
    logger: Logger,
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
/// The base interval must be at least 1000ms. Kraken refreshes use that interval.
/// CMC refreshes wait at least 30 seconds, retaining longer configured intervals.
/// Returns `Error(StartError)` if validation or actor initialization fails.
pub fn new(
  subscription_id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  config: Config,
) -> Result(RateSubscriber, StartError) {
  start(subscription_id, reply_to, config, None)
}

/// Creates a subscriber with custom scheduling, for example a manually advanced
/// scheduler in tests. Source selection and interval policy are unchanged.
pub fn new_with_scheduler(
  subscription_id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  config: Config,
  scheduler: Scheduler,
) -> Result(RateSubscriber, StartError) {
  start(subscription_id, reply_to, config, Some(scheduler))
}

fn start(
  subscription_id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  config: Config,
  scheduler: Option(Scheduler),
) -> Result(RateSubscriber, StartError) {
  let base_refresh_interval_ms = config.base_refresh_interval_ms
  use <- bool.guard(
    base_refresh_interval_ms <= 0,
    Error(actor.InitFailed("Interval must be positive")),
  )
  use <- bool.guard(
    base_refresh_interval_ms < 1000,
    Error(actor.InitFailed("Interval must be at least 1000ms")),
  )

  let context =
    Context(
      get_currency: config.get_currency,
      kraken_interface: config.kraken_interface,
      request_cmc_conversion: config.request_cmc_conversion,
      base_refresh_interval_ms:,
    )

  actor.new_with_initialiser(100, initialiser(
    _,
    subscription_id,
    reply_to,
    config,
    scheduler,
  ))
  |> actor.on_message(fn(state, msg) { handle_msg(context, state, msg) })
  |> actor.start
  |> result.map(fn(started) { started.data })
}

fn initialiser(
  subject: Subject(Msg),
  id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  config: Config,
  scheduler: Option(Scheduler),
) -> Result(Initialised(State, Msg, RateSubscriber), String) {
  let self = RateSubscriber(id:, subject:)
  let state =
    State(
      self:,
      reply_to:,
      active_subscription: None,
      logger: config.logger,
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

fn handle_msg(context: Context, state: State, msg: Msg) -> Next(State, Msg) {
  case msg {
    Subscribe(rate_request) -> handle_subscribe(context, state, rate_request)
    GetLatestRate(refresh_token) ->
      handle_get_latest_rate(context, state, refresh_token)
    Stop -> {
      release_kraken_interest(context, state.active_subscription)
      actor.stop()
    }
  }
}

fn handle_subscribe(
  context: Context,
  state: State,
  rate_request: RateRequest,
) -> Next(State, Msg) {
  release_kraken_interest(context, state.active_subscription)
  let state = State(..state, active_subscription: None, pending_refresh: None)

  let strategy =
    rate_source_strategy.determine_strategy(
      rate_request,
      context.get_currency,
      context.kraken_interface.get_kraken_symbol,
    )

  case strategy {
    Ok(source) -> {
      case source {
        KrakenStrategy(symbol) -> context.kraken_interface.subscribe(symbol)
        CmcStrategy -> Nil
      }

      fetch_reply_and_reschedule(
        context,
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
  context: Context,
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
          handle_subscribe(context, state, subscription.rate_request)
        KrakenStrategy(_) ->
          fetch_reply_and_reschedule(context, state, subscription)
      }
    }

    _, _ -> actor.continue(state)
  }
}

fn release_kraken_interest(
  context: Context,
  subscription: Option(ActiveSubscription),
) -> Nil {
  case subscription {
    Some(ActiveSubscription(_, KrakenStrategy(symbol))) ->
      context.kraken_interface.unsubscribe(symbol)
    _ -> Nil
  }
}

fn fetch_reply_and_reschedule(
  context: Context,
  state: State,
  subscription: ActiveSubscription,
) -> Next(State, Msg) {
  let ActiveSubscription(rate_request:, source:) = subscription
  let config =
    StrategyConfig(
      check_for_kraken_price: context.kraken_interface.check_for_price,
      request_cmc_conversion: context.request_cmc_conversion,
      on_kraken_fallback: log_kraken_fallback(
        state.logger,
        state.self.id,
        rate_request,
        _,
      ),
    )
  let #(result, next_source) =
    rate_source_strategy.execute_strategy(source, rate_request, config)

  process.send(state.reply_to, #(state.self, result))

  case source, next_source {
    KrakenStrategy(symbol), CmcStrategy ->
      context.kraken_interface.unsubscribe(symbol)
    _, _ -> Nil
  }

  let delay_ms = case next_source {
    KrakenStrategy(_) -> context.base_refresh_interval_ms
    CmcStrategy -> int.max(context.base_refresh_interval_ms, 30_000)
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
