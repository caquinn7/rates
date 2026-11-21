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
import server/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/rates/internal/kraken_interface.{type KrakenInterface}
import server/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/rates/internal/rate_source_strategy.{
  type KrakenFallbackReason, type RateSourceStrategy, CmcStrategy,
  KrakenStrategy, PriceUnavailable, ReciprocalOutOfRange, StrategyConfig,
}
import server/rates/internal/subscription_manager.{
  type SubscriptionManager, Cmc, Kraken,
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
/// Includes currency lookup, Kraken and CMC access, logging, and a subscription
/// manager that determines refresh intervals.
pub type Config {
  Config(
    get_currency: fn(Int) -> Result(Currency, Nil),
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
    subscription_manager: SubscriptionManager,
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

/// Fixed provider dependencies shared by message handlers.
/// Created at startup and reused for the lifetime of the subscriber actor.
type Context {
  Context(
    get_currency: fn(Int) -> Result(Currency, Nil),
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
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
    /// Active rate request, selected source, and refresh interval policy.
    subscription_manager: SubscriptionManager,
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
/// Kraken refreshes use the configured base interval. CMC refreshes wait at least
/// 30 seconds, retaining longer configured intervals. Returns `Error(StartError)`
/// if actor initialization fails.
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
  let context =
    Context(
      get_currency: config.get_currency,
      kraken_interface: config.kraken_interface,
      request_cmc_conversion: config.request_cmc_conversion,
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
      subscription_manager: config.subscription_manager,
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
    Stop -> handle_stop(state, context.kraken_interface.unsubscribe)
  }
}

fn handle_subscribe(
  context: Context,
  state: State,
  rate_request: RateRequest,
) -> Next(State, Msg) {
  let state = State(..state, pending_refresh: None)
  let state =
    cleanup_existing_subscription(state, context.kraken_interface.unsubscribe)

  let strategy =
    rate_source_strategy.determine_strategy(
      rate_request,
      context.get_currency,
      context.kraken_interface.get_kraken_symbol,
    )

  case strategy {
    Ok(strategy) -> {
      // Record acquired interest before looking up a price, so an immediate
      // fallback can release it even when there was no previous subscription.
      let state = case strategy {
        KrakenStrategy(symbol) -> {
          context.kraken_interface.subscribe(symbol)
          update_subscription_manager(state, strategy, rate_request)
        }
        CmcStrategy -> state
      }

      fetch_reply_and_reschedule(context, state, rate_request, strategy)
    }

    Error(error) -> {
      process.send(state.reply_to, #(state.self, Error(error)))
      actor.continue(clear_subscription_from_state(state))
    }
  }
}

fn handle_get_latest_rate(
  context: Context,
  state: State,
  refresh_token: Reference,
) -> Next(State, Msg) {
  let subscription =
    subscription_manager.get_subscription(state.subscription_manager)

  // Tokens identify individual refreshes, even when the subscription is unchanged.
  case state.pending_refresh, subscription {
    Some(pending), Some(current_subscription) if pending == refresh_token -> {
      let state = State(..state, pending_refresh: None)

      case current_subscription {
        // Retry the preferred source at each fallback refresh. The normal subscribe
        // path retains interest on success and releases it again if the probe fails.
        Cmc(rate_request) -> handle_subscribe(context, state, rate_request)

        Kraken(rate_request, symbol) ->
          fetch_reply_and_reschedule(
            context,
            state,
            rate_request,
            KrakenStrategy(symbol),
          )
      }
    }

    _, _ -> actor.continue(state)
  }
}

fn handle_stop(
  state: State,
  unsubscribe_from_kraken: fn(KrakenSymbol) -> Nil,
) -> Next(State, Msg) {
  let subscription =
    subscription_manager.get_subscription(state.subscription_manager)

  case subscription {
    Some(Kraken(_, symbol)) -> unsubscribe_from_kraken(symbol)
    _ -> Nil
  }

  actor.stop()
}

fn fetch_reply_and_reschedule(
  context: Context,
  state: State,
  rate_request: RateRequest,
  strategy: RateSourceStrategy,
) -> Next(State, Msg) {
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
  let #(result, should_downgrade) =
    rate_source_strategy.execute_strategy(strategy, rate_request, config)

  process.send(state.reply_to, #(state.self, result))

  let state = case should_downgrade {
    True ->
      downgrade_to_fallback(
        state,
        rate_request,
        context.kraken_interface.unsubscribe,
      )
    False -> update_subscription_manager(state, strategy, rate_request)
  }
  actor.continue(schedule_next_update(state))
}

fn downgrade_to_fallback(
  state: State,
  rate_request: RateRequest,
  unsubscribe_from_kraken: fn(KrakenSymbol) -> Nil,
) -> State {
  let subscription =
    subscription_manager.get_subscription(state.subscription_manager)

  case subscription {
    Some(Kraken(_, symbol)) -> unsubscribe_from_kraken(symbol)
    _ -> Nil
  }

  let subscription_manager =
    subscription_manager.set_subscription(
      state.subscription_manager,
      Cmc(rate_request),
    )
  State(..state, subscription_manager:)
}

fn cleanup_existing_subscription(
  state: State,
  unsubscribe_from_kraken: fn(KrakenSymbol) -> Nil,
) -> State {
  let subscription =
    subscription_manager.get_subscription(state.subscription_manager)

  case subscription {
    Some(Kraken(_, old_symbol)) -> {
      unsubscribe_from_kraken(old_symbol)
      clear_subscription_from_state(state)
    }

    _ -> state
  }
}

fn clear_subscription_from_state(state: State) -> State {
  State(
    ..state,
    pending_refresh: None,
    subscription_manager: subscription_manager.clear_subscription(
      state.subscription_manager,
    ),
  )
}

fn update_subscription_manager(
  state: State,
  strategy: RateSourceStrategy,
  rate_request: RateRequest,
) -> State {
  let subscription = case strategy {
    KrakenStrategy(symbol) -> Kraken(rate_request, symbol)
    CmcStrategy -> Cmc(rate_request)
  }

  let subscription_manager =
    subscription_manager.set_subscription(
      state.subscription_manager,
      subscription,
    )

  State(..state, subscription_manager:)
}

fn schedule_next_update(state: State) -> State {
  let assert Some(_) =
    subscription_manager.get_subscription(state.subscription_manager)

  let refresh_token = reference.new()
  let delay =
    subscription_manager.get_current_interval(state.subscription_manager)

  case state.scheduler {
    Some(schedule) ->
      schedule(delay, fn() {
        actor.send(state.self.subject, GetLatestRate(refresh_token))
      })

    None -> {
      let _ =
        process.send_after(
          state.self.subject,
          delay,
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
