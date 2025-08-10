/// An actor for managing an active subscription to a currency pair's exchange rate.
///
/// The `RateSubscriber` is intended for clients that want to receive **ongoing rate updates**
/// for a single currency pair. When a pair is subscribed to, the actor attempts to fetch the
/// most recent price from Kraken if supported, falling back to CoinMarketCap if necessary.
///
/// Upon successful subscription, the actor enters a polling loop that periodically sends a
/// `RateResponse` to the provided `reply_to` subject. The polling interval is specified when
/// calling `new`.
///
/// Usage
/// - Use `new` to start the actor and begin polling.
/// - Use `subscribe`to begin watching a specific pair.
/// - Use `add_currencies` to add more currencies to the internal dictionary.
/// - Use `unsubscribe` to stop the subscription and shut down the actor.
///
/// Only one active subscription is supported at a time. A future enhancement could allow
/// multiple concurrent subscriptions per actor instance.
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import gleam/string
import server/kraken/kraken.{type Kraken}
import server/kraken/price_store.{type PriceStore}
import server/rates/actors/utils.{type KrakenSymbol}
import server/rates/cmc_rate_handler.{
  type RequestCmcConversion, RequestFailed, UnexpectedResponse, ValidationError,
}
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse, RateResponse}

pub opaque type RateSubscriber {
  RateSubscriber(Subject(Msg))
}

type Msg {
  Subscribe(RateRequest)
  GetLatestRate
  AddCurrencies(List(Currency))
  Stop
}

type State {
  Idle(
    reply_to: Subject(Result(RateResponse, String)),
    cmc_currencies: Dict(Int, String),
    kraken: Kraken,
    price_store: PriceStore,
  )
  Subscribed(
    reply_to: Subject(Result(RateResponse, String)),
    cmc_currencies: Dict(Int, String),
    kraken: Kraken,
    price_store: PriceStore,
    subscription: Subscription,
  )
}

type Subscription {
  Kraken(rate_request: RateRequest, symbol: KrakenSymbol)
  Cmc(rate_request: RateRequest)
}

pub fn new(
  reply_to: Subject(Result(RateResponse, String)),
  cmc_currencies: List(Currency),
  request_cmc_conversion: RequestCmcConversion,
  kraken: Kraken,
  get_price_store: fn() -> PriceStore,
  interval: Int,
) -> Result(RateSubscriber, StartError) {
  let currency_dict = currencies_to_dict(cmc_currencies)

  let initial_state = Idle(reply_to, currency_dict, kraken, get_price_store())
  let msg_loop = fn(state, msg) {
    handle_msg(state, msg, request_cmc_conversion)
  }

  initial_state
  |> actor.new
  |> actor.on_message(msg_loop)
  |> actor.start
  |> result.map(fn(started) {
    process.spawn(fn() { polling_loop(started.data, interval) })
    RateSubscriber(started.data)
  })
}

fn polling_loop(subject: Subject(Msg), interval: Int) -> Nil {
  process.send(subject, GetLatestRate)
  process.sleep(interval)
  polling_loop(subject, interval)
}

pub fn subscribe(subscriber: RateSubscriber, rate_request: RateRequest) -> Nil {
  let RateSubscriber(subject) = subscriber
  actor.send(subject, Subscribe(rate_request))
}

pub fn add_currencies(
  subscriber: RateSubscriber,
  currencies: List(Currency),
) -> Nil {
  let RateSubscriber(subject) = subscriber
  actor.send(subject, AddCurrencies(currencies))
}

pub fn stop(subscriber: RateSubscriber) -> Nil {
  let RateSubscriber(subject) = subscriber
  actor.send(subject, Stop)
}

