# rates 💹

A real-time cryptocurrency and fiat currency converter with live WebSocket updates, built with [Gleam](https://gleam.run/).
Check it out at [rates.fly.dev](https://rates.fly.dev/?state=v1%3A1-2781%3B1027-2781%3B2010-2781)!

![Gleam](https://img.shields.io/badge/gleam-%23ffaff3.svg?style=flat&logo=gleam&logoColor=black)
![Erlang](https://img.shields.io/badge/Erlang-white.svg?style=flat&logo=erlang&logoColor=a90533)
![JavaScript](https://img.shields.io/badge/javascript-%23323330.svg?style=flat&logo=javascript&logoColor=%23F7DF1E)

## Features

- **Multiple Simultaneous Converters** - Add as many currency conversion widgets as you need
- **Real-Time Updates** - Live exchange rates via WebSocket connections to Kraken
- **Dual Data Sources** - Primary data from Kraken WebSocket API with CoinMarketCap fallback for currencies not available on Kraken
- **Stateful URLs** - Your converter setup is saved in URL query parameters for easy bookmarking and sharing
- **Resilient Connections** - Automatic reconnection
- **Theme Support** - Light and dark mode with smooth transitions

## Local development

Requires Gleam, Erlang/OTP, rebar3, Node.js, and npm. Install the client npm
dependencies once from the repo root (and again when they change):

```sh
npm ci --prefix client
```

Set `SECRET_KEY_BASE` and `COIN_MARKET_CAP_API_KEY` in `server/.env` or export them
in your shell. Then run from the repo root:

```sh
./dev
```

This builds the client assets, loads `server/.env` if present, and starts the
server at <http://localhost:8080>. It does not reinstall npm dependencies. Stop
with Ctrl+C and rerun after making changes.

## Tests

Run all test suites from the repo root:

```sh
./test
```

This tests shared on Erlang and JavaScript, client on JavaScript, and server on
Erlang. It stops if any suite fails.

## Architecture

This application is structured as a monorepo with three Gleam projects:

### 📦 Projects

```text
rates/
├── client/    # Lustre SPA with Elm Architecture (compiles to JavaScript)
├── server/    # Wisp web framework + Mist web server (compiles to Erlang)
└── shared/    # Shared types
```

## Tech Stack

- **Language**: [Gleam](https://gleam.run/) - Type-safe functional language
- **Frontend**: [Lustre](https://github.com/lustre-labs/lustre) + JavaScript (via FFI)
- **Backend**:  [Wisp](https://github.com/gleam-wisp/wisp) + [Mist](https://github.com/rawhat/mist) + [OTP](https://github.com/gleam-lang/otp)
- **Data Sources**: [Kraken WebSocket API](https://docs.kraken.com/api/) + [CoinMarketCap API](https://coinmarketcap.com/api/)
- **Deployment**: Docker + [Fly.io](https://fly.io/)
- **Styling**: [TailwindCSS](https://tailwindcss.com/) + [daisyUI](https://daisyui.com/)

## How It Works

1. **Initial Load**: Server serves HTML with the currency catalog and converter state embedded as JSON, without fetching rates
2. **Client Rendering**: The Lustre app renders the converters and waits for quotes, showing loading indicators after a short delay
3. **WebSocket Connection**: Client establishes WebSocket connection to server
4. **Subscriptions**: Client sends subscription requests for currency pairs
5. **Rate Updates**: Server sends initial quotes and subsequent updates through WebSocket
6. **UI Updates**: Client reactively updates the UI with new rates
7. **State Persistence**: URL updates automatically to persist converter state

### Rate Flow

```text
User adds BTC/USD converter
    ↓
Client subscribes via WebSocket
    ↓
Server checks if already subscribed to BTC/USD
    ↓
If new: Server subscribes to Kraken WebSocket
    ↓
Kraken sends price updates
    ↓
Server broadcasts to all interested clients
    ↓
Client updates UI with new rate
```
