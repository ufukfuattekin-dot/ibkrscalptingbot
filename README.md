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

### Walk-forward (out-of-sample stability)

Single-pass backtests overfit. Walk-forward splits the data into N
consecutive windows and reports stability across them. A strategy that's
only good in-sample fails this test.

```bash
curl -XPOST localhost:8000/api/v1/backtest/walkforward \
  -H 'Content-Type: application/json' \
  -d '{"symbol":"PLTR","duration":"180 D","cost_model":"ibkr_pro","n_folds":6}'
```

Or use the **Walk-Forward** tab on the Backtest page in the dashboard.

### Multi-symbol stability report

Runs walk-forward across many symbols and writes a markdown + JSON
report. Use this before deploying a strategy to paper trading: a
strategy that's STABLE on 1 of 10 names is name-specific, not a
generalizable edge.

**Prereqs:** IB Gateway must be reachable. Set `IB_USERID` /
`IB_PASSWORD` in `.env` (paper account is fine — `TRADING_MODE=paper`
points to port 4002 by default), then:

```bash
docker compose up -d postgres redis ib-gateway backend
docker compose exec backend python -m app.cli.run_report \
    --symbols-file data/symbols.txt \
    --duration "180 D" \
    --folds 6 \
    --cost-model ibkr_pro

# or one-off:
docker compose exec backend python -m app.cli.run_report \
    --symbols PLTR,SOFI,RIVN,HOOD --duration "120 D" --folds 5
```

Output lands in `backend/reports/<UTC_TIMESTAMP>/report.md` and
`report.json`. The markdown is grouped: STABLE symbols first, FRAGILE
last, with a portfolio verdict at the top:

| % of symbols STABLE | Verdict |
|---|---|
| ≥ 60% | ✅ Edge generalizes — proceed to paper trading |
| 30–60% | ⚠️ Marginal — name-specific edge, no portfolio deploy |
| < 30% | ❌ Curve-fit, do not deploy |

### Parameter sweep (grid search over engine knobs)

Once walk-forward shows your strategy is at least MIXED, sweep the engine
knobs to find a more stable configuration. The sweep evaluates each
combination by walk-forward across multiple symbols, then ranks by a
stability metric (default: `robust_sharpe = sharpe_mean − 0.5 × sharpe_std`).

**Default grid** (48 combinations):

| Param | Values |
|---|---|
| `trail_after_r` | 0.5, 1.0, 1.5, 2.0 |
| `trail_atr_mult` | 0.75, 1.0, 1.5, 2.0 |
| `per_trade_risk_pct` | 0.25, 0.5, 1.0 |

**Ranking metrics** (configurable):
- `robust_sharpe` — Sharpe mean minus 0.5×std (default; rewards consistency)
- `calmar` — mean return / |worst fold return| (penalizes worst case)
- `mean_return` — pure mean return
- `profitable_pct` — % of folds in the green

```bash
# CLI sweep with the default grid:
docker compose exec backend python -m app.cli.run_sweep \
    --symbols-file data/symbols.txt \
    --duration "180 D" \
    --folds 5 \
    --ranking-metric robust_sharpe

# Custom grid via JSON:
echo '{"trail_after_r":[0.5,1.0,1.5],"trail_atr_mult":[0.75,1.0],"per_trade_risk_pct":[0.25,0.5]}' > grid.json
docker compose exec backend python -m app.cli.run_sweep \
    --symbols PLTR,SOFI,RIVN \
    --grid-file grid.json
```

Or use the **Param Sweep** tab on the Backtest page in the dashboard.
Output: `backend/reports/sweep_<UTC_TIMESTAMP>/sweep.{md,json}` with the
top-N ranked combinations and a per-symbol breakdown of the winner.

> **Multiple-comparisons caveat:** with dozens of combos tried, the top
> combo's score is biased upward by chance. Treat the top-3 as roughly
> equivalent and prefer the lowest-variance profile. Re-run on a more
> recent window to confirm before deploying.

### Applying a sweep result to live (one-click)

Each row of the sweep result table has an **Apply** button. Click it to
push those params into the running backend:

- Strategy attributes (`momentum.min_rvol`, `rsi.oversold`, etc.) are
  mutated on the live strategy instances.
- Engine knobs (`trail_after_r`, `trail_atr_mult`, `enable_trailing`,
  `per_trade_risk_pct`) are written into the in-memory `Settings`. The
  `TrailingManager` and `RiskManager` read from `Settings` per use, so
  the change is picked up on the next event without a restart.
- Params are persisted to Postgres (`settings.active_params`) and
  audited (who, when, which sweep rank/score). On the next backend
  restart, `ActiveConfig.load()` re-applies them automatically.

A confirmation modal shows the param diff before commit. The Settings
page has an **Active Config** card summarizing what's live, with a
**Reset to env defaults** button to revert.

API endpoints (you can call these directly too):

```bash
curl -s localhost:8000/api/v1/config/active | jq
curl -XPOST localhost:8000/api/v1/config/apply \
  -H 'Content-Type: application/json' \
  -d '{"params":{"momentum.min_rvol":2.5,"engine.trail_after_r":1.5}}'
curl -XPOST localhost:8000/api/v1/config/reset-defaults
```