fn handle_msg(
  state: State,
  msg: Msg,
  request_cmc_conversion: RequestCmcConversion,
) -> Next(State, Msg) {
  case msg {
    Subscribe(rate_req) -> {
      // If we were already subscribed via Kraken, first unsubscribe from the old symbol
      let state = case state {
        Subscribed(
          reply_to,
          cmc_currencies,
          kraken,
          price_store,
          Kraken(_, old_sym),
        ) -> {
          let sym_str = utils.unwrap_kraken_symbol(old_sym)
          kraken.unsubscribe(kraken, sym_str)
          Idle(reply_to, cmc_currencies, kraken, price_store)
        }

        _ -> state
      }

      case utils.resolve_currency_symbols(rate_req, state.cmc_currencies) {
        Error(utils.CurrencyNotFound(id)) -> {
          let msg = "invalid currency id: " <> int.to_string(id)
          process.send(state.reply_to, Error(msg))
          actor.continue(Idle(
            state.reply_to,
            state.cmc_currencies,
            state.kraken,
            state.price_store,
          ))
        }

        Ok(symbols) -> {
          case utils.resolve_kraken_symbol(symbols) {
            Error(_) ->
              handle_cmc_fallback(state, rate_req, request_cmc_conversion)

            Ok(kraken_symbol) -> {
              let symbol_str = utils.unwrap_kraken_symbol(kraken_symbol)
              kraken.subscribe(state.kraken, symbol_str)

              let kraken_price_result =
                utils.wait_for_kraken_price(
                  kraken_symbol,
                  state.price_store,
                  5,
                  50,
                )

              case kraken_price_result {
                Error(_) ->
                  handle_cmc_fallback(state, rate_req, request_cmc_conversion)

                Ok(rate) -> {
                  let rate_response =
                    RateResponse(
                      rate_req.from,
                      rate_req.to,
                      rate,
                      rate_response.Kraken,
                    )

                  process.send(state.reply_to, Ok(rate_response))

                  actor.continue(Subscribed(
                    state.reply_to,
                    state.cmc_currencies,
                    state.kraken,
                    state.price_store,
                    Kraken(rate_req, kraken_symbol),
                  ))
                }
              }
            }
          }
        }
      }
    }

    GetLatestRate -> {
      case state {
        Idle(..) -> actor.continue(state)

        Subscribed(reply_to, _, _, price_store, subscription) -> {
          case subscription {
            Kraken(rate_req, symbol) -> {
              let kraken_price_result =
                utils.wait_for_kraken_price(symbol, price_store, 5, 50)

              case kraken_price_result {
                Error(_) ->
                  handle_cmc_fallback(state, rate_req, request_cmc_conversion)

                Ok(rate) -> {
                  let rate_resp =
                    RateResponse(
                      rate_req.from,
                      rate_req.to,
                      rate,
                      rate_response.Kraken,
                    )
                  process.send(reply_to, Ok(rate_resp))
                  actor.continue(state)
                }
              }
            }

            Cmc(rate_req) -> {
              // todo: attempt to upgrade to kraken sub?
              handle_cmc_fallback(state, rate_req, request_cmc_conversion)
            }
          }
        }
      }
    }

    AddCurrencies(currencies) -> {
      let cmc_currencies =
        currencies
        |> currencies_to_dict
        |> dict.merge(state.cmc_currencies, _)

      actor.continue(case state {
        Idle(..) -> Idle(..state, cmc_currencies:)
        Subscribed(..) -> Subscribed(..state, cmc_currencies:)
      })
    }

    Stop -> {
      case state {
        Idle(..) -> actor.stop()

        Subscribed(_, _, kraken, _, subscription) -> {
          case subscription {
            Kraken(_, symbol) -> {
              let symbol_str = utils.unwrap_kraken_symbol(symbol)
              kraken.unsubscribe(kraken, symbol_str)
              actor.stop()
            }

            Cmc(_) -> actor.stop()
          }
        }
      }
    }
  }
}

fn currencies_to_dict(currencies: List(Currency)) -> Dict(Int, String) {
  currencies
  |> list.map(fn(c) { #(c.id, c.symbol) })
  |> dict.from_list
}

fn handle_cmc_fallback(
  state: State,
  rate_req: RateRequest,
  request_cmc_conversion: RequestCmcConversion,
) -> Next(State, Msg) {
  let result = get_cmc_rate(rate_req, request_cmc_conversion)

  process.send(state.reply_to, result)

  actor.continue(Subscribed(
    state.reply_to,
    state.cmc_currencies,
    state.kraken,
    state.price_store,
    Cmc(rate_req),
  ))
}

fn get_cmc_rate(
  rate_request: RateRequest,
  request_cmc_conversion: RequestCmcConversion,
) -> Result(RateResponse, String) {
  rate_request
  |> cmc_rate_handler.get_rate(request_cmc_conversion)
  |> result.map_error(fn(rate_req_err) {
    case rate_req_err {
      ValidationError(msg) -> msg
      cmc_rate_handler.CurrencyNotFound(id) ->
        "currency id not found: " <> int.to_string(id)
      RequestFailed(err) -> "cmc request failed: " <> string.inspect(err)
      UnexpectedResponse(err) ->
        "unexpected response from cmc: " <> string.inspect(err)
    }
  })
}
