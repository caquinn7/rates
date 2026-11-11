//// Resolves one exchange rate within a caller-supplied deadline.
////
//// A private worker selects Kraken or CoinMarketCap and performs blocking
//// lookups. The resolver actor owns temporary Kraken interest and remains
//// responsive to cancellation while the worker runs. Every completion path
//// releases that interest and stops the worker before the resolver exits.

import gleam/erlang/process.{type Monitor, type Pid, type Subject, type Timer}
import gleam/function
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/otp/actor.{type Next, type StartError}
import gleam/result
import gleam/string
import server/rates/internal/kraken_interface.{type KrakenInterface}
import server/rates/internal/kraken_symbol.{type KrakenSymbol}
import server/rates/internal/rate_source_strategy.{
  KrakenStrategy, StrategyBehavior, StrategyConfig,
}
import server/rates/rate_error.{type RateError}
import server/rates/rate_service_config.{type RateServiceConfig}
import server/utils/time
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}

pub opaque type RateResolver {
  RateResolver(pid: Pid, subject: Subject(Msg))
}

pub type Config {
  Config(base: RateServiceConfig)
}

type Reply {
  Resolved(Result(RateResponse, RateError))
  Crashed(process.ExitReason)
}

type CallEvent {
  Answer(Reply)
  ResolverDown(process.Down)
}

type Msg {
  GetRate(Subject(Reply), RateRequest, deadline_ms: Int)
  AcquireKraken(KrakenSymbol, Subject(Nil))
  ReleaseKraken
  Completed(Result(RateResponse, RateError))
  DeadlineReached
  Cancel
  WorkerDown(process.Down)
  OwnerExited
}

type Pending {
  Pending(
    reply_to: Subject(Reply),
    request: RateRequest,
    deadline_ms: Int,
    worker: Pid,
    monitor: Monitor,
    timer: Timer,
    interest: Option(KrakenSymbol),
  )
}

type State {
  State(self: Subject(Msg), pending: Option(Pending))
}

