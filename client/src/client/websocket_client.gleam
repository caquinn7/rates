import client/websocket.{type WebSocket}
import gleam/json
import lustre/effect.{type Effect}
import shared/currency.{type Currency}
import shared/rates/rate_request.{type RateRequest}
import shared/subscriptions/subscription_id.{type SubscriptionId}
import shared/subscriptions/subscription_request.{SubscriptionRequest}
import shared/websocket_request.{
  type WebsocketRequest, AddCurrencies, Subscribe, Unsubscribe,
}

pub fn subscribe_to_rate(
  socket: WebSocket,
  subscription_id: SubscriptionId,
  rate_request: RateRequest,
) -> Effect(a) {
  [SubscriptionRequest(subscription_id, rate_request)]
  |> Subscribe
  |> send(socket, _)
}

pub fn unsubscribe_from_rate(
  socket: WebSocket,
  subscription_id: SubscriptionId,
) -> Effect(a) {
  subscription_id
  |> Unsubscribe
  |> send(socket, _)
}

pub fn add_currencies(
  socket: WebSocket,
  currencies: List(Currency),
) -> Effect(a) {
  currencies
  |> AddCurrencies
  |> send(socket, _)
}

fn send(socket: WebSocket, request: WebsocketRequest) -> Effect(a) {
  request
  |> websocket_request.encode
  |> json.to_string
  |> websocket.send(socket, _)
}
