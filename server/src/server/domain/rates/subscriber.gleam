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
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import server/domain/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/domain/rates/internal/kraken_interface.{type KrakenInterface}
import server/domain/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/domain/rates/internal/rate_source_strategy.{
  type RateSourceStrategy, type StrategyBehavior, CmcStrategy, KrakenStrategy,
  StrategyBehavior, StrategyConfig,
}
import server/domain/rates/internal/subscription_manager.{
  type Subscription, type SubscriptionManager, Cmc, Kraken,
}
import server/domain/rates/rate_error.{type RateError}
import server/domain/rates/rate_service_config.{type RateServiceConfig}
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store.{type PriceEntry}
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
    base: RateServiceConfig,
    subscription_manager: SubscriptionManager,
    logger: Logger,
  )
}

pub type SubscriptionResult =
  #(SubscriptionId, Result(RateResponse, RateError))

type Msg {
  Init(Subject(Msg))
  Subscribe(RateRequest)
  GetLatestRate(Subscription)
  AddCurrencies(List(Currency))
  Stop
}

type State {
  State(
    self: Option(Subject(Msg)),
    reply_to: Subject(SubscriptionResult),
    currency_symbols: Dict(Int, String),
    subscription_manager: SubscriptionManager,
    logger: Logger,
  )
}

