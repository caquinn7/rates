import exception
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None}
import mist
import server/currencies/currency_repository.{CurrencyRepository}
import server/currencies/currency_symbol_cache
import server/services.{Services}
import server/utils/logger
import server/web/router
import shared/currency.{type Currency, Crypto}

type CacheCall {
  Read(String)
  Fetch(String)
}

pub fn currency_symbols_with_newlines_are_rejected_before_cache_lookup_test() {
  use url, cache_calls <- with_router

  list.each(
    [
      "BTC%0A",
      "BTC%0D%0A",
      "BTC%0D",
      "BTC%0A%0A",
      "%0ABTC",
      "B%0ATC",
    ],
    fn(symbol) {
      let response = get(url <> "?symbol=" <> symbol)
      assert_bad_request(
        response,
        "'symbol' should only include one or more alphanumeric characters.",
      )
      assert process.receive(cache_calls, 0) == Error(Nil)
    },
  )
}

pub fn valid_currency_symbols_reach_the_cache_unchanged_test() {
  use url, cache_calls <- with_router

  list.each(["BTC", "btc", "1INCH"], fn(symbol) {
    let response = get(url <> "?symbol=" <> symbol)

    assert response.status == 200
    assert response.get_header(response, "content-type")
      == Ok("application/json; charset=utf-8")
    assert json.parse(response.body, decode.list(currency.decoder()))
      == Ok([fixture_currency(symbol)])
    assert process.receive(cache_calls, 1000) == Ok(Read(symbol))
    assert process.receive(cache_calls, 0) == Error(Nil)
  })
}

pub fn missing_empty_and_invalid_currency_symbol_errors_are_preserved_test() {
  use url, cache_calls <- with_router

  list.each(["", "?symbol="], fn(query) {
    assert_bad_request(
      get(url <> query),
      "Query parameter 'symbol' is required.",
    )
    assert process.receive(cache_calls, 0) == Error(Nil)
  })

  list.each(["BTC!", "BTC%20", "%20BTC", "B%20TC", "BT%C3%87"], fn(symbol) {
    assert_bad_request(
      get(url <> "?symbol=" <> symbol),
      "'symbol' should only include one or more alphanumeric characters.",
    )
    assert process.receive(cache_calls, 0) == Error(Nil)
  })
}

fn with_router(run: fn(String, Subject(CacheCall)) -> a) -> a {
  let cache_calls = process.new_subject()
  let cache_ready = process.new_subject()
  let cache_owner =
    process.spawn(fn() {
      let assert Ok(cache) =
        currency_symbol_cache.new(
          fn(symbol) {
            process.send(cache_calls, Read(symbol))
            [fixture_currency(symbol)]
          },
          fn(symbol) {
            process.send(cache_calls, Fetch(symbol))
            Error(Nil)
          },
        )
      process.send(cache_ready, cache)
      process.sleep_forever()
    })
  use <- exception.defer(fn() { stop_process(cache_owner) })
  let assert Ok(cache) = process.receive(cache_ready, 1000)

  let services =
    Services(
      currency_repository: CurrencyRepository(
        insert: fn(_) { panic as "Unexpected repository insert" },
        get_by_id: fn(_) { panic as "Unexpected repository ID lookup" },
        get_by_symbol: fn(_) { panic as "Unexpected repository symbol lookup" },
        get_all: fn() { panic as "Unexpected repository catalog lookup" },
      ),
      currency_symbol_cache: cache,
      create_rate_subscriber: fn(_, _) {
        panic as "Unexpected rate subscription"
      },
      logger: logger.new(),
    )
  let ready = process.new_subject()
  let assert Ok(server) =
    router.route_request(_, "router-test-secret", services)
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start
  use <- exception.defer(fn() { stop_process(server.pid) })

  let assert Ok(port) = process.receive(ready, 1000)
  let url = "http://127.0.0.1:" <> int.to_string(port) <> "/api/currencies"
  run(url, cache_calls)
}

fn fixture_currency(symbol: String) -> Currency {
  Crypto(1, "Fixture currency", symbol, None)
}

fn get(url: String) -> Response(String) {
  let assert Ok(req) = request.to(url)
  let assert Ok(response) =
    httpc.configure()
    |> httpc.timeout(1000)
    |> httpc.dispatch(req)
  response
}

fn assert_bad_request(response: Response(String), message: String) {
  assert response.status == 400
  assert response.get_header(response, "content-type")
    == Ok("application/json; charset=utf-8")
  assert json.parse(response.body, decode.at(["error"], decode.string))
    == Ok(message)
}

fn stop_process(pid) {
  process.unlink(pid)
  let monitor = process.monitor(pid)
  process.kill(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)
  Nil
}
