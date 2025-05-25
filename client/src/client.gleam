import client/browser/document
import client/browser/element as browser_element
import client/rates/rate_request
import client/rates/rate_response
import client/side.{type Side, Left, Right}
import client/socket.{
  type WebSocket, type WebSocketEvent, InvalidUrl, OnClose, OnOpen,
  OnTextMessage,
}
import client/start_data.{type StartData}
import client/ui/components/auto_resize_input
import client/ui/components/button_dropdown.{type DropdownOption, DropdownOption}
import gleam/dict.{type Dict}
import gleam/dynamic
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/event
import shared/currency.{type Currency, Crypto, Fiat}
import shared/rates/rate_request.{type RateRequest, RateRequest} as _shared_rate_request
import shared/rates/rate_response.{RateResponse} as _shared_rate_response

pub type Model {
  Model(
    currencies: List(Currency),
    conversion: Conversion,
    socket: Option(WebSocket),
  )
}

pub type Conversion {
  Conversion(
    left_input: ConversionInput,
    right_input: ConversionInput,
    rate: Option(Float),
    last_edited: Side,
  )
}

pub type ConversionInput {
  ConversionInput(
    amount_input: String,
    parsed_amount: Option(Float),
    currency_id: Int,
  )
}

pub type Msg {
  WsWrapper(WebSocketEvent)
  UserEnteredAmount(Side, String)
  UserSelectedCurrency(Side, String)
}

pub fn main() {
  let assert Ok(json_str) =
    document.query_selector("#model")
    |> result.map(browser_element.inner_text)

  let start_data = case json.parse(json_str, start_data.decoder()) {
    Ok(start_data) -> start_data
    _ -> panic as "failed to decode start_data"
  }

  let assert Ok(_) = auto_resize_input.register("auto-resize-input")
  let assert Ok(_) = button_dropdown.register("button-dropdown")

  let app = lustre.application(init, update, view)
  let assert Ok(_to_runtime) = lustre.start(app, "#app", start_data)
}

pub fn init(flags: StartData) -> #(Model, Effect(Msg)) {
  #(model_from_start_data(flags), socket.init("/ws", WsWrapper))
}

