import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/currencies/currency_repository.{type CurrencyRepository}
import shared/client_state.{
  type ClientState, type ConverterState, ClientState, ConverterState,
}
import shared/currency.{type Currency}
import shared/page_data.{type PageData, PageData}
import shared/rates/rate_request.{type RateRequest, RateRequest}
import shared/rates/rate_response.{type RateResponse}
import wisp.{type Response}

pub fn get(
  currency_repository: CurrencyRepository,
  get_rate: fn(RateRequest) -> Result(RateResponse, Nil),
  client_state: Option(ClientState),
) -> Response {
  case resolve_page_data(currency_repository, get_rate, client_state) {
    Error(_) -> wisp.internal_server_error()

    Ok(page_data) -> {
      let page_data_json =
        page_data
        |> page_data.encode
        |> json.to_string

      page_data_json
      |> page_scaffold
      |> element.to_document_string
      |> wisp.html_body(wisp.response(200), _)
    }
  }
}

pub fn resolve_page_data(
  currency_repository: CurrencyRepository,
  get_rate: fn(RateRequest) -> Result(RateResponse, Nil),
  client_state: Option(ClientState),
) -> Result(PageData, Nil) {
  let default_converter = {
    let btc_id = 1
    let usd_id = 2781
    ConverterState(btc_id, usd_id, 1.0)
  }

  let client_state = case client_state {
    None -> ClientState([default_converter])
    Some(state) -> state
  }

  let currencies = currency_repository.get_all()

  let #(converters, rates) = {
    let valid_converters = {
      let validated =
        filter_valid_converters(client_state.converters, currencies)

      case validated {
        [] -> [default_converter]
        _ -> validated
      }
    }

    fetch_rates(valid_converters, get_rate)
  }

  Ok(PageData(currencies:, rates:, converters:))
}

fn filter_valid_converters(
  converters: List(ConverterState),
  currencies: List(Currency),
) {
  let currency_exists = fn(id) {
    list.any(currencies, fn(currency) { currency.id == id })
  }

  use converter <- list.filter(converters)
  currency_exists(converter.from) && currency_exists(converter.to)
}

fn fetch_rates(
  converters: List(ConverterState),
  get_rate: fn(RateRequest) -> Result(RateResponse, Nil),
) -> #(List(ConverterState), List(RateResponse)) {
  converters
  |> list.filter_map(fn(converter) {
    case get_rate(RateRequest(converter.from, converter.to)) {
      Ok(rate) -> Ok(#(converter, rate))
      Error(_) -> Error(Nil)
    }
  })
  |> list.unzip
}

fn page_scaffold(seed_json: String) -> Element(a) {
  html.html(
    [
      attribute.attribute("lang", "en"),
      attribute.attribute("data-theme", "dracula"),
    ],
    [
      html.head([], [
        html.meta([attribute.attribute("charset", "UTF-8")]),
        html.meta([
          attribute.attribute(
            "content",
            "width=device-width, initial-scale=1.0",
          ),
          attribute.name("viewport"),
        ]),
        html.title([], "rates 💹"),
        html.style(
          [],
          "@font-face {
            font-family: 'Roboto Mono';
            src: url('/static/fonts/roboto-mono/RobotoMono-VariableFont_wght.ttf') format('truetype');
            font-weight: 400;
            font-style: normal;
          }

          @font-face {
            font-family: 'Roboto Mono';
            src: url('/static/fonts/roboto-mono/RobotoMono-Italic-VariableFont_wght.ttf') format('truetype');
            font-weight: 400;
            font-style: italic;
          }

          @keyframes glow {
            0%, 100% {
              color: inherit;
              box-shadow: none;
            }
            25% {
              color: var(--glow-color);
              box-shadow: 0 0 4px var(--glow-color)
            }
          }

          .animate-glow {
            animation: glow 2s ease-in-out;
          }

          :root {
            --font-mono: 'Roboto Mono', monospace;
          }

          body {
            font-family: var(--font-mono);
          }",
        ),
        html.link([
          attribute.rel("stylesheet"),
          attribute.type_("text/css"),
          attribute.href("/static/client.css"),
        ]),
        html.script(
          [attribute.src("/static/client.js"), attribute.type_("module")],
          "",
        ),
        html.script(
          [attribute.type_("application/json"), attribute.id("model")],
          seed_json,
        ),
      ]),
      html.body([attribute.class("flex flex-col min-h-screen")], [
        html.div([attribute.id("app")], []),
      ]),
    ],
  )
}
