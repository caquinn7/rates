import client/browser/document
import client/browser/element as browser_element
import client/browser/event as browser_event
import client/browser/history
import client/browser/window
import client/net/http_client
import client/net/websocket_client
import client/positive_float
import client/side.{type Side, Left, Right}
import client/ui/auto_resize_input
import client/ui/converter.{type Converter, type NewConverterError}
import client/ui/icons
import client/websocket.{
  type WebSocket, type WebSocketEvent, InvalidUrl, OnClose, OnOpen,
  OnTextMessage,
}
import gleam/dict
import gleam/dynamic
import gleam/float
import gleam/function
import gleam/int
import gleam/javascript/array
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
import lustre/element/keyed
import lustre/event
import rsvp
import shared/client_state.{ClientState, ConverterState}
import shared/currency.{type Currency}
import shared/page_data.{type PageData}
import shared/rates/rate_response.{RateResponse}
import shared/subscriptions/subscription_id
import shared/subscriptions/subscription_response.{SubscriptionResponse}

const converter_id_prefix = "converter"

pub type Model {
  Model(
    currencies: List(Currency),
    added_currencies: List(Int),
    converters: List(Converter),
    socket: Option(WebSocket),
    reconnect_attempts: Int,
  )
}

pub fn model_from_page_data(
  page_data: PageData,
) -> Result(Model, NewConverterError) {
  let build_converter = fn(rate_response, converter_id, amount) {
    let assert RateResponse(from, to, Some(rate), _source, _timestamp) =
      rate_response

    converter.new(
      converter_id,
      page_data.currencies,
      #(from, to),
      float.to_string(amount),
      Some(positive_float.from_float_unsafe(rate)),
    )
  }

  let converters =
    page_data.converters
    |> list.index_map(fn(converter_state, idx) {
      page_data.rates
      |> list.find(fn(rate_resp) {
        rate_resp.from == converter_state.from
        && rate_resp.to == converter_state.to
      })
      |> result.try(fn(rate_resp) {
        rate_resp
        |> build_converter(
          converter_id_prefix <> int.to_string(idx + 1),
          converter_state.amount,
        )
        |> result.map_error(fn(err) {
          echo "error building converter: " <> string.inspect(err)
          Nil
        })
      })
    })
    |> list.filter_map(function.identity)

  Ok(Model(
    currencies: page_data.currencies,
    added_currencies: [],
    converters:,
    socket: None,
    reconnect_attempts: 0,
  ))
}

pub fn model_with_converter(model: Model, converter: Converter) -> Model {
  let converters =
    model.converters
    |> list.map(fn(conv) {
      case conv.id == converter.id {
        True -> converter
        False -> conv
      }
    })

  Model(..model, converters:)
}

pub fn get_next_converter_id(model: Model) -> String {
  let max_id =
    model.converters
    |> list.map(fn(converter) {
      converter.id
      |> string.split_once("-")
      |> result.map(pair.second)
      |> result.try(int.parse)
      |> result.unwrap(0)
    })
    |> list.fold(0, int.max)

  let next_id = max_id + 1

  converter_id_prefix <> "-" <> int.to_string(next_id)
}

pub fn model_to_client_state(model: Model) {
  let converter_states =
    model.converters
    |> list.map(fn(converter) {
      let amount =
        converter
        |> converter.get_parsed_amount(Left)
        |> option.map(positive_float.unwrap)
        |> option.unwrap(1.0)

      ConverterState(
        converter.get_selected_currency_id(converter, Left),
        converter.get_selected_currency_id(converter, Right),
        amount,
      )
    })

  let added_currencies =
    model.added_currencies
    |> list.filter(fn(currency_id) {
      // only include added currency ids in use by a converter
      list.any(converter_states, fn(converter_state) {
        converter_state.from == currency_id || converter_state.to == currency_id
      })
    })
    |> list.filter_map(fn(currency_id) {
      // map each added currency id to its symbol
      model.currencies
      |> list.find(fn(currency) { currency.id == currency_id })
      |> result.map(fn(currency) { currency.symbol })
    })

  ClientState(converters: converter_states, added_currencies:)
}

pub fn main() -> Nil {
  let assert Ok(json_str) =
    result.map(document.query_selector("#model"), browser_element.inner_text)
    as "failed to find model element"

  let assert Ok(page_data) = json.parse(json_str, page_data.decoder())
    as "failed to decode page_data"

  let assert Ok(_) = auto_resize_input.register()

  let app = lustre.application(init, update, view)
  let assert Ok(runtime) = lustre.start(app, "#app", page_data)

  document.add_event_listener("click", fn(event) {
    event
    |> UserClickedInDocument
    |> lustre.dispatch
    |> lustre.send(runtime, _)
  })
}

