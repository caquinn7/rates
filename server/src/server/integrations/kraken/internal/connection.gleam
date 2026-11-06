//// Owns one Stratus socket. Socket failures cannot kill the price-store owner.

import gleam/erlang/process.{type Monitor, type Pid, type Subject}
import gleam/http/request as http_request
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import server/integrations/kraken/internal/request.{type KrakenRequest}
import server/integrations/kraken/internal/response.{type KrakenResponse}
import server/utils/logger.{type Logger}
import stratus

/// Handle for queuing Kraken requests on a WebSocket connection.
pub opaque type Socket {
  Socket(Subject(stratus.InternalMessage(KrakenRequest)))
}

/// Transport handle passed to `SendText` while processing a request.
pub opaque type TextSender {
  TextSender(stratus.Connection)
}

/// Sends encoded JSON using a transport handle, returning a failure
/// description if writing fails. Tests can override this to inject send failures.
pub type SendText =
  fn(TextSender, String) -> Result(Nil, String)

/// Notifications sent to the session about a connection attempt and its messages.
pub type Event {
  /// The WebSocket handshake succeeded. Provides a handle for sending Kraken
  /// requests; instrument discovery is still the session's responsibility.
  Connected(Socket)

  /// A WebSocket text message was decoded as a Kraken response.
  /// Unrecognized messages are ignored; malformed responses are logged and
  /// produce no event.
  Received(KrakenResponse)

  /// Connection setup failed or the socket exited. Carries a reason description
  /// so the session can report the failure and decide how to recover.
  Failed(String)
}

/// Monitor notifications identifying which process exited while the worker waits.
type Down {
  /// The session owner exited. Stop the socket and wait for its exit notification
  /// before allowing the worker to finish.
  OwnerDown

  /// The socket exited. Retains the monitor notification so its exit reason can
  /// be logged and reported through `Failed` before the worker finishes.
  SocketDown(process.Down)
}

/// Register the owner monitor before dialing. Once the handshake finishes, an
/// owner exit kills any socket that was created, including during startup.
pub fn start(
  owner: Pid,
  notify: fn(Event) -> Nil,
  logger: Logger,
  url: String,
  connect_timeout_ms: Int,
  send_text: SendText,
) -> Pid {
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let owner_monitor = process.monitor(owner)

    case connect(url, connect_timeout_ms, notify, logger, send_text) {
      Ok(socket) -> {
        let socket_monitor = process.monitor(socket.pid)

        notify(Connected(Socket(socket.data)))

        await_shutdown(
          owner_monitor,
          socket_monitor,
          socket.pid,
          notify,
          logger,
        )
      }

      Error(reason) -> {
        logger
        |> logger.with("reason", reason)
        |> logger.warning("Kraken connection attempt failed")

        notify(Failed(reason))
      }
    }
  })
}

/// Queues a Kraken request for encoding and transmission on this socket.
/// Transport write errors are reported asynchronously through `Failed`.
pub fn send(socket: Socket, message: KrakenRequest) -> Nil {
  let Socket(subject) = socket

  message
  |> stratus.to_user_message
  |> process.send(subject, _)
}

/// Sends a WebSocket text message using the adapter's transport.
/// This is the default `SendText` implementation; errors become descriptions.
pub fn send_text(sender: TextSender, text: String) -> Result(Nil, String) {
  let TextSender(conn) = sender

  conn
  |> stratus.send_text_message(text)
  |> result.map_error(string.inspect)
}

/// Parses `url`, configures the WebSocket callbacks, and starts the connection.
/// Waits for the handshake and returns the socket process and message subject,
/// or a description of the URL or startup error. Monitoring and session
/// notifications about startup success or failure are handled by `start`.
fn connect(
  url: String,
  connect_timeout_ms: Int,
  notify: fn(Event) -> Nil,
  logger: Logger,
  send_text: SendText,
) -> Result(
  actor.Started(Subject(stratus.InternalMessage(KrakenRequest))),
  String,
) {
  use req <- result.try(
    url
    |> http_request.to
    |> result.map_error(string.inspect),
  )

  req
  |> stratus.new(Nil)
  |> stratus.with_connect_timeout(connect_timeout_ms)
  |> stratus.on_message(fn(state, message, conn) {
    handle_message(state, message, conn, notify, logger, send_text)
  })
  |> stratus.on_close(fn(_, reason) {
    logger
    |> logger.with("reason", string.inspect(reason))
    |> logger.info("Kraken socket closed")
  })
  |> stratus.start
  |> result.map_error(string.inspect)
}

/// Handles incoming WebSocket messages and queued Kraken requests.
/// Decodes text responses and forwards them through `Received`. Logs decoding
/// failures with a short response excerpt, while unrecognized response kinds and
/// binary messages stay quiet. Encodes outgoing requests through `send_text`;
/// a write error stops the socket abnormally so its monitor can report the
/// failure. The supplied state is preserved.
fn handle_message(
  state: Nil,
  message: stratus.Message(KrakenRequest),
  conn: stratus.Connection,
  notify: fn(Event) -> Nil,
  logger: Logger,
  send_text: SendText,
) -> stratus.Next(Nil, KrakenRequest) {
  case message {
    stratus.Text(text) -> {
      case json.parse(text, response.decoder()) {
        Ok(Some(message)) -> notify(Received(message))
        Ok(None) -> Nil
        Error(error) ->
          logger
          |> logger.with("reason", string.inspect(error))
          |> logger.with("response", string.slice(text, 0, 512))
          |> logger.warning("Unable to decode Kraken response")
      }
      stratus.continue(state)
    }

    stratus.User(message) -> {
      let text =
        message
        |> request.encode
        |> json.to_string

      case send_text(TextSender(conn), text) {
        Ok(_) -> stratus.continue(state)
        Error(reason) -> stratus.stop_abnormal(reason)
      }
    }

    stratus.Binary(_) -> stratus.continue(state)
  }
}

/// Waits for the session owner or the socket to exit.
///
/// If the owner exits, kills the socket and waits up to one second for its exit
/// notification before allowing the worker to finish. If the socket exits first,
/// logs its exit reason and sends `Failed` before the worker returns normally.
fn await_shutdown(
  owner_monitor: Monitor,
  socket_monitor: Monitor,
  socket_pid: Pid,
  notify: fn(Event) -> Nil,
  logger: Logger,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_) { OwnerDown })
    |> process.select_specific_monitor(socket_monitor, SocketDown)

  case process.selector_receive_forever(selector) {
    OwnerDown -> {
      process.kill(socket_pid)
      // Wait for ownership of the socket to end before reporting exit.
      let _ = process.selector_receive(selector, 1000)
      Nil
    }

    SocketDown(down) -> {
      let reason = case down {
        process.ProcessDown(_, _, reason) -> string.inspect(reason)
        _ -> string.inspect(down)
      }

      logger
      |> logger.with("reason", reason)
      |> logger.warning("Kraken socket process exited")

      // Send the socket's reason before the worker's own normal exit.
      notify(Failed(reason))
    }
  }
}
