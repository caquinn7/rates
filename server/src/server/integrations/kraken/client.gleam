//// An actor responsible for managing a live WebSocket connection to the Kraken
//// exchange and distributing real-time price updates to interested processes.
////
//// This module handles:
//// - Connecting to Kraken's WebSocket v2 API
//// - Subscribing to and unsubscribing from ticker channels
//// - Tracking which symbols are actively subscribed and by how many clients
//// - Writing the latest prices to a shared `PriceStore`
//// - Populating the global `pairs` registry with the set of supported symbols
////
//// Price updates are stored in a shared `PriceStore`, which other parts of the
//// application can query independently. Supported trading pairs are also exposed
//// globally via the `pairs` module, which is updated during the initial
//// instrument subscription.
////
//// Use `new` to create the actor and start the WebSocket session. Use
//// `subscribe` and `unsubscribe` to manage interest in specific symbols.

import gleam/bool
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/http/request as http_request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/actor.{type Initialised, type StartError, type Started}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import server/integrations/kraken/internal/request.{
  type KrakenRequest, Instruments, KrakenRequest, Tickers,
}
import server/integrations/kraken/internal/response.{
  InstrumentsResponse, TickerResponse, TickerSubscribeConfirmation,
}
import server/integrations/kraken/internal/subscription_counter.{
  type SubscriptionCounter,
}
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store.{type PriceStore}
import server/utils/logger.{type Logger}
import stratus

pub opaque type KrakenClient {
  KrakenClient(Subject(Msg))
}

type Msg {
  SetSupportedSymbols(Set(String))
  Subscribe(String)
  ConfirmSubscribe(String)
  Unsubscribe(String)
  UpdatePrice(String, Float)
}

type State {
  SymbolsPending(
    logger: Logger,
    price_store: PriceStore,
    websocket_subject: Subject(stratus.InternalMessage(KrakenRequest)),
  )
  Ready(
    logger: Logger,
    price_store: PriceStore,
    websocket_subject: Subject(stratus.InternalMessage(KrakenRequest)),
    supported_symbols: Set(String),
    subscription_counter: SubscriptionCounter,
  )
}

pub fn new(
  logger: Logger,
  create_price_store: fn() -> PriceStore,
) -> Result(KrakenClient, StartError) {
  let handle_msg = fn(state, msg) { kraken_loop(state, msg) }

  let initialiser_wrapper = fn(self) {
    initialiser(self, logger, create_price_store)
    |> result.map_error(fn(err) { string.inspect(err) })
  }

  actor.new_with_initialiser(100, initialiser_wrapper)
  |> actor.on_message(handle_msg)
  |> actor.start
  |> result.map(fn(started) { KrakenClient(started.data) })
}

fn initialiser(
  self: Subject(Msg),
  logger: Logger,
  create_price_store: fn() -> PriceStore,
) -> Result(Initialised(State, Msg, Subject(Msg)), StartError) {
  use websocket_subject <- result.try(
    init_websocket(self, logger)
    |> result.map(fn(started) { started.data }),
  )

  KrakenRequest(request.Subscribe, Instruments, None)
  |> stratus.to_user_message
  |> actor.send(websocket_subject, _)

  let selector =
    process.new_selector()
    |> process.select(self)

  let state = SymbolsPending(logger, create_price_store(), websocket_subject)

  actor.initialised(state)
  |> actor.selecting(selector)
  |> actor.returning(self)
  |> Ok
}

pub fn subscribe(client: KrakenClient, symbol: String) -> Nil {
  let KrakenClient(subject) = client
  actor.send(subject, Subscribe(symbol))
}

pub fn unsubscribe(client: KrakenClient, symbol: String) -> Nil {
  let KrakenClient(subject) = client
  actor.send(subject, Unsubscribe(symbol))
}