pub fn init(flags: PageData) -> #(Model, Effect(Msg)) {
  let model = case model_from_page_data(flags) {
    Error(err) -> panic as { "error building model: " <> string.inspect(err) }
    Ok(m) -> m
  }

  #(model, websocket.init("/ws", FromWebSocket))
}

pub type Msg {
  FromWebSocket(WebSocketEvent)
  FromConverter(String, converter.Msg)
  UserClickedAddConverter
  UserClickedDeleteConverter(String)
  UserClickedInDocument(browser_event.Event)
  ApiReturnedMatchedCurrencies(Result(List(Currency), rsvp.Error))
  AppScheduledReconnection
  AppScheduledRateChangeIndicatorReset(String, Side)
}

pub fn update(model: Model, msg: Msg) -> #(Model, Effect(Msg)) {
  case msg {
    FromWebSocket(InvalidUrl) -> panic as "invalid url used to open websocket"

    FromWebSocket(OnClose(reason)) -> {
      echo "socket closed. reason: " <> string.inspect(reason)
      #(
        Model(..model, socket: None),
        schedule_reconnection(model.reconnect_attempts),
      )
    }

    FromWebSocket(OnOpen(socket)) -> {
      let model = Model(..model, socket: Some(socket), reconnect_attempts: 0)

      let effect =
        model.converters
        |> list.map(fn(converter) {
          websocket_client.subscribe_to_rate(
            socket,
            subscription_id.from_string_unsafe(converter.id),
            converter.to_rate_request(converter),
          )
        })
        |> effect.batch

      #(model, effect)
    }

    FromWebSocket(OnTextMessage(msg)) -> {
      case json.parse(msg, subscription_response.decoder()) {
        Error(_) -> {
          echo "failed to decode conversion response from server: " <> msg
          #(model, effect.none())
        }

        Ok(SubscriptionResponse(sub_id, rate_response)) -> {
          let RateResponse(from, to, rate, _source, _timestamp) = rate_response

          let target_converter = {
            use converter <- result.try(
              list.find(model.converters, fn(converter) {
                converter.id == subscription_id.to_string(sub_id)
              }),
            )

            let current_request = converter.to_rate_request(converter)
            case current_request.from == from && current_request.to == to {
              False -> Error(Nil)
              True -> Ok(converter)
            }
          }

          case target_converter {
            Error(_) -> #(model, effect.none())

            Ok(converter) -> {
              let model =
                rate
                |> option.map(fn(r) {
                  let assert Ok(r) = positive_float.new(r)
                  r
                })
                |> converter.with_rate(converter, _)
                |> model_with_converter(model, _)

              let effect =
                effect.from(fn(dispatch) {
                  let _ =
                    window.set_timeout(
                      fn() {
                        dispatch(AppScheduledRateChangeIndicatorReset(
                          converter.id,
                          side.opposite_side(converter.last_edited),
                        ))
                      },
                      3000,
                    )

                  Nil
                })

              #(model, effect)
            }
          }
        }
      }
    }

    FromConverter(converter_id, converter_msg) -> {
      model.converters
      |> list.find(fn(converter) { converter.id == converter_id })
      |> result.map(fn(target_converter) {
        case converter.update(target_converter, converter_msg) {
          #(converter, converter_effect) -> {
            let model = model_with_converter(model, converter)

            let effect = case converter_effect {
              converter.NoEffect -> effect.none()

              converter.FocusOnCurrencyFilter(side) ->
                effect.before_paint(fn(_, _) {
                  let currency_selector_id =
                    converter.get_converter_input(converter, side).currency_selector.id

                  let assert Ok(filter_elem) =
                    document.query_selector(
                      "#" <> currency_selector_id <> " input",
                    )

                  browser_element.focus(filter_elem)
                })

              converter.ScrollToOption(side, index) ->
                effect.before_paint(fn(_, _) {
                  let currency_selector_id =
                    converter.get_converter_input(converter, side).currency_selector.id

                  let option_elems =
                    document.query_selector_all(
                      "#"
                      <> currency_selector_id
                      <> " .options-container"
                      <> " .dd-option",
                    )

                  let assert Ok(target_option_elem) =
                    array.get(option_elems, index)

                  browser_element.scroll_into_view(target_option_elem)
                })

              converter.RequestCurrencies(symbol) ->
                http_client.get_currencies(symbol, ApiReturnedMatchedCurrencies)

              converter.RequestRate -> {
                case model.socket {
                  None -> {
                    echo "could not request rate. socket not initialized."
                    effect.none()
                  }

                  Some(socket) ->
                    websocket_client.subscribe_to_rate(
                      socket,
                      subscription_id.from_string_unsafe(converter.id),
                      converter.to_rate_request(converter),
                    )
                }
              }
            }

            #(model, effect)
          }
        }
      })
      |> result.unwrap(#(model, effect.none()))
    }

    UserClickedAddConverter -> {
      let assert Ok(new_converter) =
        converter.new(
          get_next_converter_id(model),
          model.currencies,
          #(1, 2781),
          "1",
          None,
        )

      let model =
        Model(
          ..model,
          converters: list.append(model.converters, [new_converter]),
        )

      let effect = case model.socket {
        None -> {
          echo "could not request rate. socket not initialized."
          effect.none()
        }

        Some(socket) ->
          websocket_client.subscribe_to_rate(
            socket,
            subscription_id.from_string_unsafe(new_converter.id),
            converter.to_rate_request(new_converter),
          )
      }

      let _ = encode_state_in_url(model)

      #(model, effect)
    }

    UserClickedDeleteConverter(converter_id) -> {
      let model =
        Model(
          ..model,
          converters: list.filter(model.converters, fn(converter) {
            converter.id != converter_id
          }),
        )

      let effect = case model.socket {
        None -> {
          echo "could not unsubscribe from rate update. socket not initialized."
          effect.none()
        }

        Some(socket) ->
          websocket_client.unsubscribe_from_rate(
            socket,
            subscription_id.from_string_unsafe(converter_id),
          )
      }

      #(model, effect)
    }

    UserClickedInDocument(event) -> {
      let assert Ok(clicked_elem) =
        event
        |> browser_event.target
        |> browser_element.cast

      let close_dropdown = fn(converter, side) {
        let currency_selector =
          converter.get_converter_input(converter, side).currency_selector

        let currency_selector_id = currency_selector.id
        let dropdown_visible = currency_selector.show_dropdown

        case document.get_element_by_id(currency_selector_id) {
          Error(_) -> converter

          Ok(currency_selector_elem) -> {
            let clicked_outside_dropdown =
              !browser_element.contains(currency_selector_elem, clicked_elem)

            let should_toggle = dropdown_visible && clicked_outside_dropdown
            case should_toggle {
              False -> converter
              True -> converter.with_toggled_dropdown(converter, side)
            }
          }
        }
      }

      let converters =
        model.converters
        |> list.map(fn(converter) {
          converter
          |> close_dropdown(Left)
          |> close_dropdown(Right)
        })

      #(Model(..model, converters:), effect.none())
    }

    ApiReturnedMatchedCurrencies(Error(err)) -> {
      echo "error fetching currencies: " <> string.inspect(err)
      #(model, effect.none())
    }

    ApiReturnedMatchedCurrencies(Ok(matched_currencies)) -> {
      let master_list = {
        let currencies_to_dict = fn(currencies) {
          currencies
          |> list.map(fn(currency: Currency) { #(currency.id, currency) })
          |> dict.from_list
        }

        // Convert both currency lists to dicts indexed by ID, then merge.
        // This deduplicates currencies while giving server data precedence
        // over existing client data for any conflicts.
        model.currencies
        |> currencies_to_dict
        |> dict.merge(currencies_to_dict(matched_currencies))
        |> dict.values
      }

      let converters =
        list.map(model.converters, fn(conv) {
          converter.with_master_currency_list(conv, master_list)
        })

      let model =
        Model(
          ..model,
          currencies: master_list,
          added_currencies: list.map(matched_currencies, fn(c) { c.id }),
          converters:,
        )

      let effect = case model.socket {
        None -> {
          echo "could not add currencies. socket not initialized."
          effect.none()
        }

        Some(socket) ->
          websocket_client.add_currencies(socket, matched_currencies)
      }

      #(model, effect)
    }

    AppScheduledReconnection -> #(
      Model(..model, reconnect_attempts: model.reconnect_attempts + 1),
      websocket.init("/ws", FromWebSocket),
    )

    AppScheduledRateChangeIndicatorReset(converter_id, side) -> {
      let target_converter =
        model.converters
        |> list.find(fn(converter) { converter.id == converter_id })

      let model = case target_converter {
        Error(_) -> model

        Ok(converter) ->
          model_with_converter(
            model,
            converter.with_glow_cleared(converter, side),
          )
      }

      #(model, effect.none())
    }
  }
}

