// import gleam/dict.{type Dict}
// import gleam/erlang/process.{type Subject, Normal}
// import gleam/int
// import gleam/list
// import gleam/otp/actor.{type Next, type StartError, Stop}
// import gleam/result
// import gleam/string
// import server/kraken/kraken_actor.{type KrakenActor}
// import server/kraken/pairs
// import server/kraken/price_store.{type PriceStore}
// import server/rates/cmc_rate_handler.{
//   type RequestCmcConversion, CurrencyNotFound, RequestFailed, UnexpectedResponse,
//   ValidationError,
// }
// import shared/currency.{type Currency}
// import shared/rates/rate_request.{type RateRequest}
// import shared/rates/rate_response.{type RateResponse}

// pub opaque type RateActor {
//   RateActor(Subject(Msg))
// }

// type State {
//   Idle(
//     reply_to: Subject(Result(RateResponse, String)),
//     cmc_currencies: Dict(Int, String),
//     kraken: KrakenActor,
//     price_store: PriceStore,
//   )
//   Subscribed(
//     reply_to: Subject(Result(RateResponse, String)),
//     cmc_currencies: Dict(Int, String),
//     kraken: KrakenActor,
//     price_store: PriceStore,
//     subscription: Subscription,
//   )
// }

// type Msg {
//   Subscribe(RateRequest)
//   GetLatestRate
//   Unsubscribe
// }

// type Subscription {
//   Kraken(KrakenSubscription)
//   Cmc(RateRequest)
// }

// type KrakenSubscription {
//   KrakenSubscription(
//     // base + quote IDs (user intent)
//     request: RateRequest,
//     // actual Kraken symbol subscribed to
//     symbol: String,
//     // whether price needs inversion
//     direction: SubscriptionDirection,
//   )
// }

// type SubscriptionDirection {
//   Direct
//   Reverse
// }

// pub fn new(
//   reply_to: Subject(Result(RateResponse, String)),
//   cmc_currencies: List(Currency),
//   request_cmc_conversion: RequestCmcConversion,
//   kraken: KrakenActor,
//   get_price_store: fn() -> PriceStore,
// ) -> Result(RateActor, StartError) {
//   let currency_dict =
//     cmc_currencies
//     |> list.map(fn(c) { #(c.id, c.symbol) })
//     |> dict.from_list

//   let price_store = get_price_store()

//   let initial_state = Idle(reply_to, currency_dict, kraken, price_store)
//   let loop = fn(msg, state) { handle_msg(msg, state, request_cmc_conversion) }

//   initial_state
//   |> actor.start(loop)
//   |> result.map(RateActor)
// }

// /// Starts a loop that sends `GetLatestRate` to the actor every `interval` milliseconds.
// /// This is used to keep a rate subscription updated over time.
// pub fn start_polling(rate_actor: RateActor, interval: Int) {
//   let RateActor(subject) = rate_actor
//   process.start(fn() { polling_loop(subject, interval) }, True)
//   Nil
// }

// fn polling_loop(subject: Subject(Msg), interval: Int) -> Nil {
//   process.send(subject, GetLatestRate)
//   process.sleep(interval)
//   polling_loop(subject, interval)
// }

// pub fn subscribe(rate_actor: RateActor, rate_request: RateRequest) -> Nil {
//   let RateActor(rate_actor_subject) = rate_actor
//   actor.send(rate_actor_subject, Subscribe(rate_request))
// }

// pub fn unsubscribe(rate_actor: RateActor) -> Nil {
//   let RateActor(rate_actor_subject) = rate_actor
//   actor.send(rate_actor_subject, Unsubscribe)
// }

// fn handle_msg(
//   msg: Msg,
//   state: State,
//   request_cmc_conversion: RequestCmcConversion,
// ) -> Next(Msg, State) {
//   case msg {
//     // todo: unsubscribe from current RateRequest or wait until multiple subs per client are supported
//     // todo: if initial kraken response after subscription proves to be consistently immediate,
//     // then maybe refactor to wait and send back to the client rather than CMC fallback
//     Subscribe(rate_req) -> {
//       case resolve_kraken_subscription(rate_req, state.cmc_currencies) {
//         Ok(Kraken(subscription)) -> {
//           kraken_actor.subscribe(state.kraken, subscription.symbol)
//           resolve_kraken_price(state, subscription, request_cmc_conversion)
//         }
//         _ -> handle_cmc_fallback(state, rate_req, request_cmc_conversion)
//       }
//     }

//     GetLatestRate -> {
//       case state {
//         Idle(..) -> actor.continue(state)

