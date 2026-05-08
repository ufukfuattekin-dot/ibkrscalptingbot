# Scalper — Automated US Equities Day-Trading Platform

Production-shaped intraday trading platform for small/mid-cap US stocks
($2 – $20). Connects to **Interactive Brokers** via `ib_insync`, streams
live data, scans the universe in real time, runs three configurable
strategies, gates every signal through a strict risk manager, and ships
trade alerts to Telegram. Includes a backtesting engine and a React
dashboard.

> **Default mode is paper trading.** Going live requires changing
> `TRADING_MODE=live` in `.env` AND running with `ENV=prod`. Anything
> else is rejected by the risk gate.

## Stack

- **Backend** — Python 3.11, FastAPI, ib_insync, asyncpg, SQLAlchemy 2.0 (async), Redis, structlog.
- **Frontend** — Vite, React 18, TypeScript, Tailwind, recharts, zustand, swr.
- **Infra** — Docker Compose (Postgres 16, Redis 7, IB Gateway, backend, worker, frontend).

## Quick start

```bash
cp .env.example .env
# 1. Set IB_USERID / IB_PASSWORD (paper account) for IB Gateway
# 2. Set TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID if you want alerts
docker compose up --build
```

- API:        http://localhost:8000  (Swagger at `/docs`)
- WebSocket:  ws://localhost:8000/ws
- Frontend:   http://localhost:5173

## Project layout

```
backend/app/
├── core/         config, logging, event bus, market clock
├── domain/       enums + plain dataclasses
├── brokers/      BaseBroker, IBBroker, PaperBroker, factory
├── data/         MarketDataEngine, candle aggregator, universe
├── indicators/   EMA, MACD, RSI, VWAP, ATR, Bollinger, RVOL
├── scanner/      filters, scoring signals, scanner engine
├── strategies/   base + Momentum / EMA-trend / RSI-reversal + engine
├── risk/         RiskManager (gate), position sizer, circuit breaker
├── execution/    Executor (signal→order), trailing stop helper
├── notifications/Telegram notifier
├── backtesting/  bar-by-bar engine + metrics
├── persistence/  SQLAlchemy async, ORM models, repositories
├── api/          FastAPI app, runtime container, WebSocket hub, v1 routes
└── workers/      standalone worker entrypoint
frontend/src/
├── api/    client + types
├── store/  WebSocket-fed zustand store
└── pages/  Dashboard, Scanner, Positions, Journal, Backtest, Settings
```

## Pipeline

```
IB Gateway → IBBroker → MarketDataEngine → indicators
                                       ↘
                                    Scanner → ScanResult event
                                                ↓
                                       StrategyEngine → Signal event
                                                ↓
                                          RiskManager.gate()
                                                ↓
                                          Executor → broker bracket
                                                ↓
                                       OrderFilled / PositionClosed
                                                ↓
                                  Telegram + WebSocket + DB
```

## Filters (in `.env`)

| Var                          | Default     | Meaning                                |
|------------------------------|-------------|----------------------------------------|
| `FILTER_MIN_PRICE`           | 2.0         | Min last price                         |
| `FILTER_MAX_PRICE`           | 20.0        | Max last price                         |
| `FILTER_MIN_DAILY_VOLUME`    | 1,000,000   | Min cumulative-day volume              |
| `FILTER_MIN_RVOL`            | 2.0         | Relative volume threshold              |
| `FILTER_MAX_FLOAT`           | 50,000,000  | Max public float                       |
| `FILTER_MAX_SPREAD_BPS`      | 50          | Max bid/ask spread in basis points     |

Halted, earnings-today, and excessive-spread names are also dropped.

## Risk

| Rule                                   | Default | Behaviour                       |
|----------------------------------------|---------|---------------------------------|
| Max daily loss (% equity)              | 2.0     | Trips circuit breaker for the day |
| Max loss per trade (% equity)          | 0.5     | Sets share count via stop distance |
| Max simultaneous open positions        | 5       | Reject if at cap                |
| Max account exposure (% equity)        | 50      | Caps notional per trade         |
| Cooldown after a loss (sec)            | 300     | Block new entries briefly       |
| Consecutive losses → circuit breaker   | 3       | Halt entries for the rest of day |

Every signal must pass `RiskManager.gate()`. The executor only ever takes
output from the gate — there is no other path to the broker.

## Strategies

1. **Momentum Breakout** — RVOL surge + close > VWAP + MACD bull cross + green candles + volume burst + intraday-resistance break.
2. **EMA Trend Continuation** — EMA9 > EMA20 > EMA50, pullback into EMA9, bullish continuation, volume confirmation.
3. **RSI Reversal** — RSI < 30 turning up, bullish reversal candle, MACD histogram improving, support rejection (BB lower or rolling low).

Each strategy is a pure function of an enriched 1-minute DataFrame.
Toggle individually via `/api/v1/strategies/{name}/toggle` or in the
Settings page of the dashboard.

## Backtesting

```bash
curl -XPOST localhost:8000/api/v1/backtest \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"PLTR","duration":"60 D","bar_size":"1 min"}'
```

Returns metrics (trades, win rate, profit factor, Sharpe, max drawdown,
return %), trade list, and equity curve.

## Tests

```bash
docker compose exec backend pytest -q
```

## Going live (don't do this until you've paper-traded for a week)

1. Set `TRADING_MODE=live`
2. Set `ENV=prod`
3. Point `IB_PORT=4001` (or `7496` for TWS) and use a real account number.
4. Restart. The risk manager refuses live trades when `ENV != prod`.