pub fn model_from_start_data(start_data: StartData) {
  let RateResponse(from, to, rate, _source) = start_data.rate

  let left_input = ConversionInput(float.to_string(1.0), Some(1.0), from)
  let right_input = ConversionInput(float.to_string(rate), Some(rate), to)

  Model(
    start_data.currencies,
    Conversion(left_input:, right_input:, rate: Some(rate), last_edited: Left),
    socket: None,
  )
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    WsWrapper(InvalidUrl) -> panic as "invalid url used to open websocket"

    WsWrapper(OnClose(reason)) -> {
      echo "socket closed. reason: " <> string.inspect(reason)
      // todo as "connection closed. open again? show msg?"
      #(model, effect.none())
    }

    WsWrapper(OnOpen(socket)) -> {
      let effect =
        model
        |> build_rate_request
        |> subscribe_to_rate_updates(socket, _)

      #(Model(..model, socket: Some(socket)), effect)
    }

    WsWrapper(OnTextMessage(msg)) -> {
      case json.parse(msg, rate_response.decoder()) {
        Error(_) -> {
          echo "failed to decode conversion response from server:"
          echo msg
          #(model, effect.none())
        }

        Ok(rate_resp) -> {
          let RateResponse(from, to, rate, _source) = rate_resp

          let assert Ok(_from_currency) =
            model.currencies
            |> list.find(fn(currency) { currency.id == from })

          let assert Ok(_to_currency) =
            model.currencies
            |> list.find(fn(currency) { currency.id == to })

          // •	When rate update comes in:
          // •	If last_edited == Left: recalculate right_input using parsed_amount * rate
          // •	If last_edited == Right: recalculate left_input using parsed_amount / rate

          let conversion = case model.conversion.last_edited {
            Left -> {
              case model.conversion.left_input.parsed_amount {
                Some(left_amount) -> {
                  let right_amount = left_amount *. rate
                  let right_input =
                    ConversionInput(
                      ..model.conversion.right_input,
                      amount_input: float.to_string(right_amount),
                      parsed_amount: Some(right_amount),
                    )
                  Conversion(..model.conversion, right_input:, rate: Some(rate))
                }

                _ -> Conversion(..model.conversion, rate: Some(rate))
              }
            }

            Right -> {
              case model.conversion.right_input.parsed_amount {
                Some(right_amount) -> {
                  let left_amount = right_amount /. rate
                  let left_input =
                    ConversionInput(
                      ..model.conversion.left_input,
                      amount_input: float.to_string(left_amount),
                      parsed_amount: Some(left_amount),
                    )
                  Conversion(..model.conversion, left_input:, rate: Some(rate))
                }

                _ -> Conversion(..model.conversion, rate: Some(rate))
              }
            }
          }

          #(Model(..model, conversion:), effect.none())
        }
      }
    }

    UserEnteredAmount(side, amount_str) -> {
      let to_float = fn(str) {
        str
        |> float.parse
        |> result.lazy_or(fn() {
          int.parse(str)
          |> result.map(int.to_float)
        })
      }

      let parse_amount = fn(str) {
        let str = case string.ends_with(str, ".") {
          False -> str
          True -> string.drop_end(str, 1)
        }
        to_float(str)
      }

      let update_conversion = fn(
        side: Side,
        source_input: ConversionInput,
        target_input: ConversionInput,
        amount: Float,
        rate: Option(Float),
      ) {
        let maybe_converted_amount = case side {
          Left ->
            rate
            |> option.map(fn(rate) { amount *. rate })
          Right ->
            rate
            |> option.map(fn(rate) { amount /. rate })
        }

        let updated_source =
          ConversionInput(
            ..source_input,
            amount_input: amount_str,
            parsed_amount: Some(amount),
          )

        let updated_target =
          ConversionInput(
            ..target_input,
            amount_input: maybe_converted_amount
              |> option.map(float.to_string)
              |> option.unwrap(""),
            parsed_amount: maybe_converted_amount,
          )

        Conversion(
          ..model.conversion,
          last_edited: side,
          left_input: case side {
            Left -> updated_source
            _ -> updated_target
          },
          right_input: case side {
            Left -> updated_target
            _ -> updated_source
          },
        )
      }

      let update_failed_parse = fn(side: Side) {
        Conversion(
          ..model.conversion,
          last_edited: side,
          left_input: case side {
            Left ->
              ConversionInput(
                ..model.conversion.left_input,
                amount_input: amount_str,
                parsed_amount: None,
              )
            _ ->
              ConversionInput(..model.conversion.left_input, amount_input: "")
          },
          right_input: case side {
            Left ->
              ConversionInput(
                ..model.conversion.right_input,
                amount_input: amount_str,
                parsed_amount: None,
              )
            Right ->
              ConversionInput(..model.conversion.right_input, amount_input: "")
          },
        )
      }

      let model = case parse_amount(amount_str) {
        Ok(amount) -> {
          let conversion = case side {
            Left ->
              update_conversion(
                Left,
                model.conversion.left_input,
                model.conversion.right_input,
                amount,
                model.conversion.rate,
              )
            Right ->
              update_conversion(
                Right,
                model.conversion.right_input,
                model.conversion.left_input,
                amount,
                model.conversion.rate,
              )
          }

          Model(..model, conversion:)
        }

        Error(_) -> {
          let conversion = update_failed_parse(side)
          Model(..model, conversion:)
        }
      }

      #(model, effect.none())
    }

    UserSelectedCurrency(side, currency_id_str) -> {
      let assert Ok(currency_id) = int.parse(currency_id_str)

      let model = case side {
        Left ->
          Model(
            ..model,
            conversion: Conversion(
              ..model.conversion,
              left_input: ConversionInput(
                ..model.conversion.left_input,
                currency_id:,
              ),
            ),
          )

        Right ->
          Model(
            ..model,
            conversion: Conversion(
              ..model.conversion,
              right_input: ConversionInput(
                ..model.conversion.right_input,
                currency_id:,
              ),
            ),
          )
      }

      let effect = case model.socket {
        None -> {
          echo "could not request rate. socket not initialized."
          effect.none()
        }

        Some(socket) -> {
          model
          |> build_rate_request
          |> subscribe_to_rate_updates(socket, _)
        }
      }

      #(model, effect)
    }
  }
}

