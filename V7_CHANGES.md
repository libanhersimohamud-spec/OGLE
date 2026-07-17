# LUCC/LDCC Confirmation & Retest EA — V7 changelog

## V7 — Second independent trading engine (2W → 2D → 1H)

Two fully independent engines now run side by side, sharing only the execution
infrastructure and stateless utilities:

- **Engine 0 — `1W-1D`**: the original 1W → 1D → 1H path, behaviour unchanged.
- **Engine 1 — `2W-2D`**: identical logic, with the higher timeframes doubled
  (2-Week bias, 2-Day confirmation). Same LUCC/LDCC/CC/RC detection, entry &
  pending-order logic, min-SL floor, target fixation, partial/BE/target-lock
  management, stale-entry & Daily-break invalidation, and logging.

**How independence is achieved**
- A global engine context (`g_curEng`) makes every higher-TF candle accessor
  (`W*`/`D*`) and every pattern function resolve to that engine's timeframe — the
  signal code itself is unchanged and shared.
- All *trading state* is per-engine: `g_bias[2]`, `g_sell[2]`/`g_buy[2]` (setup /
  LUCC/LDCC / CC / RC / daily counters / doneToday), engine-tagged open trades,
  pending limits, missed/skipped records, win-episodes, and weekly stats. Neither
  engine can block, complete, or otherwise affect the other.
- Trade *management* (BE @1.2R, 50% partial @2R, 82%→50% profit lock, stops,
  excursions, logging) is shared code that acts on each trade's own frozen
  parameters, so both engines are managed identically and independently.

**Synthetic higher-timeframe candles (Engine 1)**
- **2-Day** = non-overlapping consecutive weekday pairs: Mon-Tue, Wed-Thu,
  Fri-Mon, Tue-Wed, Thu-Fri, … (weekends folded into the Fri→Mon pair; realigns
  to Mon-Tue every two weeks). Deterministic via a Monday epoch and weekday-index
  pairing.
- **2-Week** = discrete non-overlapping 2-week blocks (two consecutive weekly
  candles per block).
- Built by aggregating native D1/W1 bars; the forming block updates live intrabar.

**Logging**
- Every per-trade row, opportunity-cost row, and weekly-stats row carries an
  **`Engine`** column (`1W-1D` / `2W-2D`) so each engine can be analysed alone or
  together. CSV files are shared (one dataset, engine-tagged).

**Operational note:** the daily reset cycle (per-day trade limit, `doneToday`,
pending-expiration at the new Nairobi day) is shared/calendar-based for both
engines; the *signal* structure (2W bias, 2D confirmation, 2D Daily-C1 levels) is
fully adapted per engine. `InpMoveToBEOnDailyBreak` remains off by default.

---

## V6 changelog (unchanged, still in effect)

Built on the uploaded **V5_1** baseline (V1–V4 are ignored).
No signal-detection logic (LUCC/LDCC/CC/RC, weekly bias, daily patterns) was changed —
only entry/exit management and logging.

## Behavioural changes

### 1. Minimum stop-loss floor (10 pips) + 1:4 fallback
- New input `InpMinStopLossPips = 10` — the minimum **final** SL distance. It already
  includes the 1.3 buffer and is **not** multiplied by `InpStopLossMultiplier` again.
- The Case-1 entry adjustment now improves the entry (shrinking the SL) only until the
  stop reaches the 10-pip floor. It is never tightened below it.
- If, at the 10-pip floor, the Weekly/Daily C1 target still can't provide
  `InpMinTargetRR` (2.5R), the trade is **no longer rejected**: it uses a fixed 10-pip SL
  and a fixed `InpCappedTP_R` (4R → 40-pip TP, 1:4). The TP may extend beyond C1.
- A universal 10-pip SL floor is also applied to market (Case 2/3) entries.
- Answers your Q2: V5 shrank the SL without limit to force 2.5R; V6 caps that at the floor.

