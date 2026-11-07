import birdie
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import shared/numbers/positive_float
import shared/rates/rate_request.{RateRequest}
import shared/rates/rate_response.{Kraken, RateResponse}
import shared/subscriptions/subscription_id
import shared/websocket_response.{
  CurrencyNotFound, ProtocolError, RateUnavailable, SubscriptionFailed,
  SubscriptionUpdate,
}

pub fn all_response_variants_round_trip_test() {
  let id = subscription_id.from_string_unsafe("converter-1")
  let request = RateRequest(1, 2781)

  [
    SubscriptionUpdate(
      id,
      RateResponse(
        1,
        2781,
        Some(positive_float.from_float_unsafe(100.0)),
        Kraken,
        123,
      ),
    ),
    SubscriptionUpdate(id, RateResponse(1, 2781, None, Kraken, 123)),
    SubscriptionFailed(id, request, CurrencyNotFound(2781)),
    SubscriptionFailed(id, request, RateUnavailable),
    ProtocolError,
  ]
  |> list.each(fn(response) {
    assert response
      |> websocket_response.encode
      |> json.to_string
      |> json.parse(websocket_response.decoder())
      == Ok(response)
  })
}

pub fn encode_subscription_update_test() {
  let update =
    SubscriptionUpdate(
      subscription_id.from_string_unsafe("converter-1"),
      RateResponse(
        1,
        2781,
        Some(positive_float.from_float_unsafe(1.23)),
        Kraken,
        123,
      ),
    )

  update
  |> websocket_response.encode
  |> json.to_string
  |> birdie.snap("encode_subscription_update_test")
}

pub fn encode_currency_not_found_test() {
  let error =
    SubscriptionFailed(
      subscription_id.from_string_unsafe("converter-1"),
      RateRequest(1, 2781),
      CurrencyNotFound(2781),
    )
  error
  |> websocket_response.encode
  |> json.to_string
  |> birdie.snap("encode_currency_not_found_test")
}

pub fn encode_rate_unavailable_test() {
  SubscriptionFailed(
    subscription_id.from_string_unsafe("converter-1"),
    RateRequest(1, 2781),
    RateUnavailable,
  )
  |> websocket_response.encode
  |> json.to_string
  |> birdie.snap("encode_rate_unavailable_test")
}

pub fn encode_protocol_error_test() {
  ProtocolError
  |> websocket_response.encode
  |> json.to_string
  |> birdie.snap("encode_protocol_error_test")
}

pub fn malformed_and_unknown_responses_are_rejected_test() {
  [
    "Unexpected error getting rate",
    "{}",
    "{\"type\":\"unknown\"}",
    "{\"type\":123}",
    "{\"id\":\"converter-1\",\"rate_response\":{\"from\":1,\"to\":2781,\"rate\":100.0,\"source\":\"Kraken\",\"timestamp\":123}}",
    "{\"type\":\"success\",\"id\":\"converter-1\",\"rate_response\":{\"from\":1,\"to\":2781,\"rate\":100.0,\"source\":\"Kraken\",\"timestamp\":123}}",
    "{\"type\":\"subscription_update\"}",
    "{\"type\":\"subscription_error\",\"error\":{\"code\":\"rate_unavailable\"}}",
    "{\"type\":\"subscription_error\",\"id\":\"converter-1\",\"error\":{\"code\":\"rate_unavailable\"}}",
    "{\"type\":\"subscription_error\",\"id\":\"converter-1\",\"rate_request\":{\"from\":1,\"to\":2781},\"error\":{\"code\":\"unknown\"}}",
    "{\"type\":\"subscription_error\",\"id\":\"converter-1\",\"rate_request\":{\"from\":1,\"to\":2781},\"error\":{\"code\":\"currency_not_found\"}}",
    "{\"type\":\"protocol_error\",\"error\":{\"code\":\"unknown\"}}",
  ]
  |> list.each(fn(payload) {
    let assert Error(_) = json.parse(payload, websocket_response.decoder())
  })
}
