import gleam/dynamic/decode.{type Decoder}
import server/subscriptions/subscription_request
import shared/currency.{type Currency}
import shared/subscriptions/subscription_id.{type SubscriptionId}
import shared/subscriptions/subscription_request.{type SubscriptionRequest} as _shared_sub_request

pub type WebsocketRequest {
  Subscribe(List(SubscriptionRequest))
  Unsubscribe(SubscriptionId)
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
      use subscription_id <- decode.subfield(
        ["body", "id"],
        subscription_id.decoder(),
      )
      decode.success(Unsubscribe(subscription_id))
    }

    "add_currencies" -> {
      use body <- decode.field("body", decode.list(currency.decoder()))
      decode.success(AddCurrencies(body))
    }

    _ -> decode.failure(Subscribe([]), "WebsocketRequest")
  }
}
