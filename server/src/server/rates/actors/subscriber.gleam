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
import server/integrations/kraken/client.{type KrakenClient} as kraken_client
import server/integrations/kraken/price_store.{type PriceEntry, type PriceStore}
import server/rates/actors/internal/kraken_symbol.{type KrakenSymbol}
import server/rates/actors/internal/utils
import server/rates/actors/rate_error.{type RateError, CmcError}
import server/rates/cmc_rate_handler.{type RequestCmcConversion}
import server/utils/logger.{type Logger}
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse, RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

pub opaque type RateSubscriber {
  RateSubscriber(
    // id specified by client
    id: SubscriptionId,
    subject: Subject(Msg),
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
    cmc_currencies: Dict(Int, String),
    kraken_client: KrakenClient,
    base_interval: Int,
    current_interval: Int,
    kraken_price_store: PriceStore,
    subscription: Option(Subscription),
    logger: Logger,
  )
}

type Subscription {
  Kraken(rate_request: RateRequest, symbol: KrakenSymbol)
  Cmc(rate_request: RateRequest)
}

/// Creates a new RateSubscriber actor that periodically fetches currency rates.
///
/// This function initializes a new actor with the provided configuration and starts it.
/// The actor will handle rate subscription messages and communicate conversion results
/// back through the provided reply subject as a tuple containing the subscription ID
/// and the rate response or error.
///
/// ## Parameters
///
/// - `subscription_id`: Unique identifier for this subscription
/// - `reply_to`: Subject to send tuples of (subscription_id, rate_response_or_error) back to the caller
/// - `cmc_currencies`: List of currencies supported by CoinMarketCap
/// - `request_cmc_conversion`: Function to request currency conversions from CoinMarketCap
/// - `kraken_client`: Kraken exchange client for fetching rates
/// - `interval`: Time interval in milliseconds for periodic rate updates
/// - `get_kraken_price_store`: Function that returns the current price store instance
/// - `get_current_time_ms`: Function that returns the current time in milliseconds
/// - `logger`: Logger instance for debugging and monitoring
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
/// configured `interval` parameter.
///
/// The reply subject will receive tuples in the format:
/// `#(subscription_id, Ok(rate_response))` for successful rate fetches
/// `#(subscription_id, Error(rate_error))` for failed rate fetches
pub fn new(
  subscription_id: SubscriptionId,
  reply_to: Subject(SubscriptionResult),
  cmc_currencies: List(Currency),
  request_cmc_conversion: RequestCmcConversion,
  kraken_client: KrakenClient,
  interval: Int,
  get_kraken_price_store: fn() -> PriceStore,
  get_current_time_ms: fn() -> Int,
  logger: Logger,
) -> Result(RateSubscriber, StartError) {
  let state =
    State(
      None,
      reply_to,
      currencies_to_dict(cmc_currencies),
      kraken_client,
      interval,
      interval,
      get_kraken_price_store(),
      None,
      logger,
    )

  let handle_msg = fn(state, msg) {
    handle_msg(
      subscription_id,
      state,
      msg,
      request_cmc_conversion,
      get_current_time_ms,
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
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  case msg {
    Init(self_subject) -> init(state, self_subject)

    Subscribe(rate_request) ->
      do_subscribe(
        subscription_id,
        state,
        rate_request,
        request_cmc_conversion,
        get_current_time_ms,
      )

    GetLatestRate(scheduled_subscription) ->
      get_latest_rate(
        subscription_id,
        state,
        scheduled_subscription,
        request_cmc_conversion,
        get_current_time_ms,
      )

    AddCurrencies(currencies) -> do_add_currencies(state, currencies)

    Stop -> do_stop(state)
  }
}

fn init(state: State, subject: Subject(Msg)) -> Next(State, Msg) {
  let updated_state = State(..state, self: Some(subject))
  actor.continue(updated_state)
}

fn do_subscribe(
  subscription_id: SubscriptionId,
  state: State,
  rate_request: RateRequest,
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  // If we were already subscribed via Kraken, first unsubscribe from the old symbol
  let state = case state.subscription {
    Some(Kraken(_, old_symbol)) -> {
      let symbol_str = kraken_symbol.to_string(old_symbol)
      kraken_client.unsubscribe(state.kraken_client, symbol_str)
      State(..state, subscription: None)
    }

    _ -> state
  }

  utils.resolve_currency_symbols(rate_request, state.cmc_currencies)
  |> result.map_error(fn(err) {
    case err {
      utils.CurrencyNotFound(id) -> {
        process.send(state.reply_to, #(
          subscription_id,
          Error(rate_error.CurrencyNotFound(rate_request, id)),
        ))
        actor.continue(State(..state, subscription: None))
      }
    }
  })
  |> result.map(fn(symbols) {
    case kraken_symbol.new(symbols) {
      Error(_) ->
        handle_cmc_fallback(
          subscription_id,
          state,
          rate_request,
          request_cmc_conversion,
          get_current_time_ms,
        )

      Ok(kraken_symbol) ->
        handle_kraken_subscription(
          subscription_id,
          state,
          rate_request,
          kraken_symbol,
          request_cmc_conversion,
          get_current_time_ms,
        )
    }
  })
  |> result.map(fn(state) {
    let assert Some(subject) = state.self
    let assert Some(subscription) = state.subscription

    process.send_after(
      subject,
      state.current_interval,
      GetLatestRate(subscription),
    )

    actor.continue(state)
  })
  |> result.unwrap_both
}

fn get_latest_rate(
  subscription_id: SubscriptionId,
  state: State,
  scheduled_subscription: Subscription,
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  use <- bool.guard(option.is_none(state.subscription), actor.continue(state))

  let assert Some(current_subscription) = state.subscription

  case current_subscription == scheduled_subscription {
    False -> actor.continue(state)

    True -> {
      let state = case current_subscription {
        Cmc(rate_req) ->
          handle_cmc_fallback(
            subscription_id,
            state,
            rate_req,
            request_cmc_conversion,
            get_current_time_ms,
          )

        Kraken(rate_req, symbol) ->
          check_kraken_price_and_respond(
            subscription_id,
            state,
            rate_req,
            symbol,
            request_cmc_conversion,
            get_current_time_ms,
          )
      }

      let assert Some(subject) = state.self
      process.send_after(
        subject,
        state.current_interval,
        GetLatestRate(current_subscription),
      )

      actor.continue(state)
    }
  }
}

fn handle_kraken_subscription(
  subscription_id: SubscriptionId,
  state: State,
  rate_req: RateRequest,
  kraken_symbol: KrakenSymbol,
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> State {
  utils.subscribe_to_kraken(state.kraken_client, kraken_symbol)

  check_kraken_price_and_respond(
    subscription_id,
    state,
    rate_req,
    kraken_symbol,
    request_cmc_conversion,
    get_current_time_ms,
  )
}

fn check_kraken_price_and_respond(
  subscription_id: SubscriptionId,
  state: State,
  rate_req: RateRequest,
  kraken_symbol: KrakenSymbol,
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> State {
  let kraken_price_result =
    utils.wait_for_kraken_price(kraken_symbol, state.kraken_price_store, 5, 50)

  case kraken_price_result {
    Error(_) -> {
      log_wait_for_kraken_price_timeout(state.logger, subscription_id, rate_req)

      handle_cmc_fallback(
        subscription_id,
        state,
        rate_req,
        request_cmc_conversion,
        get_current_time_ms,
      )
    }

    Ok(price_entry) ->
      handle_kraken_price_hit(
        subscription_id,
        state,
        rate_req,
        kraken_symbol,
        price_entry,
      )
  }
}

fn handle_kraken_price_hit(
  subscription_id: SubscriptionId,
  state: State,
  rate_req: RateRequest,
  kraken_symbol: KrakenSymbol,
  price_entry: PriceEntry,
) -> State {
  let rate = utils.extract_price(price_entry, kraken_symbol)

  let rate_resp =
    RateResponse(
      rate_req.from,
      rate_req.to,
      rate,
      rate_response.Kraken,
      price_entry.timestamp,
    )

  process.send(state.reply_to, #(subscription_id, Ok(rate_resp)))

  State(
    ..state,
    current_interval: state.base_interval,
    subscription: Some(Kraken(rate_req, kraken_symbol)),
  )
}

fn handle_cmc_fallback(
  subscription_id: SubscriptionId,
  state: State,
  rate_request: RateRequest,
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> State {
  let result =
    rate_request
    |> cmc_rate_handler.get_rate(request_cmc_conversion, get_current_time_ms)
    |> result.map_error(CmcError(rate_request, _))

  process.send(state.reply_to, #(subscription_id, result))

  // cmc api is rate limited, so capping freq to 30s
  State(
    ..state,
    current_interval: int.max(state.base_interval, 30_000),
    subscription: Some(Cmc(rate_request)),
  )
}

fn do_add_currencies(
  state: State,
  currencies: List(Currency),
) -> Next(State, Msg) {
  let cmc_currencies =
    currencies
    |> currencies_to_dict
    |> dict.merge(state.cmc_currencies, _)

  actor.continue(State(..state, cmc_currencies:))
}

fn do_stop(state: State) -> Next(State, Msg) {
  case state.subscription {
    None -> actor.stop()

    Some(subscription) -> {
      case subscription {
        Kraken(_, symbol) -> {
          utils.unsubscribe_from_kraken(state.kraken_client, symbol)
          actor.stop()
        }

        Cmc(_) -> actor.stop()
      }
    }
  }
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
  |> logger.warning("Timed out waiting for kraken price")
}
