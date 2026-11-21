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
import server/utils/time
import stratus

/// Handle for queuing Kraken requests on a WebSocket connection.
pub opaque type Socket {
  Socket(Subject(stratus.InternalMessage(SocketMessage)))
}

/// Internal messages for sending requests and checking inbound inactivity.
type SocketMessage {
  /// Encodes a Kraken request and sends it as a WebSocket text message.
  SendRequest(KrakenRequest)

  /// Checks the inactivity deadline and either schedules the next check or
  /// stops the socket.
  CheckInactivity
}

/// Tracks inbound activity for a single WebSocket connection.
type SocketState {
  SocketState(
    /// Socket-owned subject that receives scheduled inactivity checks.
    self: Subject(SocketMessage),
    /// Monotonic timestamp in milliseconds, set after the handshake and
    /// updated on every inbound text message.
    last_inbound_ms: Int,
  )
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
  inactivity_timeout_ms: Int,
  send_text: SendText,
) -> Pid {
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let owner_monitor = process.monitor(owner)

    case
      connect(
        url,
        connect_timeout_ms,
        inactivity_timeout_ms,
        notify,
        logger,
        send_text,
      )
    {
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
  |> SendRequest
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
  inactivity_timeout_ms: Int,
  notify: fn(Event) -> Nil,
  logger: Logger,
  send_text: SendText,
) -> Result(
  actor.Started(Subject(stratus.InternalMessage(SocketMessage))),
  String,
) {
  use req <- result.try(
    url
    |> http_request.to
    |> result.map_error(string.inspect),
  )

  req
  |> stratus.new_with_initialiser(fn() {
    let self = process.new_subject()
    let last_inbound_ms = time.monotonic_time_ms()
    let _ = process.send_after(self, inactivity_timeout_ms, CheckInactivity)
    let selector =
      process.new_selector()
      |> process.select(self)

    SocketState(self:, last_inbound_ms:)
    |> stratus.initialised
    |> stratus.selecting(selector)
    |> Ok
  })
  |> stratus.with_connect_timeout(connect_timeout_ms)
  |> stratus.on_message(fn(state, message, conn) {
    handle_message(
      state,
      message,
      conn,
      notify,
      logger,
      send_text,
      inactivity_timeout_ms,
    )
  })
  |> stratus.on_close(fn(_, reason) {
    logger
    |> logger.with("reason", string.inspect(reason))
    |> logger.info("Kraken socket closed")
  })
  |> stratus.start
  |> result.map_error(string.inspect)
}

/// Records inbound text activity before decoding. Forwards recognized
/// responses through `Received` and logs decode errors with a response excerpt.
/// The socket stops on inactivity or a write error so the worker can report
/// the failure.
fn handle_message(
  state: SocketState,
  message: stratus.Message(SocketMessage),
  conn: stratus.Connection,
  notify: fn(Event) -> Nil,
  logger: Logger,
  send_text: SendText,
  inactivity_timeout_ms: Int,
) -> stratus.Next(SocketState, SocketMessage) {
  case message {
    stratus.Text(text) -> {
      let state =
        SocketState(..state, last_inbound_ms: time.monotonic_time_ms())

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

    stratus.User(SendRequest(message)) -> {
      let text =
        message
        |> request.encode
        |> json.to_string

      case send_text(TextSender(conn), text) {
        Ok(_) -> stratus.continue(state)
        Error(reason) -> stratus.stop_abnormal(reason)
      }
    }

    stratus.User(CheckInactivity) -> {
      let idle_ms = time.monotonic_time_ms() - state.last_inbound_ms
      let remaining_ms = inactivity_timeout_ms - idle_ms
      case remaining_ms <= 0 {
        True -> stratus.stop_abnormal("Kraken inbound inactivity timeout")
        False -> {
          // Keep one check scheduled. Text frames only update the timestamp.
          let _ = process.send_after(state.self, remaining_ms, CheckInactivity)
          stratus.continue(state)
        }
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
