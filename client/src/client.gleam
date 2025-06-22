import client/browser/document
import client/browser/element as browser_element
import client/browser/event as browser_event
import client/currency/collection.{CryptoCurrency, FiatCurrency} as currency_collection
import client/currency/formatting as currency_formatting
import client/rates/rate_request
import client/rates/rate_response
import client/side.{type Side, Left, Right}
import client/socket.{
  type WebSocket, type WebSocketEvent, InvalidUrl, OnClose, OnOpen,
  OnTextMessage,
}
import client/start_data.{type StartData}
import client/ui/button_dropdown.{DropdownOption}
import client/ui/components/auto_resize_input
import gleam/dict
import gleam/float
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import gleam/result
import gleam/string
import lustre
import lustre/attribute
import lustre/effect.{type Effect}
import lustre/element.{type Element}
import lustre/element/html
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
    conversion_inputs: #(ConversionInput, ConversionInput),
    rate: Option(Float),
    last_edited: Side,
  )
}

pub type ConversionInput {
  ConversionInput(
    amount_input: AmountInput,
    currency_selector: CurrencySelector,
  )
}

pub type AmountInput {
  AmountInput(raw: String, parsed: Option(Float))
}

pub type CurrencySelector {
  CurrencySelector(
    id: String,
    show_dropdown: Bool,
    currency_filter: String,
    currencies: List(Currency),
    currency: Currency,
  )
}

// model utility functions

pub fn map_conversion_input(
  model: Model,
  side: Side,
  fun: fn(ConversionInput) -> a,
) -> a {
  let target = case side {
    Left -> model.conversion.conversion_inputs.0
    Right -> model.conversion.conversion_inputs.1
  }
  fun(target)
}

pub type TargetedSide {
  Just(Side)
  Both
}

pub fn map_conversion_inputs(
  inputs: #(ConversionInput, ConversionInput),
  side: TargetedSide,
  fun: fn(ConversionInput) -> ConversionInput,
) -> #(ConversionInput, ConversionInput) {
  let map_pair = case side {
    Just(Left) -> pair.map_first
    Just(Right) -> pair.map_second
    Both -> fn(pair, map) {
      pair
      |> pair.map_first(map)
      |> pair.map_second(map)
    }
  }
  map_pair(inputs, fun)
}

pub fn with_amount(model: Model, side: Side, raw_amount: String) -> Model {
  let parse_amount = fn(str) {
    let to_float = fn(str) {
      str
      |> float.parse
      |> result.lazy_or(fn() {
        int.parse(str)
        |> result.map(int.to_float)
      })
    }

    case string.ends_with(str, ".") {
      False -> str
      True -> string.drop_end(str, 1)
    }
    |> string.replace(",", "")
    |> to_float
  }

  let conversion_inputs = model.conversion.conversion_inputs

  let map_failed_parse = fn() {
    map_conversion_inputs(conversion_inputs, Just(side), fn(input) {
      ConversionInput(
        ..input,
        amount_input: AmountInput(raw: raw_amount, parsed: None),
      )
    })
    |> map_conversion_inputs(Just(side.opposite_side(side)), fn(input) {
      ConversionInput(..input, amount_input: AmountInput(raw: "", parsed: None))
    })
  }

  let map_successful_parse = fn(parsed_amount) {
    let format_amount_input = fn(currency, amount) {
      AmountInput(
        raw: currency_formatting.format_amount_str(currency, amount),
        parsed: Some(amount),
      )
    }

    map_conversion_inputs(conversion_inputs, Just(side), fn(input) {
      ConversionInput(
        ..input,
        amount_input: format_amount_input(
          input.currency_selector.currency,
          parsed_amount,
        ),
      )
    })
    |> map_conversion_inputs(Just(side.opposite_side(side)), fn(input) {
      let rate = model.conversion.rate
      let maybe_converted_amount = case side {
        Left -> rate |> option.map(fn(r) { parsed_amount *. r })
        Right -> rate |> option.map(fn(r) { parsed_amount /. r })
      }

      ConversionInput(
        ..input,
        amount_input: maybe_converted_amount
          |> option.map(fn(converted) {
            format_amount_input(input.currency_selector.currency, converted)
          })
          |> option.unwrap(AmountInput(raw: "", parsed: None)),
      )
    })
  }

  let updated_inputs = case parse_amount(raw_amount) {
    Error(_) -> map_failed_parse()
    Ok(amount) -> map_successful_parse(amount)
  }

  Model(
    ..model,
    conversion: Conversion(
      ..model.conversion,
      conversion_inputs: updated_inputs,
      last_edited: side,
    ),
  )
}