fn encode_state_in_url(model: Model) {
  let encoded_state =
    model
    |> model_to_client_state
    |> client_state.encode

  let updated_url =
    window.get_url_with_updated_query_param("state", encoded_state)

  history.replace_state(dynamic.nil(), Some(updated_url))
}

fn schedule_reconnection(reconnect_attempts: Int) -> Effect(Msg) {
  effect.from(fn(dispatch) {
    // Exponential backoff: 1s, 2s, 4s, 8s... up to 30s, then ±25% jitter (max ~37.5s)
    let delay_ms = {
      let base_delay_ms =
        int.min(1000 * int.bitwise_shift_left(1, reconnect_attempts), 30_000)

      let jitter_range = int.to_float(base_delay_ms) *. 0.25
      let jitter = float.random() *. jitter_range *. 2.0 -. jitter_range
      float.round(int.to_float(base_delay_ms) +. jitter)
    }

    echo "reconnect attempt #"
      <> int.to_string(reconnect_attempts + 1)
      <> " in "
      <> int.to_string(delay_ms / 1000)
      <> " seconds."

    let _ =
      window.set_timeout(fn() { dispatch(AppScheduledReconnection) }, delay_ms)

    Nil
  })
}

fn view(model: Model) -> Element(Msg) {
  element.fragment([
    header(model),
    main_content(model),
  ])
}