/// Starts a one-shot resolver. Call `get_rate` once with the desired time budget.
pub fn new(config: Config) -> Result(RateResolver, StartError) {
  actor.new_with_initialiser(1000, fn(self) {
    // Handle the owner's exit explicitly so its outstanding work is cleaned up.
    process.trap_exits(True)
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_monitors(WorkerDown)
      |> process.select_trapped_exits(fn(_) { OwnerExited })

    State(self, None)
    |> actor.initialised
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(fn(state, message) {
    handle_msg(state, message, config.base)
  })
  |> actor.start
  |> result.map(fn(started) { RateResolver(started.pid, started.data) })
}

/// Resolves a rate, returning `TimedOut` when the millisecond budget expires.
/// Nonpositive budgets time out without starting any provider work.
/// Unexpected resolver or worker crashes still raise, preserving their details.
pub fn get_rate(
  resolver: RateResolver,
  rate_request: RateRequest,
  timeout: Int,
) -> Result(RateResponse, RateError) {
  let RateResolver(pid, subject) = resolver
  let deadline_ms = time.monotonic_time_ms() + int.max(timeout, 0)
  case timeout <= 0 {
    True -> {
      process.send(subject, Cancel)
      Error(rate_error.TimedOut(rate_request))
    }
    False -> {
      let reply_to = process.new_subject()
      let monitor = process.monitor(pid)
      let selector =
        process.new_selector()
        |> process.select_map(reply_to, Answer)
        |> process.select_specific_monitor(monitor, ResolverDown)

      process.send(subject, GetRate(reply_to, rate_request, deadline_ms))
      let answer = process.selector_receive(selector, remaining_ms(deadline_ms))
      process.demonitor_process(monitor)

      case answer {
        Ok(Answer(Resolved(result))) -> result
        Ok(Answer(Crashed(reason)))
        | Ok(ResolverDown(process.ProcessDown(reason:, ..))) ->
          panic as { "rate resolver exited: " <> string.inspect(reason) }
        Ok(ResolverDown(down)) ->
          panic as { "rate resolver exited: " <> string.inspect(down) }
        Error(_) -> {
          process.send(subject, Cancel)
          Error(rate_error.TimedOut(rate_request))
        }
      }
    }
  }
}

fn handle_msg(
  state: State,
  msg: Msg,
  config: RateServiceConfig,
) -> Next(State, Msg) {
  case msg {
    GetRate(reply_to, request, deadline_ms) -> {
      case state.pending {
        Some(_) -> panic as "a rate resolver can only be used once"
        None ->
          case remaining_ms(deadline_ms) {
            0 -> {
              process.send(
                reply_to,
                Resolved(Error(rate_error.TimedOut(request))),
              )
              actor.stop()
            }
            remaining -> {
              let worker =
                process.spawn_unlinked(fn() {
                  let result = resolve(state.self, config, request, deadline_ms)
                  process.send(state.self, Completed(result))
                })
              let pending =
                Pending(
                  reply_to:,
                  request:,
                  deadline_ms:,
                  worker:,
                  monitor: process.monitor(worker),
                  timer: process.send_after(
                    state.self,
                    remaining,
                    DeadlineReached,
                  ),
                  interest: None,
                )
              actor.continue(State(..state, pending: Some(pending)))
            }
          }
      }
    }

    AcquireKraken(symbol, acknowledge) -> {
      case state.pending {
        Some(pending) ->
          case remaining_ms(pending.deadline_ms) {
            0 -> timed_out(state, config.kraken_interface)
            _ -> {
              config.kraken_interface.subscribe(symbol)
              process.send(acknowledge, Nil)
              actor.continue(
                State(
                  ..state,
                  pending: Some(Pending(..pending, interest: Some(symbol))),
                ),
              )
            }
          }
        None -> actor.continue(state)
      }
    }

    ReleaseKraken ->
      actor.continue(release_interest(state, config.kraken_interface))

    Completed(result) ->
      case state.pending {
        Some(pending) ->
          case remaining_ms(pending.deadline_ms) {
            0 -> timed_out(state, config.kraken_interface)
            _ -> finish(state, Some(Resolved(result)), config.kraken_interface)
          }
        None -> actor.continue(state)
      }

    DeadlineReached -> timed_out(state, config.kraken_interface)
    Cancel | OwnerExited -> finish(state, None, config.kraken_interface)
    WorkerDown(process.ProcessDown(reason:, ..)) ->
      finish(state, Some(Crashed(reason)), config.kraken_interface)
    WorkerDown(down) ->
      panic as { "unexpected worker monitor: " <> string.inspect(down) }
  }
}

fn timed_out(state: State, kraken: KrakenInterface) -> Next(State, Msg) {
  let reply =
    option.map(state.pending, fn(pending) {
      Resolved(Error(rate_error.TimedOut(pending.request)))
    })
  finish(state, reply, kraken)
}

/// Finalizes both successful and failed requests, including cancellation.
fn finish(
  state: State,
  reply: Option(Reply),
  kraken: KrakenInterface,
) -> Next(State, Msg) {
  case state.pending {
    Some(pending) -> {
      let _ = process.cancel_timer(pending.timer)
      let _ = release_interest(state, kraken)
      stop_worker(pending.worker, pending.monitor)
      case reply {
        Some(reply) -> process.send(pending.reply_to, reply)
        None -> Nil
      }
    }
    None -> Nil
  }
  actor.stop()
}

fn stop_worker(worker: Pid, monitor: Monitor) -> Nil {
  case process.is_alive(worker) {
    True -> {
      process.kill(worker)
      let _ =
        process.new_selector()
        |> process.select_specific_monitor(monitor, function.identity)
        |> process.selector_receive_forever
      Nil
    }
    False -> Nil
  }
  process.demonitor_process(monitor)
}

fn release_interest(state: State, kraken: KrakenInterface) -> State {
  case state.pending {
    Some(Pending(interest: Some(symbol), ..) as pending) -> {
      kraken.unsubscribe(symbol)
      State(..state, pending: Some(Pending(..pending, interest: None)))
    }
    _ -> state
  }
}

fn resolve(
  controller: Subject(Msg),
  config: RateServiceConfig,
  request: RateRequest,
  deadline_ms: Int,
) -> Result(RateResponse, RateError) {
  use strategy <- result.try(
    rate_source_strategy.determine_strategy(
      request,
      config.get_currency,
      config.kraken_interface.get_kraken_symbol,
    )
    |> result.map_error(fn(error) {
      let rate_source_strategy.CurrencyNotFound(id) = error
      rate_error.CurrencyNotFound(request, id)
    }),
  )

  use _ <- result.try(case strategy {
    KrakenStrategy(symbol) -> {
      let acknowledge = process.new_subject()
      process.send(controller, AcquireKraken(symbol, acknowledge))

      process.receive(acknowledge, remaining_ms(deadline_ms))
      |> result.replace_error(rate_error.TimedOut(request))
    }
    _ -> Ok(Nil)
  })

  let strategy_config =
    StrategyConfig(
      check_for_kraken_price: config.kraken_interface.check_for_price,
      request_cmc_conversion: config.request_cmc_conversion,
      behavior: StrategyBehavior(
        on_kraken_success: fn() { process.send(controller, ReleaseKraken) },
        on_kraken_failure: fn(_, _) { process.send(controller, ReleaseKraken) },
      ),
    )
  let #(result, _) =
    rate_source_strategy.execute_strategy(strategy, request, strategy_config)
  result
}

fn remaining_ms(deadline_ms: Int) -> Int {
  int.max(deadline_ms - time.monotonic_time_ms(), 0)
}
