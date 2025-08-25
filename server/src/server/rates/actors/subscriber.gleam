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

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid, type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import server/kraken/kraken.{type Kraken}
import server/kraken/price_store.{type PriceStore}
import server/rates/actors/kraken_symbol.{type KrakenSymbol}
import server/rates/actors/rate_error.{type RateError, CmcError}
import server/rates/actors/utils
import server/rates/cmc_rate_handler.{type RequestCmcConversion}
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse, RateResponse}

pub opaque type RateSubscriber {
  RateSubscriber(pid: Pid, subject: Subject(Msg))
}

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
    reply_to: Subject(Result(RateResponse, RateError)),
    cmc_currencies: Dict(Int, String),
    kraken: Kraken,
    base_interval: Int,
    current_interval: Int,
    price_store: PriceStore,
    subscription: Option(Subscription),
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
/// back through the provided reply subject.
///
/// ## Parameters
///
/// - `reply_to`: Subject to send rate responses or error messages back to the caller
/// - `cmc_currencies`: List of currencies supported by CoinMarketCap
/// - `request_cmc_conversion`: Function to request currency conversions from CoinMarketCap
/// - `kraken`: Kraken exchange client for fetching rates
/// - `interval`: Time interval in milliseconds for periodic rate updates
/// - `get_price_store`: Function that returns the current price store instance
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
pub fn new(
  reply_to: Subject(Result(RateResponse, RateError)),
  cmc_currencies: List(Currency),
  request_cmc_conversion: RequestCmcConversion,
  kraken: Kraken,
  interval: Int,
  get_price_store: fn() -> PriceStore,
) -> Result(RateSubscriber, StartError) {
  let state =
    State(
      None,
      reply_to,
      currencies_to_dict(cmc_currencies),
      kraken,
      interval,
      interval,
      get_price_store(),
      None,
    )

  use rate_subscriber <- result.try(
    state
    |> actor.new
    |> actor.on_message(fn(state, msg) {
      handle_msg(state, msg, request_cmc_conversion)
    })
    |> actor.start
    |> result.map(fn(started) { RateSubscriber(started.pid, started.data) }),
  )

  let RateSubscriber(_pid, subject) = rate_subscriber

  actor.send(subject, Init(subject))
  Ok(rate_subscriber)
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
  let RateSubscriber(_pid, subject) = subscriber
  actor.send(subject, Subscribe(rate_request))
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
  let RateSubscriber(_pid, subject) = subscriber
  actor.send(subject, AddCurrencies(currencies))
}

/// Stops a rate subscriber actor by sending a Stop message to it.
///
/// ## Parameters
/// - `subscriber`: The RateSubscriber instance to stop
///
/// ## Returns
/// `Nil` - This function performs a side effect by sending a message to an actor
pub fn stop(subscriber: RateSubscriber) -> Nil {
  let RateSubscriber(_pid, subject) = subscriber
  actor.send(subject, Stop)
}

fn handle_msg(
  state: State,
  msg: Msg,
  request_cmc_conversion: RequestCmcConversion,
) -> Next(State, Msg) {
  case msg {
    Init(self_subject) -> init(state, self_subject)

    Subscribe(rate_req) -> do_subscribe(state, rate_req, request_cmc_conversion)

    GetLatestRate(scheduled_subscription) ->
      get_latest_rate(state, scheduled_subscription, request_cmc_conversion)

    AddCurrencies(currencies) -> do_add_currencies(state, currencies)

    Stop -> do_stop(state)
  }
}

fn init(state: State, subject: Subject(Msg)) -> Next(State, Msg) {
  let updated_state = State(..state, self: Some(subject))
  actor.continue(updated_state)
}

fn do_subscribe(
  state: State,
  rate_req: RateRequest,
  request_cmc_conversion: RequestCmcConversion,
) -> Next(State, Msg) {
  // If we were already subscribed via Kraken, first unsubscribe from the old symbol
  let state = case state.subscription {
    Some(Kraken(_, old_symbol)) -> {
      let symbol_str = kraken_symbol.to_string(old_symbol)
      kraken.unsubscribe(state.kraken, symbol_str)
      State(..state, subscription: None)
    }

    _ -> state
  }

  utils.resolve_currency_symbols(rate_req, state.cmc_currencies)
  |> result.map_error(fn(err) {
    case err {
      utils.CurrencyNotFound(id) -> {
        process.send(
          state.reply_to,
          Error(rate_error.CurrencyNotFound(rate_req, id)),
        )
        actor.continue(State(..state, subscription: None))
      }
    }
  })
  |> result.map(fn(symbols) {
    case kraken_symbol.new(symbols) {
      Error(_) -> handle_cmc_fallback(state, rate_req, request_cmc_conversion)

      Ok(kraken_symbol) ->
        handle_kraken_subscription(
          state,
          rate_req,
          kraken_symbol,
          request_cmc_conversion,
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
  state: State,
  scheduled_subscription: Subscription,
  request_cmc_conversion: RequestCmcConversion,
) -> Next(State, Msg) {
  let assert Some(current_subscription) = state.subscription

  case current_subscription == scheduled_subscription {
    False -> actor.continue(state)

    True -> {
      let state = case current_subscription {
        Cmc(rate_req) ->
          handle_cmc_fallback(state, rate_req, request_cmc_conversion)

        Kraken(rate_req, symbol) ->
          check_kraken_price_and_respond(
            state,
            rate_req,
            symbol,
            request_cmc_conversion,
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
  state: State,
  rate_req: RateRequest,
  kraken_symbol: KrakenSymbol,
  request_cmc_conversion: RequestCmcConversion,
) -> State {
  let symbol_str = kraken_symbol.to_string(kraken_symbol)
  kraken.subscribe(state.kraken, symbol_str)

  check_kraken_price_and_respond(
    state,
    rate_req,
    kraken_symbol,
    request_cmc_conversion,
  )
}

fn check_kraken_price_and_respond(
  state: State,
  rate_req: RateRequest,
  kraken_symbol: KrakenSymbol,
  request_cmc_conversion: RequestCmcConversion,
) -> State {
  let kraken_price_result =
    utils.wait_for_kraken_price(kraken_symbol, state.price_store, 5, 50)

  case kraken_price_result {
    Error(_) -> handle_cmc_fallback(state, rate_req, request_cmc_conversion)
    Ok(rate) -> handle_kraken_price_hit(state, rate_req, kraken_symbol, rate)
  }
}

fn handle_kraken_price_hit(
  state: State,
  rate_req: RateRequest,
  kraken_symbol: KrakenSymbol,
  rate: Float,
) -> State {
  let rate_resp =
    RateResponse(rate_req.from, rate_req.to, rate, rate_response.Kraken)

  process.send(state.reply_to, Ok(rate_resp))

  State(
    ..state,
    current_interval: state.base_interval,
    subscription: Some(Kraken(rate_req, kraken_symbol)),
  )
}

fn handle_cmc_fallback(
  state: State,
  rate_req: RateRequest,
  request_cmc_conversion: RequestCmcConversion,
) -> State {
  let result =
    rate_req
    |> cmc_rate_handler.get_rate(request_cmc_conversion)
    |> result.map_error(CmcError(rate_req, _))

  process.send(state.reply_to, result)

  // cmc api is rate limited, so capping freq to 30s
  State(
    ..state,
    current_interval: int.max(state.base_interval, 30_000),
    subscription: Some(Cmc(rate_req)),
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
          let symbol_str = kraken_symbol.to_string(symbol)
          kraken.unsubscribe(state.kraken, symbol_str)
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
