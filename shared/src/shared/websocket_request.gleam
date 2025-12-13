import gleam/dynamic/decode.{type Decoder}
import gleam/json.{type Json}
import shared/subscriptions/subscription_id.{type SubscriptionId}
import shared/subscriptions/subscription_request.{type SubscriptionRequest}

pub type WebsocketRequest {
  Subscribe(List(SubscriptionRequest))
  Unsubscribe(SubscriptionId)
}

pub fn encode(websocket_request: WebsocketRequest) -> Json {
  case websocket_request {
    Subscribe(subscription_requests) ->
      json.object([
        #("action", json.string("subscribe")),
        #(
          "body",
          json.array(subscription_requests, subscription_request.encode),
        ),
      ])

    Unsubscribe(subscription_id) ->
      json.object([
        #("action", json.string("unsubscribe")),
        #(
          "body",
          json.object([#("id", subscription_id.encode(subscription_id))]),
        ),
      ])
  }
}

pub fn decoder() -> Decoder(WebsocketRequest) {
  use action <- decode.field("action", decode.string)

  case action {
    "subscribe" -> {
      use body <- decode.field(
        "body",
        decode.list(subscription_request.decoder()),
      )
      decode.success(Subscribe(body))
    }

    "unsubscribe" -> {
      use subscription_id <- decode.subfield(
        ["body", "id"],
        subscription_id.decoder(),
      )
      decode.success(Unsubscribe(subscription_id))
    }

    _ -> decode.failure(Subscribe([]), "WebsocketRequest")
  }
}
