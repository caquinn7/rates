import exception
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/option.{None}
import gleam/otp/actor
import mist
import server/integrations/kraken/client
import server/integrations/kraken/price_store
import server/utils/logger

pub fn startup_waits_for_websocket_handshake_test() {
  let handler = fn(req) {
    process.sleep(250)
    mist.websocket(
      req,
      on_init: fn(_) { #(Nil, None) },
      handler: fn(state, _, _) { mist.continue(state) },
      on_close: fn(_) { Nil },
    )
  }
  use url <- with_server(handler)

  let owner = process.new_subject()
  use <- exception.defer(fn() {
    case process.receive(owner, 0) {
      Ok(pid) -> stop_process(pid)
      Error(_) -> Nil
    }
  })

  let create_store = fn() {
    let assert Ok(store) = price_store.new()
    process.send(owner, process.self())
    store
  }

  let assert Ok(_) = client.new_with_url(logger.new(), create_store, url)
}

pub fn startup_returns_websocket_handshake_failure_test() {
  let handler = fn(_) {
    process.sleep(250)
    response.new(503)
    |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
  use url <- with_server(handler)

  let create_store = fn() {
    panic as "Price store must not be created after a failed handshake"
  }

  let assert Error(actor.InitFailed(_)) =
    client.new_with_url(logger.new(), create_store, url)
}

fn with_server(handler, run) {
  let ready = process.new_subject()
  let assert Ok(server) =
    handler
    |> mist.new
    |> mist.bind("127.0.0.1")
    |> mist.port(0)
    |> mist.after_start(fn(port, _, _) { process.send(ready, port) })
    |> mist.start

  use <- exception.defer(fn() { stop_process(server.pid) })

  let assert Ok(port) = process.receive(ready, 1000)
  run("http://127.0.0.1:" <> int.to_string(port) <> "/ws")
}

fn stop_process(pid: process.Pid) {
  process.unlink(pid)
  let monitor = process.monitor(pid)
  process.kill(pid)

  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
    |> process.selector_receive(1000)

  Nil
}
