import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/rates/rate_request.{type RateRequest}
import shared/rates/rate_response.{type RateResponse}
import shared/subscriptions/subscription_id.{type SubscriptionId}

/// Messages the server sends over the application's WebSocket connection.
pub type WebsocketResponse {
  /// A successful rate lookup for a subscription. The rate may be absent when
  /// the price is not tracked; that is a valid result rather than a failure.
  SubscriptionUpdate(id: SubscriptionId, rate_response: RateResponse)
  /// A failed rate lookup, identified by subscription ID and requested pair.
  /// Clients should match both before applying the error so that a response for
  /// a previous currency selection does not affect the current converter.
  SubscriptionFailed(
    id: SubscriptionId,
    rate_request: RateRequest,
    error: SubscriptionError,
  )
  /// The server could not decode a WebSocket request, so the error cannot be
  /// reliably associated with a specific subscription.
  ProtocolError
}

/// Public failure reasons for a specific rate subscription.
///
/// These reasons let the client explain the failure and recovery behavior while
/// detailed provider diagnostics remain in server logs.
pub type SubscriptionError {
  /// The currency ID is missing from the server's current currency catalogue.
  /// This does not imply permanent unavailability. The server clears the
  /// subscription, so another subscription request is needed to try again.
  CurrencyNotFound(currency_id: Int)
  /// A rate could not be obtained from the rate provider. The subscription
  /// remains active, and the server retries on its normal refresh schedule.
  RateUnavailable
}

pub fn encode(response: WebsocketResponse) -> Json {
  case response {
    SubscriptionUpdate(id, rate_resp) ->
      json.object([
        #("type", json.string("subscription_update")),
        #("id", subscription_id.encode(id)),
        #("rate_response", rate_response.encode(rate_resp)),
      ])
    SubscriptionFailed(id, request, error) ->
      json.object([
        #("type", json.string("subscription_error")),
        #("id", subscription_id.encode(id)),
        #("rate_request", rate_request.encode(request)),
        #("error", encode_error(error)),
      ])
    ProtocolError ->
      json.object([
        #("type", json.string("protocol_error")),
        #("error", json.object([#("code", json.string("invalid_request"))])),
      ])
  }
}

fn encode_error(error: SubscriptionError) -> Json {
  case error {
    CurrencyNotFound(id) ->
      json.object([
        #("code", json.string("currency_not_found")),
        #("currency_id", json.int(id)),
      ])
    RateUnavailable -> json.object([#("code", json.string("rate_unavailable"))])
  }
}

pub fn decoder() -> Decoder(WebsocketResponse) {
  use kind <- decode.field("type", decode.string)
  case kind {
    "subscription_update" -> {
      use id <- decode.field("id", subscription_id.decoder())
      use rate_resp <- decode.field("rate_response", rate_response.decoder())
      decode.success(SubscriptionUpdate(id, rate_resp))
    }
    "subscription_error" -> {
      use id <- decode.field("id", subscription_id.decoder())
      use request <- decode.field("rate_request", rate_request.decoder())
      use error <- decode.field("error", error_decoder())
      decode.success(SubscriptionFailed(id, request, error))
    }
    "protocol_error" -> {
      use code <- decode.subfield(["error", "code"], decode.string)
      case code {
        "invalid_request" -> decode.success(ProtocolError)
        _ -> decode.failure(ProtocolError, "ProtocolError")
      }
    }
    _ -> decode.failure(ProtocolError, "WebsocketResponse")
  }
}

fn error_decoder() -> Decoder(SubscriptionError) {
  use code <- decode.field("code", decode.string)
  case code {
    "currency_not_found" -> {
      use id <- decode.field("currency_id", decode.int)
      decode.success(CurrencyNotFound(id))
    }
    "rate_unavailable" -> decode.success(RateUnavailable)
    _ -> decode.failure(RateUnavailable, "SubscriptionError")
  }
}