### 2. Pending-limit Daily invalidation (Q3)
- New input `InpCancelLimitOnDailyBreak = true`. While a Case-1 limit is unfilled, if price
  trades beyond Daily C1 (buy: above C1 High; sell: below C1 Low) the limit is **deleted
  immediately**, the setup is marked expired, and the EA hunts a brand-new setup.

### 3. Trade management (replaces the V4 target-lock defaults)
- Breakeven trigger changed to **+1.2R** (`InpBreakevenTriggerR = 1.2`).
- New **partial close**: take 50% off at **+2R** (`InpUsePartialClose`, `InpPartialCloseR = 2.0`,
  `InpPartialClosePct = 50`); the remaining 50% runs to the final target.
- A remaining position stopped at BE is classified **BE, not a win**; the weekly bias is
  completed **only on a full TP** (partial+BE does not complete the bias).
- `InpUseTargetLock` now defaults **off** (kept for A/B research).

### 4. Stale-entry filter — 2R away-from-entry expiration (new request)
- New inputs `InpUseStaleEntryFilter = true`, `InpMaxAwayR = 2.0`.
- Tracks how far price ran **away** (profit direction) from the planned RC entry level
  before returning to retest it — during the armed wait **and** during an unfilled Case-1
  limit's life.
- If that away-move exceeds `InpMaxAwayR` × the planned SL distance, the setup is stale:
  any pending limit is cancelled, it is marked Expired, and the EA hunts a new setup.
  Applies to not-yet-triggered entries only; open trades are never touched.

## New logging (research platform)

**Trade log** (`LUCC_LDCC_TradeLog.csv`) — new columns:
- Entry regime: `EntryType`, `TargetSource`, `PlannedRR_V6`, `LimitPlacedTime`, `LimitWaitBars`, `LimitFilled`.
- Daily patterns + combos: `DailyBuyPatterns`, `DailySellPatterns`, `DailyTradeSidePatterns`,
  `DailyComboKey`, `WeeklyDailyComboKey`.
- Breakeven timing + partial close: `BEArmTime`, `BarsToBE`, `PartialTaken`, `PartialTime`,
  `PartialLots`, `PartialPrice`, `PartialProfit`, `BarsToPartial`, `PartialCloseR_Cfg`.
- Lifecycle / drawdown: `MaxDD_Money`, `SecondsInProfit`, `SecondsInDrawdown`, `PctTimeInProfit`,
  `TimeToFirst1R_Min`, `TimeToTP_Min`, `MinStopLossPips_Cfg`.
- Away-from-entry: `MaxAwayBeforeEntry_R`, `MaxAwayBeforeEntry_Pips`, `MaxAwayR_Cfg`.

**Opportunity-cost log** (`LUCC_LDCC_MissedSetups.csv`) — now also captures **skipped** setups
(not just RC-never): `InpLogSkippedSetups = true`. Every setup blocked by a rule
(`SkipBias`, `SkipDailyConf`, `SkipAfterWin`, `SkipDoneToday`, `SkipMaxTrades`,
`SkipStale2R`) or cancelled (`LimitDailyBreak`, `LimitStale2R`) is written with its reason
and a hypothetical "enter at CC close" forward outcome (MaxFavR, would-it-have-won, TP/SL).
New column `DailySidePatterns`.

The existing per-trade **path log** (`LUCC_LDCC_PathLog.csv`, bar-by-bar OHLC + fav/adv R)
already makes trailing / alternative BE / alternative exit simulations fully replayable offline.

## Verification
Static verification only (no MetaEditor/MT5 toolchain in this environment):
brace/paren/bracket balance OK; trade-log header/row column parity 134 = 134; missed-log
parity 34 = 34; all new symbols resolve. A latent V5→V6 compile bug (an orphaned
`ProcessNewBar` body) was found and fixed. **Please compile once in MetaEditor and run a
short backtest to confirm before a full multi-year run.**