pub fn toggle_currency_selector_dropdown(model: Model, side: Side) -> Model {
  let conversion_inputs =
    model.conversion.conversion_inputs
    |> map_conversion_inputs(Just(side), fn(conversion_input) {
      ConversionInput(
        ..conversion_input,
        currency_selector: CurrencySelector(
          ..conversion_input.currency_selector,
          show_dropdown: !conversion_input.currency_selector.show_dropdown,
        ),
      )
    })

  Model(..model, conversion: Conversion(..model.conversion, conversion_inputs:))
}

pub fn with_currency_filter(
  model: Model,
  side: Side,
  filter_str: String,
) -> Model {
  let currencies =
    model.currencies
    |> currency_collection.filter(filter_str)

  let conversion_inputs =
    model.conversion.conversion_inputs
    |> map_conversion_inputs(Just(side), fn(conversion_input) {
      ConversionInput(
        ..conversion_input,
        currency_selector: CurrencySelector(
          ..conversion_input.currency_selector,
          currency_filter: filter_str,
          currencies:,
        ),
      )
    })

  Model(..model, conversion: Conversion(..model.conversion, conversion_inputs:))
}

pub fn with_selected_currency(model: Model, side: Side, currency_id: Int) {
  let assert Ok(currency) =
    model.currencies
    |> list.find(fn(c) { c.id == currency_id })

  let conversion_inputs =
    model.conversion.conversion_inputs
    |> map_conversion_inputs(Just(side), fn(conversion_input) {
      ConversionInput(
        ..conversion_input,
        currency_selector: CurrencySelector(
          ..conversion_input.currency_selector,
          currency:,
        ),
      )
    })

  Model(..model, conversion: Conversion(..model.conversion, conversion_inputs:))
}

// end model utility functions

pub fn main() -> Nil {
  let assert Ok(json_str) =
    document.query_selector("#model")
    |> result.map(browser_element.inner_text)

  let start_data = case json.parse(json_str, start_data.decoder()) {
    Ok(start_data) -> start_data
    _ -> panic as "failed to decode start_data"
  }

  let assert Ok(_) = auto_resize_input.register("auto-resize-input")

  let app = lustre.application(init, update, view)
  let assert Ok(runtime) = lustre.start(app, "#app", start_data)

  document.add_event_listener("click", fn(event) {
    event
    |> UserClickedInDocument
    |> lustre.dispatch
    |> lustre.send(runtime, _)
  })
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
      AmountInput(
        currency_formatting.format_amount_str(from_currency, 1.0),
        Some(1.0),
      ),
      CurrencySelector(
        "currency-selector-" <> side.to_string(Left),
        False,
        "",
        start_data.currencies,
        from_currency,
      ),
    )
  let right_input =
    ConversionInput(
      AmountInput(
        currency_formatting.format_amount_str(to_currency, rate),
        Some(rate),
      ),
      CurrencySelector(
        "currency-selector-" <> side.to_string(Right),
        False,
        "",
        start_data.currencies,
        to_currency,
      ),
    )

  Model(
    start_data.currencies,
    Conversion(
      conversion_inputs: #(left_input, right_input),
      rate: Some(rate),
      last_edited: Left,
    ),
    socket: None,
  )
}

