//// A short-lived actor for resolving a single exchange rate.
////
//// The `RateResolver` actor attempts to fetch the exchange rate for a given
//// currency pair using Kraken, falling back to CoinMarketCap (CMC) if needed.
//// This actor is designed for one-shot use and terminates after handling a single
//// `GetRate` message.
////
//// Kraken is preferred as the source of truth if the currency pair is supported
//// and the price becomes available within a short polling window.
//// Otherwise, the actor gracefully falls back to CMC.
////
//// Usage:
////   - Start a new `RateResolver` with `new`.
////   - Send a `GetRate` message using `get_rate`.
////   - The actor automatically stops after sending its response.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import server/domain/rates/internal/cmc_rate_handler.{type RequestCmcConversion}
import server/domain/rates/internal/kraken_interface.{type KrakenInterface}
import server/domain/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/domain/rates/internal/rate_source_strategy.{
  type RateSourceStrategy, type StrategyBehavior, CmcStrategy, KrakenStrategy,
  StrategyBehavior, StrategyConfig,
}
import server/domain/rates/rate_error.{type RateError}
import server/integrations/kraken/pairs
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}

pub opaque type RateResolver {
  RateResolver(Subject(Msg))
}

pub type Config {
  Config(
    currencies: List(Currency),
    kraken_interface: KrakenInterface,
    request_cmc_conversion: RequestCmcConversion,
    get_current_time_ms: fn() -> Int,
  )
}

type Msg {
  GetRate(Subject(Result(RateResponse, RateError)), RateRequest)
}

type State {
  State(currency_symbols: Dict(Int, String))
}

pub fn new(config: Config) -> Result(RateResolver, StartError) {
  let currency_symbols =
    config.currencies
    |> list.map(fn(c) { #(c.id, c.symbol) })
    |> dict.from_list

  let msg_loop = fn(state, msg) {
    handle_msg(
      state,
      msg,
      config.kraken_interface,
      config.request_cmc_conversion,
      config.get_current_time_ms,
    )
  }

  State(currency_symbols:)
  |> actor.new
  |> actor.on_message(msg_loop)
  |> actor.start
  |> result.map(fn(started) { RateResolver(started.data) })
}

pub fn get_rate(
  resolver: RateResolver,
  rate_request: RateRequest,
  timeout: Int,
) -> Result(RateResponse, RateError) {
  let RateResolver(subject) = resolver
  actor.call(subject, timeout, GetRate(_, rate_request))
}

fn handle_msg(
  state: State,
  msg: Msg,
  kraken_interface: KrakenInterface,
  request_cmc_conversion: RequestCmcConversion,
  get_current_time_ms: fn() -> Int,
) -> Next(State, Msg) {
  case msg {
    GetRate(reply_to, rate_request) -> {
      let strategy =
        rate_source_strategy.determine_strategy(
          rate_request,
          state.currency_symbols,
          kraken_symbol.new(_, pairs.exists),
        )

      case strategy {
        Error(rate_source_strategy.CurrencyNotFound(id)) -> {
          process.send(
            reply_to,
            Error(rate_error.CurrencyNotFound(rate_request, id)),
          )
          actor.stop()
        }

        Ok(strategy) -> {
          let config =
            StrategyConfig(
              check_for_kraken_price: kraken_interface.check_for_price,
              request_cmc_conversion:,
              get_current_time_ms:,
              behavior: create_resolver_behavior(
                kraken_interface.unsubscribe,
                strategy,
              ),
            )

          case strategy {
            KrakenStrategy(symbol) -> kraken_interface.subscribe(symbol)
            CmcStrategy -> Nil
          }

          let result =
            rate_source_strategy.execute_strategy(
              strategy,
              rate_request,
              config,
            )

          process.send(reply_to, result)
          actor.stop()
        }
      }
    }
  }
}

fn create_resolver_behavior(
  unsubscribe_from_kraken: fn(KrakenSymbol) -> Nil,
  strategy: RateSourceStrategy,
) -> StrategyBehavior {
  StrategyBehavior(
    on_kraken_success: fn() {
      case strategy {
        KrakenStrategy(symbol) -> unsubscribe_from_kraken(symbol)
        CmcStrategy -> Nil
      }
    },
    on_kraken_failure: fn(_rate_request, kraken_symbol) {
      unsubscribe_from_kraken(kraken_symbol)
    },
  )
}
