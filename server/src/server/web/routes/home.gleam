import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/pair
import lustre/attribute
import lustre/element.{type Element}
import lustre/element/html
import server/currencies/currency_repository.{type CurrencyRepository}
import shared/client_state.{type ClientState, ClientState, ConverterState}
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
  let client_state = case client_state {
    None -> {
      let btc_id = 1
      let usd_id = 2781
      ClientState([ConverterState(btc_id, usd_id, 1.0)])
    }

    Some(state) -> state
  }

  let currencies = currency_repository.get_all()

  // filter out converters containing a currency id that is not found in the repo
  let valid_converters =
    list.filter(client_state.converters, fn(converter) {
      let currency_exists = fn(id) {
        list.any(currencies, fn(currency) { currency.id == id })
      }

      currency_exists(converter.from) && currency_exists(converter.to)
    })

  // for each converter, fetch the rate
  // also filter out any converters for which the get_rate call failed
  let converter_rate_pairs =
    list.filter_map(valid_converters, fn(converter) {
      case get_rate(RateRequest(converter.from, converter.to)) {
        Ok(rate) -> Ok(#(converter, rate))
        Error(_) -> Error(Nil)
      }
    })

  let converters = list.map(converter_rate_pairs, pair.first)
  let rates = list.map(converter_rate_pairs, pair.second)

  Ok(PageData(currencies:, rates:, converters:))
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