fn subscribe_to_rate_updates(
  socket: WebSocket,
  rate_request: RateRequest,
) -> Effect(Msg) {
  rate_request
  |> rate_request.encode
  |> json.to_string
  |> socket.send(socket, _)
}

fn build_rate_request(model: Model) -> RateRequest {
  let left_currency = model.conversion.left_input.currency_id
  let right_currency = model.conversion.right_input.currency_id
  RateRequest(left_currency, right_currency)
}

pub fn view(model: Model) -> Element(Msg) {
  // element.fragment([header(), main_content(model)])
  element.fragment([main_content(model)])
}

// fn header() -> Element(Msg) {
//   html.header([attribute.class("p-4 border-b border-base-content")], [
//     html.h1(
//       [
//         attribute.class(
//           "w-full mx-auto max-w-screen-xl text-5xl text-base-content",
//         ),
//       ],
//       [html.text("RateRadar")],
//     ),
//   ])
// }

fn main_content(model: Model) -> Element(Msg) {
  let dropdown_options =
    model.currencies
    |> list.group(fn(currency) {
      case currency {
        Crypto(..) -> "Crypto"
        Fiat(..) -> "Fiat"
      }
    })
    |> dict.map_values(fn(key, currencies) {
      currencies
      |> list.sort(fn(c1, c2) {
        case key {
          "Crypto" -> {
            let get_rank = fn(currency) {
              let assert Crypto(_, _, _, maybe_rank) = currency
              option.unwrap(maybe_rank, or: 0)
            }
            int.compare(get_rank(c1), get_rank(c2))
          }
          _ -> string.compare(c1.symbol, c2.symbol)
        }
      })
      |> list.map(fn(currency) {
        DropdownOption(value: int.to_string(currency.id), label: currency.name)
      })
    })

  let equal_sign =
    html.p([attribute.class("text-3xl font-bold")], [element.text("=")])

  let left_conversion_input = model.conversion.left_input
  let right_conversion_input = model.conversion.right_input

  html.div(
    [
      attribute.class(
        "flex flex-col md:flex-row "
        <> "items-center justify-center p-4 "
        <> "space-y-4 md:space-y-0 md:space-x-4",
      ),
    ],
    [
      conversion_input(
        amount_input(Left, left_conversion_input.amount_input),
        currency_selector(
          Left,
          dropdown_options,
          left_conversion_input.currency_id,
        ),
      ),
      equal_sign,
      conversion_input(
        amount_input(Right, right_conversion_input.amount_input),
        currency_selector(
          Right,
          dropdown_options,
          right_conversion_input.currency_id,
        ),
      ),
    ],
  )
}

fn conversion_input(
  amount_input: Element(Msg),
  currency_selector: Element(Msg),
) -> Element(Msg) {
  html.span([attribute.class("flex flex-row items-center space-x-2")], [
    amount_input,
    currency_selector,
  ])
}

fn amount_input(side: Side, value: String) -> Element(Msg) {
  element.element(
    "auto-resize-input",
    [
      auto_resize_input.id("amount-input-" <> side.to_string(side)),
      auto_resize_input.value(value),
      // auto_resize_input.min_width(4),
      event.on("value-changed", fn(data) {
        data
        |> dynamic.field("detail", dynamic.string)
        |> result.map(UserEnteredAmount(side, _))
      }),
    ],
    [],
  )
}

fn currency_selector(
  side: Side,
  dropdown_options: Dict(String, List(DropdownOption)),
  selected_currency_id: Int,
) -> Element(Msg) {
  element.element(
    "button-dropdown",
    [
      button_dropdown.id("currency-selector-" <> side.to_string(side)),
      button_dropdown.options(dropdown_options),
      button_dropdown.value(int.to_string(selected_currency_id)),
      event.on("option-selected", fn(data) {
        data
        |> dynamic.field("detail", dynamic.string)
        |> result.map(UserSelectedCurrency(side, _))
      }),
    ],
    [],
  )
}