### Strategy-level sweep

The same sweep also tunes per-strategy parameters (RSI oversold threshold,
EMA `target_r`, momentum `min_rvol`, etc.) — not just engine knobs.
Grid keys can be **namespaced**:

| Key | Routes to |
|---|---|
| `engine.trail_after_r` | `BacktestEngine` kwarg |
| `momentum.min_rvol` | `MomentumBreakoutStrategy` kwarg |
| `ema.target_r` | `EmaTrendStrategy` kwarg |
| `rsi.oversold` | `RsiReversalStrategy` kwarg |

Built-in strategy presets (run one strategy at a time):

```bash
docker compose exec backend python -m app.cli.run_sweep \
    --symbols-file data/symbols.txt --duration "180 D" \
    --strategy-preset rsi --ranking-metric robust_sharpe
```

In the dashboard's **Param Sweep** tab, the "Sweep Target" dropdown picks
between the engine knob grid and any strategy preset.

## Observability (Prometheus + Grafana)

The backend exposes Prometheus metrics at `/metrics`. Spin up the full
stack with Prometheus + Grafana:

```bash
docker compose up -d prometheus grafana
```

- **Prometheus:** http://localhost:9090 — query `scalper_account_equity_dollars`, etc.
- **Grafana:** http://localhost:3000 — anonymous viewer enabled; admin login `admin/admin` (override via `GRAFANA_ADMIN_PASSWORD`).
- A pre-provisioned dashboard "**Scalper — Live Overview**" is auto-imported
  into the `Scalper` folder (broker status, equity, PnL, signals/min,
  rejections by rule, exit-reason mix, scanner latency p50/p95).

Metrics exposed:

| Type | Name | Labels |
|---|---|---|
| Gauge | `scalper_broker_connected` | – |
| Gauge | `scalper_account_equity_dollars` | – |
| Gauge | `scalper_realized_pnl_today_dollars` | – |
| Gauge | `scalper_unrealized_pnl_dollars` | – |
| Gauge | `scalper_open_positions` | – |
| Gauge | `scalper_circuit_breaker_tripped` | – |
| Gauge | `scalper_consecutive_losses` | – |
| Gauge | `scalper_universe_size` | – |
| Gauge | `scalper_trading_mode_paper` | – |
| Counter | `scalper_signals_total` | `strategy` |
| Counter | `scalper_signals_rejected_total` | `rule` |
| Counter | `scalper_orders_filled_total` | `side` |
| Counter | `scalper_positions_closed_total` | `reason` |
| Counter | `scalper_realized_pnl_total_dollars` | – |
| Counter | `scalper_realized_loss_total_dollars` | – |
| Counter | `scalper_errors_total` | `level` |
| Histogram | `scalper_scan_duration_seconds` | – |

### Suggested alert rules

Wire these into a Prometheus rules file once you go to paper trading 24/7:

| Expr | When to fire | Severity |
|---|---|---|
| `scalper_broker_connected == 0` for 30s | broker socket dead | **page** |
| `rate(scalper_errors_total{level="error"}[5m]) > 0.1` | error storm | warn |
| `scalper_circuit_breaker_tripped == 1` | day flatlined | info |
| `histogram_quantile(0.95, sum(rate(scalper_scan_duration_seconds_bucket[5m])) by (le)) > 5` | scanner falling behind | warn |
| `(scalper_realized_loss_total_dollars - scalper_realized_loss_total_dollars offset 1d) > $YOUR_DAILY_LOSS_LIMIT` | breached daily loss cap | **page** |
| `rate(scalper_signals_total[15m]) == 0` during RTH | no activity at all (data feed dead?) | warn |

Cardinality discipline: every label set is small and finite
(strategy ∈ 3, side ∈ 2, reason ∈ 5, rule ∈ ~10, level ∈ 4).
Adding new metrics: define in `backend/app/observability/metrics.py` and
subscribe to the relevant event in `MetricsRecorder.start()`.

## Tests

```bash
docker compose exec backend pytest -q
```

## First-day paper trading

There's a complete walkthrough in [`docs/RUNBOOK.md`](docs/RUNBOOK.md) —
`.env` setup, smoke-test interpretation, what to watch on the dashboards,
how to read the first signal/fill/close cycle, and a troubleshooting
matrix.

Quick sequence:

```bash
cp .env.example .env                          # fill in IB_USERID / IB_PASSWORD
docker compose up -d postgres redis ib-gateway
docker compose logs -f ib-gateway             # wait for "API server listening"
docker compose up -d backend worker frontend prometheus grafana

# Verify every surface is healthy before relying on it:
docker compose exec backend python -m app.cli.smoke_test --symbol AAPL
```

Expect 9 PASS rows. If any FAIL, **do not trade** until resolved.

## Going live (don't do this until you've paper-traded for a week)

1. Set `TRADING_MODE=live`
2. Set `ENV=prod`
3. Point `IB_PORT=4001` (or `7496` for TWS) and use a real account number.
4. Restart. The risk manager refuses live trades when `ENV != prod`.
