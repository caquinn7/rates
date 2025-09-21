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
import gleam/otp/actor.{type StartError, type Started}
import gleam/result
import gleam/set.{type Set}
import gleam/string
import server/integrations/kraken/pairs
import server/integrations/kraken/price_store.{type PriceStore}
import server/integrations/kraken/request.{
  type KrakenRequest, Instruments, KrakenRequest, Tickers,
}
import server/integrations/kraken/response.{
  InstrumentsResponse, TickerResponse, TickerSubscribeConfirmation,
}
import server/integrations/kraken/subscription_counter.{type SubscriptionCounter}
import server/utils/logger.{type Logger}
import stratus

pub opaque type KrakenClient {
  KrakenClient(Subject(Msg))
}

type Msg {
  Connect(Subject(stratus.InternalMessage(KrakenRequest)))
  SetSupportedSymbols(Set(String))
  Subscribe(String)
  ConfirmSubscribe(String)
  Unsubscribe(String)
  UpdatePrice(String, Float)
}

type State {
  New(logger: Logger)
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
  let kraken_loop = fn(state, msg) {
    kraken_loop(state, msg, create_price_store)
  }

  use kraken_subject <- result.try(
    New(logger)
    |> actor.new
    |> actor.on_message(kraken_loop)
    |> actor.start
    |> result.map(fn(started) { started.data }),
  )

  use websocket_subject <- result.try(
    init_websocket(kraken_subject, logger)
    |> result.map(fn(started) { started.data }),
  )

  actor.send(kraken_subject, Connect(websocket_subject))
  Ok(KrakenClient(kraken_subject))
}

pub fn subscribe(client: KrakenClient, symbol: String) -> Nil {
  let KrakenClient(subject) = client
  actor.send(subject, Subscribe(symbol))
}

pub fn unsubscribe(client: KrakenClient, symbol: String) -> Nil {
  let KrakenClient(subject) = client
  actor.send(subject, Unsubscribe(symbol))
}

fn kraken_loop(
  state: State,
  msg: Msg,
  create_price_store: fn() -> PriceStore,
) -> actor.Next(State, Msg) {
  case msg {
    Connect(websocket_subject) -> {
      KrakenRequest(request.Subscribe, Instruments, None)
      |> stratus.to_user_message
      |> actor.send(websocket_subject, _)

      actor.continue(SymbolsPending(
        state.logger,
        create_price_store(),
        websocket_subject,
      ))
    }

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
      let assert Ok(subscription_counter) =
        subscription_counter.confirm_subscription(subscription_counter, symbol)

      subscription_counter.log_subscription_count(
        subscription_counter,
        logger,
        symbol,
      )

      actor.continue(Ready(..state, subscription_counter:))
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
  |> stratus.on_close(fn(_state) {
    logger.info(logger, "kraken socket closed")
    Nil
  })
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
  logger
  |> logger.with("received", message)
  |> logger.debug("Received message from kraken")
}