pub type Msg {
  WsWrapper(WebSocketEvent)
  UserEnteredAmount(Side, String)
  UserClickedCurrencySelector(Side)
  UserFilteredCurrencies(Side, String)
  UserSelectedCurrency(Side, Int)
  UserClickedInDocument(browser_event.Event)
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
              case
                { model.conversion.conversion_inputs.0 }.amount_input.parsed
              {
                Some(left_amount) -> {
                  let right_amount = left_amount *. rate
                  let right_input =
                    ConversionInput(
                      ..model.conversion.conversion_inputs.1,
                      amount_input: AmountInput(
                        raw: currency_formatting.format_amount_str(
                          to_currency,
                          right_amount,
                        ),
                        parsed: Some(right_amount),
                      ),
                    )
                  Conversion(
                    ..model.conversion,
                    conversion_inputs: #(
                      model.conversion.conversion_inputs.0,
                      right_input,
                    ),
                    rate: Some(rate),
                  )
                }

                None -> Conversion(..model.conversion, rate: Some(rate))
              }
            }

            Right -> {
              case
                { model.conversion.conversion_inputs.1 }.amount_input.parsed
              {
                Some(right_amount) -> {
                  let left_amount = right_amount /. rate
                  let left_input =
                    ConversionInput(
                      ..model.conversion.conversion_inputs.0,
                      amount_input: AmountInput(
                        raw: currency_formatting.format_amount_str(
                          from_currency,
                          left_amount,
                        ),
                        parsed: Some(left_amount),
                      ),
                    )
                  Conversion(
                    ..model.conversion,
                    conversion_inputs: #(
                      left_input,
                      model.conversion.conversion_inputs.1,
                    ),
                    rate: Some(rate),
                  )
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
      let model =
        model
        |> with_amount(side, amount_str)

      #(model, effect.none())
    }

    UserClickedCurrencySelector(side) -> {
      let model =
        model
        |> toggle_currency_selector_dropdown(side)

      #(model, effect.none())
    }

    UserFilteredCurrencies(side, filter_str) -> {
      let model =
        model
        |> with_currency_filter(side, filter_str)

      #(model, effect.none())
    }

    UserSelectedCurrency(side, currency_id) -> {
      let model =
        model
        |> with_selected_currency(side, currency_id)

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

    UserClickedInDocument(event) -> {
      let assert Ok(clicked_elem) =
        event
        |> browser_event.target
        |> browser_element.cast

      let update_side = fn(side, model) {
        let #(currency_selector_id, dropdown_visible) =
          model
          |> map_conversion_input(side, fn(conversion_input) {
            #(
              conversion_input.currency_selector.id,
              conversion_input.currency_selector.show_dropdown,
            )
          })

        let assert Ok(currency_selector_elem) =
          document.get_element_by_id(currency_selector_id)

        let clicked_outside_dropdown =
          !browser_element.contains(currency_selector_elem, clicked_elem)

        let should_toggle = dropdown_visible && clicked_outside_dropdown
        case should_toggle {
          False -> model
          True ->
            model
            |> toggle_currency_selector_dropdown(side)
        }
      }

      let model =
        model
        |> update_side(Left, _)
        |> update_side(Right, _)

      #(model, effect.none())
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
  let #(left_input, right_input) = model.conversion.conversion_inputs
  RateRequest(
    left_input.currency_selector.currency.id,
    right_input.currency_selector.currency.id,
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
  let equal_sign =
    html.p([attribute.class("text-3xl font-bold")], [element.text("=")])

  let conversion_input_elem = fn(side) {
    let target_conversion_input = case side {
      Left -> model.conversion.conversion_inputs.0
      Right -> model.conversion.conversion_inputs.1
    }

    let on_currency_selected = fn(currency_id_str) {
      let assert Ok(currency_id) = int.parse(currency_id_str)
      UserSelectedCurrency(side, currency_id)
    }

    conversion_input(
      amount_input(
        "amount-input-" <> side.to_string(side),
        target_conversion_input.amount_input,
        UserEnteredAmount(side, _),
      ),
      currency_selector(
        target_conversion_input.currency_selector,
        UserClickedCurrencySelector(side),
        UserFilteredCurrencies(side, _),
        on_currency_selected,
      ),
    )
  }

  html.div(
    [
      attribute.class(
        "flex flex-col md:flex-row "
        <> "items-center justify-center p-4 "
        <> "space-y-4 md:space-y-0 md:space-x-4",
      ),
    ],
    [conversion_input_elem(Left), equal_sign, conversion_input_elem(Right)],
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

fn amount_input(
  id: String,
  amount_input: AmountInput,
  on_change: fn(String) -> Msg,
) -> Element(Msg) {
  auto_resize_input.element([
    auto_resize_input.id(id),
    auto_resize_input.value(amount_input.raw),
    auto_resize_input.min_width(4),
    on_change
      |> auto_resize_input.on_change
      |> event.debounce(300),
  ])
}

fn currency_selector(
  currency_selector: CurrencySelector,
  on_btn_click: Msg,
  on_filter: fn(String) -> Msg,
  on_select: fn(String) -> Msg,
) -> Element(Msg) {
  let dropdown_options = {
    let currency_groups =
      currency_collection.group(currency_selector.currencies)

    currency_groups
    |> dict.keys
    |> list.map(fn(key) {
      let assert Ok(currencies) = dict.get(currency_groups, key)
      let options =
        list.map(currencies, fn(currency) {
          DropdownOption(
            value: int.to_string(currency.id),
            display: html.text(currency.symbol <> " - " <> currency.name),
          )
        })
      let key_str = case key {
        CryptoCurrency -> "Crypto"
        FiatCurrency -> "Fiat"
      }
      #(key_str, options)
    })
    |> dict.from_list
  }

  button_dropdown.view(
    currency_selector.id,
    currency_selector.currency.symbol,
    currency_selector.show_dropdown,
    currency_selector.currency_filter,
    dropdown_options,
    on_btn_click,
    on_filter,
    on_select,
  )
}
