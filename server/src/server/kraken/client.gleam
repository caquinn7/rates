// import gleam/erlang/process.{type Subject}
// import gleam/http/request as http_request
// import gleam/json
// import gleam/list
// import gleam/option.{type Option, None}
// import gleam/otp/actor.{type Next, type StartError}
// import server/kraken/currency_pair.{type CurrencyPair}
// import server/kraken/request.{
//   type KrakenRequest, Instruments, KrakenRequest, Subscribe, Tickers,
//   Unsubscribe,
// }
// import server/kraken/response.{type KrakenResponse}
// import stratus.{
//   type Connection, type InternalMessage, type Message, Binary, Text, User,
// }

// pub type Msg {
//   Request(KrakenRequest)
// }

// pub fn new(
//   receiver: Subject(KrakenResponse),
// ) -> Result(Subject(InternalMessage(Msg)), StartError) {
//   let assert Ok(req) = http_request.to("https://ws.kraken.com/v2")

//   stratus.websocket(
//     request: req,
//     init: fn() { #(Nil, None) },
//     loop: fn(msg, state, conn) { message_handler(receiver, msg, state, conn) },
//   )
//   |> stratus.on_close(fn(_state) {
//     echo "kraken socket closed"
//     Nil
//   })
//   |> stratus.initialize
// }

// fn message_handler(
//   receiver: Subject(KrakenResponse),
//   msg: Message(Msg),
//   state: Nil,
//   conn: Connection,
// ) -> Next(Msg, Nil) {
//   case msg {
//     Text(response_str) ->
//       case json.parse(response_str, response.decoder()) {
//         Error(_) -> actor.continue(state)

//         Ok(kraken_resp) -> {
//           process.send(receiver, kraken_resp)
//           actor.continue(state)
//         }
//       }

//     User(Request(kraken_req)) -> {
//       let json_str =
//         kraken_req
//         |> request.encode
//         |> json.to_string

//       case stratus.send_text_message(conn, json_str) {
//         Error(err) -> {
//           echo "failed to send message to kraken:"
//           echo err
//           actor.continue(state)
//         }
//         Ok(_) -> actor.continue(state)
//       }
//     }

//     Binary(_) -> actor.continue(state)
//   }
// }

// pub fn subscribe_to_instruments(
//   client: Subject(InternalMessage(Msg)),
//   request_id: Option(Int),
// ) -> Nil {
//   let kraken_req = KrakenRequest(Subscribe, Instruments, request_id)
//   actor.send(client, stratus.to_user_message(Request(kraken_req)))
// }

// pub fn unsubscribe_to_instruments(
//   client: Subject(InternalMessage(Msg)),
//   request_id: Option(Int),
// ) -> Nil {
//   let kraken_req = KrakenRequest(Unsubscribe, Instruments, request_id)
//   actor.send(client, stratus.to_user_message(Request(kraken_req)))
// }

// pub fn subscribe_to_tickers(
//   client: Subject(InternalMessage(Msg)),
//   currency_pairs: List(CurrencyPair),
//   request_id: Option(Int),
// ) -> Nil {
//   currency_pairs
//   |> list.map(currency_pair.to_symbol)
//   |> Tickers
//   |> KrakenRequest(Subscribe, _, request_id)
//   |> Request
//   |> stratus.to_user_message
//   |> actor.send(client, _)
// }

// pub fn unsubscribe_to_tickers(
//   client: Subject(InternalMessage(Msg)),
//   currency_pairs: List(CurrencyPair),
//   request_id: Option(Int),
// ) -> Nil {
//   currency_pairs
//   |> list.map(currency_pair.to_symbol)
//   |> Tickers
//   |> KrakenRequest(Unsubscribe, _, request_id)
//   |> Request
//   |> stratus.to_user_message
//   |> actor.send(client, _)
// }