fn kraken_loop(state: State, msg: Msg) -> actor.Next(State, Msg) {
  case msg {
    SetSupportedSymbols(supported_symbols) -> {
      // Updates the set of supported symbols based on Kraken's latest Instruments response.

      let assert SymbolsPending(logger:, price_store:, websocket_subject:) =
        state

      log_symbols(logger, supported_symbols)
      pairs.set(supported_symbols)

      KrakenRequest(request.Unsubscribe, Instruments, None)
      |> stratus.to_user_message
      |> actor.send(websocket_subject, _)

      actor.continue(Ready(
        price_store:,
        logger:,
        websocket_subject:,
        supported_symbols:,
        subscription_counter: subscription_counter.new(),
      ))
    }

    Subscribe(symbol) -> {
      let assert Ready(
        logger,
        _,
        websocket_subject:,
        supported_symbols:,
        subscription_counter:,
      ) = state

      use <- bool.guard(
        !set.contains(supported_symbols, symbol),
        actor.continue(state),
      )

      let #(should_subscribe, subscription_counter) =
        subscription_counter.add_subscription(subscription_counter, symbol)

      subscription_counter.log_subscription_count(
        subscription_counter,
        logger,
        symbol,
      )

      case should_subscribe {
        False -> Nil
        True ->
          KrakenRequest(request.Subscribe, Tickers([symbol]), None)
          |> stratus.to_user_message
          |> actor.send(websocket_subject, _)
      }

      actor.continue(Ready(..state, subscription_counter:))
    }

    ConfirmSubscribe(symbol) -> {
      let assert Ready(logger, _, _, _, subscription_counter:) = state

      let confirmation =
        subscription_counter.confirm_subscription(subscription_counter, symbol)

      case confirmation {
        Error(_) -> {
          log_confirmation_error(logger, symbol)
          actor.continue(Ready(..state, subscription_counter:))
        }

        Ok(subscription_counter) -> {
          subscription_counter.log_subscription_count(
            subscription_counter,
            logger,
            symbol,
          )
          actor.continue(Ready(..state, subscription_counter:))
        }
      }
    }

    Unsubscribe(symbol) -> {
      let assert Ready(logger, _, websocket_subject, _, subscription_counter:) =
        state

      let #(should_unsubscribe, subscription_counter) =
        subscription_counter.remove_subscription(subscription_counter, symbol)

      subscription_counter.log_subscription_count(
        subscription_counter,
        logger,
        symbol,
      )

      case should_unsubscribe {
        False -> Nil
        True ->
          KrakenRequest(request.Unsubscribe, Tickers([symbol]), None)
          |> stratus.to_user_message
          |> actor.send(websocket_subject, _)
      }

      actor.continue(Ready(..state, subscription_counter:))
    }

    UpdatePrice(symbol, price) -> {
      let assert Ready(logger, price_store, _, _, subscription_counter:) = state

      let is_subscribed =
        subscription_counter.is_actively_subscribed(
          subscription_counter,
          symbol,
        )

      case is_subscribed {
        False -> Nil
        True -> price_store.insert(price_store, symbol, price)
      }

      // todo: log timestamp of price
      log_price_update(logger, symbol, price)

      actor.continue(state)
    }
  }
}

// websocket

fn init_websocket(
  reply_to: Subject(Msg),
  logger: Logger,
) -> Result(
  Started(Subject(stratus.InternalMessage(KrakenRequest))),
  StartError,
) {
  let assert Ok(req) = http_request.to("https://ws.kraken.com/v2")

  stratus.websocket(
    request: req,
    init: fn() { #(#(reply_to, logger), None) },
    loop: websocket_loop,
  )
  |> stratus.on_close(fn(_state) { logger.info(logger, "kraken socket closed") })
  |> stratus.initialize
}

fn websocket_loop(
  state: #(Subject(Msg), Logger),
  msg: stratus.Message(KrakenRequest),
  conn: stratus.Connection,
) -> stratus.Next(#(Subject(Msg), Logger), KrakenRequest) {
  let #(reply_to, logger) = state

  case msg {
    stratus.Text(str) -> {
      log_message_from_kraken(logger, str)

      case json.parse(str, response.decoder()) {
        Error(_) -> stratus.continue(state)

        Ok(InstrumentsResponse(pairs)) -> {
          let symbols =
            pairs
            |> list.map(fn(p) { p.symbol })
            |> set.from_list

          actor.send(reply_to, SetSupportedSymbols(symbols))
          stratus.continue(state)
        }

        Ok(TickerSubscribeConfirmation(symbol)) -> {
          actor.send(reply_to, ConfirmSubscribe(symbol))
          stratus.continue(state)
        }

        Ok(TickerResponse(symbol, price)) -> {
          actor.send(reply_to, UpdatePrice(symbol, price))
          stratus.continue(state)
        }
      }
    }

    stratus.User(kraken_req) -> {
      let json_str =
        kraken_req
        |> request.encode
        |> json.to_string

      case stratus.send_text_message(conn, json_str) {
        Error(err) -> {
          log_message_send_error(logger, json_str, err)
          stratus.continue(state)
        }

        Ok(_) -> stratus.continue(state)
      }
    }

    stratus.Binary(_) -> stratus.continue(state)
  }
}

// logging

fn log_symbols(logger: Logger, symbols: Set(String)) -> Nil {
  logger
  |> logger.with("count", int.to_string(set.size(symbols)))
  |> logger.info("Received pair symbols from Kraken")
}

fn log_confirmation_error(logger: Logger, symbol: String) -> Nil {
  logger
  |> logger.with("symbol", symbol)
  |> logger.warning("Subscription confirmation failed")
}

fn log_price_update(logger: Logger, symbol: String, price: Float) -> Nil {
  logger
  |> logger.with("symbol", symbol)
  |> logger.with("price", float.to_string(price))
  |> logger.debug("Received price update")
}

fn log_message_send_error(logger: Logger, attempted_msg: String, err: a) -> Nil {
  logger
  |> logger.with("attempted_msg", attempted_msg)
  |> logger.with("error", string.inspect(err))
  |> logger.error("Failed to send message to kraken")
}

fn log_message_from_kraken(logger: Logger, message: String) -> Nil {
  Nil
  // logger
  // |> logger.with("received", message)
  // |> logger.debug("Received message from kraken")
}
