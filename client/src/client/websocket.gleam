import client/browser/document
import gleam/option.{None, Some}
import gleam/result
import gleam/uri.{Uri}
import lustre/effect.{type Effect}

pub type WebSocket

pub type WebSocketEvent {
  InvalidUrl
  OnOpen(WebSocket)
  OnTextMessage(String)
  OnClose(WebSocketCloseReason)
}

pub type WebSocketCloseReason {
  Normal
  GoingAway
  ProtocolError
  UnexpectedTypeOfData
  NoCodeFromServer
  AbnormalClose
  IncomprehensibleFrame
  PolicyViolated
  MessageTooBig
  FailedExtensionNegotation
  UnexpectedFailure
  FailedTLSHandshake
  Other(Int)
}

fn code_to_reason(code: Int) -> WebSocketCloseReason {
  case code {
    1000 -> Normal
    1001 -> GoingAway
    1002 -> ProtocolError
    1003 -> UnexpectedTypeOfData
    1005 -> NoCodeFromServer
    1006 -> AbnormalClose
    1007 -> IncomprehensibleFrame
    1008 -> PolicyViolated
    1009 -> MessageTooBig
    1010 -> FailedExtensionNegotation
    1011 -> UnexpectedFailure
    1015 -> FailedTLSHandshake
    _ -> Other(code)
  }
}

/// Initialize a websocket. These constructs are fully asynchronous, so you must provide a wrapper
/// that takes a `WebSocketEvent` and turns it into a lustre message of your application.
/// If the path given is a URL, that is used.
/// If the path is an absolute path, host and port are taken from
/// document.URL, and scheme will become ws for http and wss for https.
/// If the path is a relative path, ditto, but the the path will be
/// relative to the path from document.URL
pub fn init(path: String, wrapper: fn(WebSocketEvent) -> a) -> Effect(a) {
  effect.from(fn(dispatch) {
    case get_websocket_path(path) {
      Ok(url) ->
        do_init(
          url,
          fn(ws) { dispatch(wrapper(OnOpen(ws))) },
          fn(text) { dispatch(wrapper(OnTextMessage(text))) },
          fn(code) {
            code
            |> code_to_reason
            |> OnClose
            |> wrapper
            |> dispatch
          },
        )

      _ ->
        InvalidUrl
        |> wrapper
        |> dispatch
    }
  })
}

pub fn get_websocket_path(path: String) -> Result(String, Nil) {
  let path_uri =
    path
    |> uri.parse
    |> result.unwrap(Uri(
      scheme: None,
      userinfo: None,
      host: None,
      port: None,
      path: path,
      query: None,
      fragment: None,
    ))

  use page_uri <- result.try(uri.parse(document.get_document_url()))
  use resolved_uri <- result.try(uri.merge(page_uri, path_uri))
  use http_scheme <- result.try(option.to_result(resolved_uri.scheme, Nil))
  use ws_scheme <- result.try(convert_scheme(http_scheme))

  Uri(..resolved_uri, scheme: Some(ws_scheme))
  |> uri.to_string
  |> Ok
}

fn convert_scheme(scheme: String) -> Result(String, Nil) {
  case scheme {
    "https" -> Ok("wss")
    "http" -> Ok("ws")
    "ws" | "wss" -> Ok(scheme)
    _ -> Error(Nil)
  }
}

/// Send a text message over the web socket. This is asynchronous. There is no
/// expectation of a reply. See `init`. Only works on a Non-Closed socket.
/// Returns a `Effect(a)` that you must pass as second entry in the lustre `update` return.
pub fn send(ws: WebSocket, msg: String) -> Effect(a) {
  effect.from(fn(_) { do_send(ws, msg) })
}

@external(javascript, "../socket_ffi.mjs", "initSocket")
fn do_init(
  url: String,
  on_open: fn(WebSocket) -> Nil,
  on_message: fn(String) -> Nil,
  on_close: fn(Int) -> Nil,
) -> Nil

@external(javascript, "../socket_ffi.mjs", "sendOverSocket")
fn do_send(ws: WebSocket, msg: String) -> Nil