type StateTransition {
  KeepCurrentState
  UpdateSubscription(RateSourceStrategy, RateRequest)
  ClearSubscription
  DowngradeToFallback(RateRequest)
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
  let state =
    State(
      None,
      reply_to,
      currencies_to_dict(config.base.currencies),
      config.subscription_manager,
      config.logger,
    )

  let handle_msg = fn(state, msg) {
    handle_msg(
      subscription_id,
      state,
      msg,
      config.base.kraken_interface,
      config.base.request_cmc_conversion,
      config.base.get_current_time_ms,
    )
  }

  use rate_subscriber <- result.try(
    state
    |> actor.new
    |> actor.on_message(handle_msg)
    |> actor.start
    |> result.map(fn(started) { RateSubscriber(subscription_id, started.data) }),
  )

  actor.send(rate_subscriber.subject, Init(rate_subscriber.subject))
  Ok(rate_subscriber)
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

/// Adds a list of currencies to the rate subscriber's available currency set.
/// 
/// This function sends an `AddCurrencies` message to the subscriber actor,
/// instructing it to add the specified currencies to the list of currencies
/// that clients can subscribe to for exchange rate updates.
/// 
/// ## Parameters
/// 
/// - `subscriber`: The `RateSubscriber` instance to add currencies to
/// - `currencies`: A list of `Currency` values to make available for subscription
/// 
/// ## Returns
/// 
/// `Nil` - This function performs a side effect by sending a message to an actor
pub fn add_currencies(
  subscriber: RateSubscriber,
  currencies: List(Currency),
) -> Nil {
  actor.send(subscriber.subject, AddCurrencies(currencies))
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

fn handle_msg(
  subscription_id: SubscriptionId,
  state: State,
  msg: Msg,
  kraken_interface: KrakenInterface,
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  case msg {
    Init(subject) -> handle_init(state, subject)

    Subscribe(rate_request) ->
      handle_subscribe(
        subscription_id,
        state,
        rate_request,
        kraken_interface.subscribe,
        kraken_interface.unsubscribe,
        kraken_interface.check_for_price,
        request_cmc_conversion,
        get_current_time_ms,
      )

    GetLatestRate(scheduled_subscription) ->
      handle_get_latest_rate(
        subscription_id,
        state,
        scheduled_subscription,
        kraken_interface.unsubscribe,
        kraken_interface.check_for_price,
        request_cmc_conversion,
        get_current_time_ms,
      )

    AddCurrencies(currencies) -> handle_add_currencies(state, currencies)

    Stop -> handle_stop(state, kraken_interface.unsubscribe)
  }
}

// message handler functions

fn handle_init(state: State, subject: Subject(Msg)) -> Next(State, Msg) {
  actor.continue(State(..state, self: Some(subject)))
}

fn handle_subscribe(
  subscription_id: SubscriptionId,
  state: State,
  rate_request: RateRequest,
  subscribe_to_kraken: fn(KrakenSymbol) -> Nil,
  unsubscribe_from_kraken: fn(KrakenSymbol) -> Nil,
  check_for_kraken_price: fn(KrakenSymbol) -> Result(PriceEntry, Nil),
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  let state = cleanup_existing_subscription(state, unsubscribe_from_kraken)

  let strategy =
    rate_source_strategy.determine_strategy(
      rate_request,
      state.currency_symbols,
      kraken_symbol.new(_, pairs.exists),
    )

  case strategy {
    Error(rate_source_strategy.CurrencyNotFound(id)) -> {
      process.send(state.reply_to, #(
        subscription_id,
        Error(rate_error.CurrencyNotFound(rate_request, id)),
      ))

      let state =
        apply_state_transition(
          state,
          ClearSubscription,
          unsubscribe_from_kraken,
        )
      actor.continue(state)
    }

    Ok(strategy) -> {
      let config =
        StrategyConfig(
          check_for_kraken_price:,
          request_cmc_conversion:,
          get_current_time_ms:,
          behavior: create_subscriber_behavior(subscription_id, state.logger),
        )

      // Subscribe to Kraken if needed (only happens once during initial subscription)
      case strategy {
        KrakenStrategy(symbol) -> subscribe_to_kraken(symbol)
        CmcStrategy -> Nil
      }

      let #(result, should_downgrade) =
        rate_source_strategy.execute_strategy(strategy, rate_request, config)

      process.send(state.reply_to, #(subscription_id, result))

      // Determine state transition based on strategy and downgrade
      let transition = case should_downgrade {
        True -> DowngradeToFallback(rate_request)
        False -> UpdateSubscription(strategy, rate_request)
      }

      let state =
        apply_state_transition(state, transition, unsubscribe_from_kraken)

      schedule_next_update(state)
      actor.continue(state)
    }
  }
}

fn handle_get_latest_rate(
  subscription_id: SubscriptionId,
  state: State,
  scheduled_subscription: Subscription,
  unsubscribe_from_kraken: fn(KrakenSymbol) -> Nil,
  check_for_kraken_price: fn(KrakenSymbol) -> Result(PriceEntry, Nil),
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  let subscription =
    subscription_manager.get_subscription(state.subscription_manager)

  use <- bool.guard(option.is_none(subscription), actor.continue(state))

  let assert Some(current_subscription) = subscription

  use <- bool.guard(
    current_subscription != scheduled_subscription,
    actor.continue(state),
  )

  let #(rate_request, strategy) = case current_subscription {
    Kraken(rate_req, symbol) -> #(rate_req, KrakenStrategy(symbol))
    Cmc(rate_req) -> #(rate_req, CmcStrategy)
  }

  let strategy_config =
    StrategyConfig(
      check_for_kraken_price:,
      request_cmc_conversion:,
      get_current_time_ms:,
      behavior: create_subscriber_behavior(subscription_id, state.logger),
    )

  let #(result, should_downgrade) =
    rate_source_strategy.execute_strategy(
      strategy,
      rate_request,
      strategy_config,
    )

  process.send(state.reply_to, #(subscription_id, result))

  let transition = case should_downgrade {
    True -> DowngradeToFallback(rate_request)
    False -> KeepCurrentState
  }

  let state = apply_state_transition(state, transition, unsubscribe_from_kraken)

  schedule_next_update(state)
  actor.continue(state)
}

fn handle_add_currencies(
  state: State,
  currencies: List(Currency),
) -> Next(State, Msg) {
  let currency_symbols =
    currencies
    |> currencies_to_dict
    |> dict.merge(state.currency_symbols, _)

  actor.continue(State(..state, currency_symbols:))
}

fn handle_stop(
  state: State,
  unsubscribe_from_kraken: fn(KrakenSymbol) -> Nil,
) -> Next(State, Msg) {
  let subscription =
    subscription_manager.get_subscription(state.subscription_manager)

  case subscription {
    None -> actor.stop()

    Some(subscription) -> {
      case subscription {
        Kraken(_, symbol) -> {
          unsubscribe_from_kraken(symbol)
          actor.stop()
        }

        Cmc(_) -> actor.stop()
      }
    }
  }
}

// helper functions

/// Applies a state transition to create a new state
fn apply_state_transition(
  state: State,
  transition: StateTransition,
  unsubscribe_from_kraken: fn(KrakenSymbol) -> Nil,
) -> State {
  case transition {
    KeepCurrentState -> state

    UpdateSubscription(strategy, rate_request) ->
      update_subscription_manager(state, strategy, rate_request)

    ClearSubscription -> clear_subscription_from_state(state)

    DowngradeToFallback(rate_request) -> {
      // Cleanup any existing Kraken subscription before downgrading
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
  }
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
    subscription_manager: subscription_manager.clear_subscription(
      state.subscription_manager,
    ),
  )
}

fn create_subscriber_behavior(
  subscription_id: SubscriptionId,
  logger: Logger,
) -> StrategyBehavior {
  StrategyBehavior(
    on_kraken_success: fn() { Nil },
    on_kraken_failure: fn(rate_request, _kraken_symbol) {
      log_wait_for_kraken_price_timeout(logger, subscription_id, rate_request)
    },
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

fn schedule_next_update(state: State) -> Nil {
  let assert Some(subject) = state.self
  let assert Some(subscription) =
    subscription_manager.get_subscription(state.subscription_manager)

  process.send_after(
    subject,
    subscription_manager.get_current_interval(state.subscription_manager),
    GetLatestRate(subscription),
  )

  Nil
}

fn currencies_to_dict(currencies: List(Currency)) -> Dict(Int, String) {
  currencies
  |> list.map(fn(c) { #(c.id, c.symbol) })
  |> dict.from_list
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
