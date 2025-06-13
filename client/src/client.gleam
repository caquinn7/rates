import client/browser/document
import client/browser/element as browser_element
import client/currency.{type CurrencyType, CryptoCurrency, FiatCurrency}
import client/rates/rate_request
import client/rates/rate_response
import client/side.{type Side, Left, Right}
import client/socket.{
  type WebSocket, type WebSocketEvent, InvalidUrl, OnClose, OnOpen,
  OnTextMessage,
}
import client/start_data.{type StartData}
import client/ui/components/auto_resize_input
import client/ui/components/button_dropdown
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/component
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
import lustre/element/keyed
import lustre/event
import shared/currency.{type Currency} as _shared_currency
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
    currency: Currency,
  )
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

  let assert Ok(from_currency) =
    start_data.currencies
    |> list.find(fn(c) { c.id == from })

  let assert Ok(to_currency) =
    start_data.currencies
    |> list.find(fn(c) { c.id == to })

  let left_input =
    ConversionInput(
      currency.format_amount_str(from_currency, 1.0),
      Some(1.0),
      from_currency,
    )
  let right_input =
    ConversionInput(
      currency.format_amount_str(to_currency, rate),
      Some(rate),
      to_currency,
    )

  Model(
    start_data.currencies,
    Conversion(left_input:, right_input:, rate: Some(rate), last_edited: Left),
    socket: None,
  )
}

