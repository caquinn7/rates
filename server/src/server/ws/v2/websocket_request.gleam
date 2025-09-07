import gleam/dynamic/decode.{type Decoder}
import server/subscriptions/subscription_request
import shared/currency.{type Currency}
import shared/subscriptions/subscription_request.{type SubscriptionRequest} as _shared_sub_request
import shared/subscriptions/subscription_response.{type SubscriptionResponse} as _shared_sub_response

pub type WebsocketRequest {
  Subscribe(List(SubscriptionRequest))
  Unsubscribe(subscription_id: String)
  AddCurrencies(List(Currency))
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
      use subscription_id <- decode.subfield(["body", "id"], decode.string)
      decode.success(Unsubscribe(subscription_id))
    }

    "add_currencies" -> {
      use body <- decode.field("body", decode.list(currency.decoder()))
      decode.success(AddCurrencies(body))
    }

    _ -> decode.failure(Subscribe([]), "WebsocketRequest")
  }
}

pub type WebsocketResponse {
  Subscribed(List(SubscriptionResponse))
  Unsubscribed(subscription_id: String)
}