//         Subscribed(_, cmc_currencies, _, price_store, subscription) -> {
//           case subscription {
//             Kraken(sub) ->
//               resolve_kraken_price(state, sub, request_cmc_conversion)

//             Cmc(rate_req) -> {
//               // Try resolving a supported Kraken symbol first
//               case resolve_kraken_subscription(rate_req, cmc_currencies) {
//                 Ok(Kraken(sub)) -> {
//                   // Only if it's supported, check if price is now available
//                   case price_store.get_price(price_store, sub.symbol) {
//                     Ok(_) -> {
//                       // Promote to Kraken subscription
//                       resolve_kraken_price(state, sub, request_cmc_conversion)
//                     }

//                     Error(_) -> {
//                       // Still no price; continue using CMC
//                       handle_cmc_fallback(
//                         state,
//                         rate_req,
//                         request_cmc_conversion,
//                       )
//                     }
//                   }
//                 }

//                 _ -> {
//                   // Not even a supported Kraken symbol
//                   handle_cmc_fallback(state, rate_req, request_cmc_conversion)
//                 }
//               }
//             }
//           }
//         }
//       }
//     }

//     Unsubscribe -> {
//       case state {
//         Idle(..) -> Stop(Normal)

//         Subscribed(_, _, kraken, _, subscription) -> {
//           case subscription {
//             Kraken(kraken_sub) -> {
//               kraken_actor.unsubscribe(kraken, kraken_sub.symbol)
//               Stop(Normal)
//             }

//             Cmc(_) -> Stop(Normal)
//           }
//         }
//       }
//     }
//   }
// }

// fn resolve_kraken_subscription(
//   rate_req: RateRequest,
//   currencies: Dict(Int, String),
// ) -> Result(Subscription, Nil) {
//   use from_symbol <- result.try(dict.get(currencies, rate_req.from))
//   use to_symbol <- result.try(dict.get(currencies, rate_req.to))

//   let user_facing_symbol = from_symbol <> "/" <> to_symbol
//   let reverse_symbol = to_symbol <> "/" <> from_symbol

//   case pairs.exists(user_facing_symbol), pairs.exists(reverse_symbol) {
//     True, _ ->
//       Ok(
//         Kraken(KrakenSubscription(
//           request: rate_req,
//           symbol: user_facing_symbol,
//           direction: Direct,
//         )),
//       )

//     False, True ->
//       Ok(
//         Kraken(KrakenSubscription(
//           request: rate_req,
//           symbol: reverse_symbol,
//           direction: Reverse,
//         )),
//       )

//     _, _ -> Error(Nil)
//   }
// }

// fn handle_cmc_fallback(
//   state: State,
//   rate_req: RateRequest,
//   request_cmc_conversion: RequestCmcConversion,
// ) -> Next(Msg, State) {
//   let result = get_cmc_rate(rate_req, request_cmc_conversion)

//   process.send(state.reply_to, result)

//   actor.continue(Subscribed(
//     state.reply_to,
//     state.cmc_currencies,
//     state.kraken,
//     state.price_store,
//     Cmc(rate_req),
//   ))
// }

// fn resolve_kraken_price(
//   state: State,
//   subscription: KrakenSubscription,
//   request_cmc_conversion: RequestCmcConversion,
// ) -> Next(Msg, State) {
//   let result = price_store.get_price(state.price_store, subscription.symbol)

//   case result {
//     Error(_) ->
//       handle_cmc_fallback(state, subscription.request, request_cmc_conversion)

//     Ok(price) -> {
//       let adjusted_price = case subscription.direction {
//         Direct -> price
//         Reverse -> 1.0 /. price
//       }

//       let response =
//         rate_response.RateResponse(
//           subscription.request.from,
//           subscription.request.to,
//           adjusted_price,
//         )

//       process.send(state.reply_to, Ok(response))

//       actor.continue(Subscribed(
//         state.reply_to,
//         state.cmc_currencies,
//         state.kraken,
//         state.price_store,
//         Kraken(subscription),
//       ))
//     }
//   }
// }

// fn get_cmc_rate(
//   rate_request: RateRequest,
//   request_cmc_conversion: RequestCmcConversion,
// ) -> Result(RateResponse, String) {
//   rate_request
//   |> cmc_rate_handler.get_rate(request_cmc_conversion)
//   |> result.map_error(fn(rate_req_err) {
//     case rate_req_err {
//       ValidationError(msg) -> msg
//       CurrencyNotFound(id) -> "cmc currency id not found: " <> int.to_string(id)
//       RequestFailed(err) -> "cmc request failed: " <> string.inspect(err)
//       UnexpectedResponse(err) ->
//         "unexpected response from cmc: " <> string.inspect(err)
//     }
//   })
// }
