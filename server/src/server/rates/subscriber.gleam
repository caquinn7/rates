//// This module implements an actor-based system for fetching and streaming currency exchange rates
////
//// ## Features
////
//// - **Multi-source support**: Primary data from Kraken WebSocket, fallback to CoinMarketCap API
//// - **Automatic fallback**: Seamlessly switches between data sources based on availability
//// - **Rate limiting**: Update frequency capped at 30s for CMC, configurable for Kraken
//// - **Real-time updates**: WebSocket-based live price feeds when available
////
//// ## Data Source Priority
////
//// 1. **Kraken WebSocket** (preferred): Real-time, low-latency updates
//// 2. **CoinMarketCap API** (fallback): Rate-limited but comprehensive coverage
////
//// ## Interval Behavior
////
//// - **Kraken subscriptions**: Use the configured base interval
//// - **CMC subscriptions**: Capped at 30 seconds due to API rate limits
//// - **Transitions**: Automatically restore optimal intervals when switching back to Kraken

import gleam/bool
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
  type RateSourceStrategy, CmcStrategy, KrakenStrategy, StrategyConfig,
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

pub type Config {
  Config(
    get_currency: fn(Int) -> Result(Currency, Nil),
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
    subscription_manager: SubscriptionManager,
    logger: Logger,
  )
}

pub type SubscriptionResult =
  #(SubscriptionId, Result(RateResponse, RateError))

/// Schedule an update by arranging to invoke its delivery callback after a delay.
/// The callback enqueues the update on the actor; it never handles it directly.
pub type Scheduler =
  fn(Int, fn() -> Nil) -> Nil

type Msg {
  Subscribe(RateRequest)
  GetLatestRate(Reference)
  Stop
}

type Context {
  Context(
    subscription_id: SubscriptionId,
    get_currency: fn(Int) -> Result(Currency, Nil),
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
  )
}

type State {
  State(
    self: Subject(Msg),
    reply_to: Subject(SubscriptionResult),
    subscription_manager: SubscriptionManager,
    logger: Logger,
    scheduler: Option(Scheduler),
    pending_refresh: Option(Reference),
  )
}

/// Creates a new RateSubscriber actor that periodically fetches currency rates.
///
/// This function initializes a new actor with the provided configuration and starts it.
/// The actor will handle rate subscription messages and communicate conversion results
/// back through the provided reply subject as a tuple containing the subscription Id
/// and the rate response or error.
///
/// ## Parameters
///
/// - `subscription_id`: Unique identifier for this subscription
/// - `reply_to`: Subject to send tuples of (subscription_id, rate_response_or_error) back to the caller
/// - `config`: Configuration containing all necessary dependencies and settings
///
/// ## Returns
///
/// Returns `Ok(RateSubscriber)` if the actor is successfully created and started,
/// or `Error(StartError)` if actor initialization fails.
///
/// ## Note
///
/// When using CoinMarketCap as the data source, the update interval will be
/// automatically capped at 30 seconds due to API rate limits, regardless of the
/// configured base interval in the subscription manager.
///
/// The reply subject will receive tuples in the format:
/// `#(subscription_id, Ok(rate_response))` for successful rate fetches
/// `#(subscription_id, Error(rate_error))` for failed rate fetches
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
      subscription_id:,
      get_currency: config.get_currency,
      kraken_interface: config.kraken_interface,
      request_cmc_conversion: config.request_cmc_conversion,
    )

  actor.new_with_initialiser(100, initialiser(_, reply_to, config, scheduler))
  |> actor.on_message(fn(state, msg) { handle_msg(context, state, msg) })
  |> actor.start
  |> result.map(fn(started) { RateSubscriber(subscription_id, started.data) })
}

fn initialiser(
  self: Subject(Msg),
  reply_to: Subject(SubscriptionResult),
  config: Config,
  scheduler: Option(Scheduler),
) -> Result(Initialised(State, Msg, Subject(Msg)), String) {
  let state =
    State(
      self:,
      reply_to:,
      subscription_manager: config.subscription_manager,
      logger: config.logger,
      scheduler:,
      pending_refresh: None,
    )

  let selector =
    process.new_selector()
    |> process.select(self)

  state
  |> actor.initialised
  |> actor.selecting(selector)
  |> actor.returning(self)
  |> Ok
}

pub fn subscription_id(rate_subscriber: RateSubscriber) {
  rate_subscriber.id
}

/// Subscribes a rate subscriber to receive updates for a specific rate request.
///
/// This function sends a subscription message to the subscriber actor, which will
/// begin receiving rate updates that match the provided rate request criteria.
///
/// ## Parameters
/// - `subscriber`: The `RateSubscriber` containing the actor subject to send the subscription to
/// - `rate_request`: The `RateRequest` specifying which currency pair to subscribe to
///
/// ## Returns
/// `Nil` - This function performs a side effect by sending a message to an actor
pub fn subscribe(subscriber: RateSubscriber, rate_request: RateRequest) -> Nil {
  actor.send(subscriber.subject, Subscribe(rate_request))
}

/// Stops a rate subscriber actor by sending a Stop message to it.
///
/// ## Parameters
/// - `subscriber`: The RateSubscriber instance to stop
///
/// ## Returns
/// `Nil` - This function performs a side effect by sending a message to an actor
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

// message handler functions

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
      process.send(state.reply_to, #(context.subscription_id, Error(error)))
      actor.continue(clear_subscription_from_state(state))
    }
  }
}

fn handle_get_latest_rate(
  context: Context,
  state: State,
  refresh_token: Reference,
) -> Next(State, Msg) {
  // Tokens identify individual refreshes, even when the subscription is unchanged.
  use <- bool.guard(
    state.pending_refresh != Some(refresh_token),
    actor.continue(state),
  )

  let subscription =
    subscription_manager.get_subscription(state.subscription_manager)

  use <- bool.guard(option.is_none(subscription), actor.continue(state))

  let assert Some(current_subscription) = subscription
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
      on_kraken_fallback: fn() {
        log_wait_for_kraken_price_timeout(
          state.logger,
          context.subscription_id,
          rate_request,
        )
      },
    )
  let #(result, should_downgrade) =
    rate_source_strategy.execute_strategy(strategy, rate_request, config)

  process.send(state.reply_to, #(context.subscription_id, result))

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
    subscription_manager.create_cmc_subscription(
      state.subscription_manager,
      rate_request,
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
  let subscription_manager = case strategy {
    KrakenStrategy(symbol) ->
      subscription_manager.create_kraken_subscription(
        state.subscription_manager,
        rate_request,
        symbol,
      )

    CmcStrategy ->
      subscription_manager.create_cmc_subscription(
        state.subscription_manager,
        rate_request,
      )
  }

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
        actor.send(state.self, GetLatestRate(refresh_token))
      })
    None -> {
      let _ =
        process.send_after(state.self, delay, GetLatestRate(refresh_token))
      Nil
    }
  }

  State(..state, pending_refresh: Some(refresh_token))
}

// logging

fn log_wait_for_kraken_price_timeout(
  logger: Logger,
  subscription_id: SubscriptionId,
  rate_req: RateRequest,
) -> Nil {
  logger
  |> logger.with("subscription_id", subscription_id.to_string(subscription_id))
  |> logger.with("rate_request.from", int.to_string(rate_req.from))
  |> logger.with("rate_request.to", int.to_string(rate_req.to))
  |> logger.warning("Timed out waiting for kraken price. Falling back to CMC")
}