pub type Msg {
  WsWrapper(WebSocketEvent)
  UserEnteredAmount(Side, String)
  UserSelectedCurrency(Side, String)
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
          echo "failed to decode conversion response from server: " <> msg
          #(model, effect.none())
        }

        Ok(rate_resp) -> {
          let RateResponse(from, to, rate, _source) = rate_resp

          let assert Ok(from_currency) =
            model.currencies
            |> list.find(fn(currency) { currency.id == from })

          let assert Ok(to_currency) =
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
                      amount_input: currency.format_amount_str(
                        to_currency,
                        right_amount,
                      ),
                      parsed_amount: Some(right_amount),
                    )
                  Conversion(..model.conversion, right_input:, rate: Some(rate))
                }

                None -> Conversion(..model.conversion, rate: Some(rate))
              }
            }

            Right -> {
              case model.conversion.right_input.parsed_amount {
                Some(right_amount) -> {
                  let left_amount = right_amount /. rate
                  let left_input =
                    ConversionInput(
                      ..model.conversion.left_input,
                      amount_input: currency.format_amount_str(
                        from_currency,
                        left_amount,
                      ),
                      parsed_amount: Some(left_amount),
                    )
                  Conversion(..model.conversion, left_input:, rate: Some(rate))
                }

                None -> Conversion(..model.conversion, rate: Some(rate))
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
        case string.ends_with(str, ".") {
          False -> str
          True -> string.drop_end(str, 1)
        }
        |> string.replace(",", "")
        |> to_float
      }

      // Build a new Conversion when the user has entered a valid number
      let update_conversion = fn(
        edited_side: Side,
        // the input they just typed into
        source_input: ConversionInput,
        target_input: ConversionInput,
        amount: Float,
        rate: Option(Float),
      ) {
        // Compute the amount for the side opposite the edited one
        let maybe_converted_amount = case edited_side {
          Left -> rate |> option.map(fn(r) { amount *. r })
          Right -> rate |> option.map(fn(r) { amount /. r })
        }

        // Update the field the user just typed into
        let updated_source =
          ConversionInput(
            ..source_input,
            amount_input: currency.format_amount_str(
              source_input.currency,
              amount,
            ),
            parsed_amount: Some(amount),
          )

        // Update the other field with the converted value (or blank if no rate)
        let updated_target =
          ConversionInput(
            ..target_input,
            amount_input: maybe_converted_amount
              |> option.map(currency.format_amount_str(target_input.currency, _))
              |> option.unwrap(""),
            parsed_amount: maybe_converted_amount,
          )

        Conversion(
          ..model.conversion,
          last_edited: edited_side,
          left_input: case edited_side {
            Left -> updated_source
            _ -> updated_target
          },
          right_input: case edited_side {
            Left -> updated_target
            _ -> updated_source
          },
        )
      }

      // Build a new Conversion when the user typed something non-numeric
      let update_failed_parse = fn(edited_side: Side) {
        // Helper to clear parsed_amount on both fields,
        // keep amount_str only in the field the user was editing
        let clear_amount_str = fn(input: ConversionInput, field_side: Side) {
          ConversionInput(
            ..input,
            amount_input: case field_side == edited_side {
              True -> amount_str
              False -> ""
            },
            parsed_amount: None,
          )
        }

        let left_input = clear_amount_str(model.conversion.left_input, Left)
        let right_input = clear_amount_str(model.conversion.right_input, Right)

        Conversion(
          ..model.conversion,
          last_edited: edited_side,
          left_input: left_input,
          right_input: right_input,
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
      let assert Ok(currency) =
        currency_id_str
        |> int.parse
        |> result.try(fn(id) {
          list.find(model.currencies, fn(c) { c.id == id })
        })

      let model = case side {
        Left ->
          Model(
            ..model,
            conversion: Conversion(
              ..model.conversion,
              left_input: ConversionInput(
                ..model.conversion.left_input,
                currency:,
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
                currency:,
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
  let conversion = model.conversion
  RateRequest(
    conversion.left_input.currency.id,
    conversion.right_input.currency.id,
  )
}

pub fn view(model: Model) -> Element(Msg) {
  element.fragment([header(), main_content(model)])
}

fn header() -> Element(Msg) {
  html.header([attribute.class("p-4 border-b border-base-content")], [
    html.h1(
      [
        attribute.class(
          "w-full mx-auto max-w-screen-xl text-5xl text-base-content",
        ),
      ],
      [html.text("RateRadar")],
    ),
  ])
}

fn main_content(model: Model) -> Element(Msg) {
  let currency_groups =
    model.currencies
    |> currency.group_by_type
    |> dict.map_values(fn(currency_type, currencies) {
      currencies
      |> list.sort(fn(c1, c2) {
        let assert Ok(order) = case currency_type {
          CryptoCurrency -> currency.sort_cryptos(c1, c2)
          FiatCurrency -> currency.sort_fiats(c1, c2)
        }
        order
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
        currency_selector(Left, currency_groups, left_conversion_input.currency),
      ),
      equal_sign,
      conversion_input(
        amount_input(Right, right_conversion_input.amount_input),
        currency_selector(
          Right,
          currency_groups,
          right_conversion_input.currency,
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
  auto_resize_input.element([
    auto_resize_input.id("amount-input-" <> side.to_string(side)),
    auto_resize_input.value(value),
    auto_resize_input.min_width(4),
    UserEnteredAmount(side, _)
      |> auto_resize_input.on_change
      |> event.debounce(300),
  ])
}

fn currency_selector(
  side: Side,
  currency_groups: Dict(CurrencyType, List(Currency)),
  selected_currency: Currency,
) -> Element(Msg) {
  let currency_option_group_elems =
    currency_groups
    |> dict.to_list
    |> list.map(currency_option_group(_, UserSelectedCurrency(side, _)))

  button_dropdown.element(
    [
      button_dropdown.id("currency-selector-" <> side.to_string(side)),
      button_dropdown.value(int.to_string(selected_currency.id)),
      button_dropdown.btn_text(selected_currency.symbol),
    ],
    [html.div([component.slot("options")], currency_option_group_elems)],
  )
}

fn currency_option_group(
  currency_group: #(CurrencyType, List(Currency)),
  on_option_selected: fn(String) -> Msg,
) -> Element(Msg) {
  let group_title_div =
    html.div(
      [attribute.class("px-2 py-1 font-bold text-lg text-base-content")],
      [
        html.text(case currency_group.0 {
          CryptoCurrency -> "Crypto"
          FiatCurrency -> "Fiat"
        }),
      ],
    )

  html.div([], [
    group_title_div,
    currency_options_container(currency_group.1, on_option_selected),
  ])
}

fn currency_options_container(
  currencies: List(Currency),
  on_option_selected: fn(String) -> Msg,
) -> Element(Msg) {
  let dd_option = fn(currency: Currency) {
    html.div(
      [
        attribute.attribute("data-value", int.to_string(currency.id)),
        attribute.class("px-6 py-1 cursor-pointer text-base-content"),
        attribute.class("hover:bg-base-content hover:text-base-100"),
        event.on_click(on_option_selected(int.to_string(currency.id))),
      ],
      [html.text(currency.name)],
    )
  }

  keyed.div(
    [attribute.class("options-container")],
    list.map(currencies, fn(currency) {
      let child = dd_option(currency)
      #(int.to_string(currency.id), child)
    }),
  )
}