fn header(model: Model) -> Element(Msg) {
  let site_name =
    html.h1(
      [
        attribute.class("w-full mx-auto max-w-screen-xl text-4xl"),
      ],
      [
        html.text("rates"),
      ],
    )

  html.div([attribute.class("navbar border-b")], [
    html.div([attribute.class("flex-1 pl-4")], [site_name]),
    html.div([attribute.class("flex-none gap-4 pr-4 flex items-center")], [
      connection_status_indicator(model),
      theme_controller(),
    ]),
  ])
}

fn connection_status_indicator(model: Model) -> Element(Msg) {
  let indicator = fn(color_class) {
    html.div([attribute.class("inline-grid *:[grid-area:1/1]")], [
      html.div([attribute.class("status animate-ping " <> color_class)], []),
      html.div([attribute.class("status " <> color_class)], []),
    ])
  }

  let badge = fn(indicator, text) {
    html.div([attribute.class("badge border-none")], [
      indicator,
      html.text(text),
    ])
  }

  case model.socket, model.reconnect_attempts {
    Some(_), _ -> badge(indicator("status-success"), "Connected")
    None, 0 -> badge(indicator("status-warning"), "Connecting")
    None, attempts ->
      badge(
        indicator("status-error"),
        "Reconnecting (" <> int.to_string(attempts) <> ")",
      )
  }
}

fn theme_controller() {
  html.label([attribute.class("swap swap-rotate")], [
    html.input([
      attribute.type_("checkbox"),
      attribute.class("theme-controller"),
      attribute.value("lofi"),
    ]),
    icons.sun(),
    icons.moon(),
  ])
}

fn main_content(model: Model) -> Element(Msg) {
  let converter_rows =
    list.index_map(model.converters, fn(converter, index) {
      let is_last_converter = list.length(model.converters) - 1 == index
      let is_only_converter = list.length(model.converters) == 1
      let row = converter_row(converter, is_last_converter, is_only_converter)
      #(converter.id, row)
    })

  html.div([attribute.class("container max-w-4xl mx-auto px-4")], [
    html.div([attribute.class("flex justify-center")], [
      keyed.div(
        [attribute.class("converters flex flex-col mt-4")],
        converter_rows,
      ),
    ]),
  ])
}

fn converter_row(
  converter: Converter,
  show_add: Bool,
  show_delete: Bool,
) -> Element(Msg) {
  let button = fn(color_class, icon, on_click) {
    html.button(
      [
        attribute.class(color_class),
        attribute.class("btn btn-circle"),
        event.on_click(on_click),
      ],
      [icon],
    )
  }

  let converter_elem =
    converter
    |> converter.view
    |> element.map(FromConverter(converter.id, _))

  let left_column = case show_add {
    False -> html.div([attribute.class("w-12")], [])
    True ->
      html.div([attribute.class("w-12 flex justify-center")], [
        button("btn-info", icons.plus(), UserClickedAddConverter),
      ])
  }

  let right_column = case show_delete {
    False ->
      html.div([attribute.class("w-12 flex justify-center")], [
        button(
          "btn-warning",
          icons.x(),
          UserClickedDeleteConverter(converter.id),
        ),
      ])

    True -> html.div([attribute.class("w-12")], [])
  }

  html.div(
    [
      attribute.class(
        "grid grid-cols-[3rem_1fr_3rem] items-center gap-4 w-full max-w-fit",
      ),
    ],
    [
      left_column,
      converter_elem,
      right_column,
    ],
  )
}
