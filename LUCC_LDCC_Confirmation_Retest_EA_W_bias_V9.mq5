//+------------------------------------------------------------------+
//|              LUCC_LDCC_Confirmation_Retest_EA_V9.mq5             |
//|                                                                    |
//| Expert Advisor port of "LUCC / LDCC Confirmation & Retest         |
//| Indicator" (Pine v6).                                              |
//|                                                                    |
//| ==== V9 CHANGE — SIX INDEPENDENT ENGINES ======================== |
//| Four more fully independent engines are added (six total), each    |
//| differing ONLY in its higher-timeframe hierarchy; all share the    |
//| same 2H entry TF and identical entry / management / logging logic: |
//|   Engine 0: 1W  -> 1D -> 2H     Engine 3: 5D  -> 1D -> 2H          |
//|   Engine 1: 2W  -> 2D -> 2H     Engine 4: 5D  -> 2D -> 2H          |
//|   Engine 2: 10D -> 2D -> 2H     Engine 5: 1W  -> 2D -> 2H          |
//| Per engine, the bias/confirmation accessors resolve to that        |
//| engine's timeframe via g_engBias[]/g_engConf[] "kinds" (native W1/ |
//| D1, or synthetic 2W / 5D / 10D / 2D blocks). Synthetic blocks:      |
//|   2W  = 2 calendar weeks (from W1);                                 |
//|   5D  = one Mon-Fri trading week, 10D = two trading weeks,          |
//|   2D  = Mon-Tue/Wed-Thu/Fri-Mon pairs (all from D1, weekday-index).|
//| Every engine keeps its OWN bias, setup/LUCC/LDCC/CC/RC state,      |
//| pending orders, open trades, counters, win-episodes and stats; no  |
//| engine can affect another. Each CSV row carries the Engine column. |
//|                                                                    |
//| ==== V8 CHANGE — ENTRY TIMEFRAME 1H -> 2H ======================= |
//| The ONLY change from V7: the entry timeframe is now 2H (PERIOD_H2) |
//| instead of 1H. All entry-signal detection (LUCC/LDCC, CC, RC), the |
//| new-bar trigger, pending-order & entry-expiration logic, and every |
//| entry-candle count now run on 2H, via the single ENTRY_TF constant.|
//| Both engines still use this same entry TF; only their higher       |
//| timeframes differ (Engine 0: 1W/1D, Engine 1: 2W/2D). Everything   |
//| else — bias, confirmation, trade management, targets, stops,       |
//| partial/BE/lock, CSV structure, statistics, research — is          |
//| byte-for-byte identical to V7.                                     |
//|                                                                    |
//| ==== V7 CHANGES — SECOND INDEPENDENT ENGINE ===================== |
//| Two fully independent trading engines run side by side, sharing    |
//| ONLY the execution infrastructure and stateless utilities:         |
//|   Engine 0: 1W -> 1D -> 1H  (the original path, behaviour unchanged)|
//|   Engine 1: 2W -> 2D -> 1H  (identical logic, higher TFs doubled)   |
//| The ONLY difference is the higher-timeframe candle source. A global |
//| engine context (g_curEng) makes every W*/D* accessor and every      |
//| pattern function resolve to that engine's timeframe with no change  |
//| to the signal code. 2-Day candles = non-overlapping consecutive     |
//| weekday pairs (Mon-Tue / Wed-Thu / Fri-Mon, realigning every 2      |
//| weeks); 2-Week candles = discrete non-overlapping 2-week blocks.    |
//| Each engine keeps its OWN bias, setup/LUCC/LDCC/CC/RC state,        |
//| pending orders, open trades, counters, win-episodes, weekly-stop,   |
//| and statistics; neither ever blocks or affects the other. Every     |
//| CSV row carries an Engine column ("1W-1D" / "2W-2D"). Trade         |
//| MANAGEMENT (BE / partial / lock / stops / logging) is shared code   |
//| that acts on each trade's own frozen parameters, so both engines    |
//| are managed identically and independently.                         |
//|                                                                    |
//| ==== V6 CHANGES ================================================== |
//| 1. MIN STOP-LOSS FLOOR (10 pips, already buffered — no extra x1.3): |
//|    the Case-1 entry adjustment reduces the stop only until it       |
//|    reaches 10 pips. If, at the 10-pip floor, the Weekly/Daily C1    |
//|    target still can't provide InpMinTargetRR, the trade is NOT      |
//|    rejected: a fixed 10-pip SL + 40-pip TP (1:4) is used, and the   |
//|    TP is allowed to extend beyond the C1 level.                     |
//| 2. PENDING-LIMIT DAILY INVALIDATION: while a Case-1 limit is        |
//|    pending, if price trades beyond Daily C1 (buy: above C1 High,    |
//|    sell: below C1 Low) the limit is deleted immediately, the setup  |
//|    is marked expired, and the EA hunts a brand-new setup.           |
//| 3. TRADE MANAGEMENT — a three-stage ladder on each trade:           |
//|      - Stage 1: move the SL to breakeven at +1.2R.                  |
//|      - Stage 2: take 50% off at +2R (partial); the remaining 50%    |
//|        runs on.                                                     |
//|      - Stage 3: at 82% of the total target, move the runner's SL to |
//|        50% of the total target (percentage-based profit lock that   |
//|        scales to any RR). Only ever tightens into profit.           |
//|      - A remaining position stopped at BE is a BREAKEVEN trade, not |
//|        a win; a runner stopped at the lock is a LOCK exit; the      |
//|        Weekly bias is completed ONLY on a full TP.                  |
//| 4. RESEARCH PLATFORM LOGGING: actual Daily patterns at entry,       |
//|    Weekly x Daily combos, entry type / limit wait candles / fill /  |
//|    expiry, partial-close geometry, BE-arm timing, time in profit vs |
//|    drawdown, max floating drawdown, and an opportunity-cost capture |
//|    of every skipped / expired / invalidated setup with a            |
//|    hypothetical forward outcome — so the CSVs can answer virtually  |
//|    any research question without re-running the backtest.           |
//|                                                                    |
//| ==== V4 CHANGES (trade management only — signal logic untouched) = |
//| 1. BREAKEVEN STOP: once an open trade's floating profit reaches    |
//|    InpBreakevenTriggerR (in R, i.e. multiples of the trade's own   |
//|    risk distance — NOT a fixed pip value), the SL is moved to the  |
//|    entry price (optionally +InpBreakevenLockR of locked profit).   |
//|    The trigger is an INPUT so the Strategy-Tester Optimizer can    |
//|    sweep it (1.0 / 1.25 / 1.5 / 1.75 / 2.0 ...).                   |
//| 2. BREAKEVEN OUTCOME: a trade stopped at that breakeven level is   |
//|    classified as BE — neither a win nor a loss. It does NOT book a |
//|    win, does NOT arm the daily win-stop, and does NOT arm the      |
//|    stop-after-first-win-per-weekly-bias lock. The EA keeps hunting |
//|    new valid setups under the SAME weekly bias.                    |
//| 3. Only a genuine TAKE-PROFIT exit counts as a win and activates   |
//|    the "no more trades for this weekly bias" rule (and doneToday). |
//| Outcome is now decided by the EXIT PRICE (TP / BE / SL), not by    |
//| the sign of net profit, so a small +swap on a BE exit can never be |
//| mis-booked as a win.                                               |
//|                                                                    |
//| ==== V4_2: target-% profit lock (see below, retained) ===========  |
//|                                                                    |
//| ==== V5 CHANGES ================================================== |
//| A. PER-PATTERN WEEKLY INVALIDATION: trading through Weekly Candle-1 |
//|    no longer kills the WHOLE side. BC and DC stay valid; all other  |
//|    Weekly patterns are still invalidated for the week.             |
//| B. DAILY CONFIRMATION is now MANDATORY / hard-wired ON (a BUY needs |
//|    >=1 Daily buy pattern, a SELL >=1 Daily sell) — cannot be off.   |
//| C. TARGET FIXATION: the default target is Weekly Candle-1 High(buy) |
//|    / Low(sell) instead of a fixed RR. The SL is the RC structural   |
//|    stop x1.3 buffer and is a FIXED level that is never moved.       |
//|      - RR to target < InpMinTargetRR (2.5): keep the SL, place a    |
//|        pending BUY/SELL LIMIT at a better entry so RR = exactly 2.5.|
//|      - 2.5 <= RR <= 4: take the level as-is (market entry).         |
//|      - RR > InpMaxTargetRR (4): cap the target at 4R (market).      |
//|    For BC/DC only, once price trades through Weekly C1 the target   |
//|    source switches from Weekly C1 to DAILY C1 (same RR-band logic). |
//|    Unfilled Case-1 limits are cancelled at the next Nairobi day.    |
//+------------------------------------------------------------------+
//|                                                                    |
//| LUCC/LDCC candidate search, the PROTECTED / NOT-CONTAINED filters, |
//| and the Confirmation Candle (CC) rule are a line-for-line mirror   |
//| of the indicator, evaluated only on fully closed H1 bars (never    |
//| the forming bar) so that part cannot repaint.                     |
//|                                                                    |
//| The Retest Candle (RC) is intentionally NOT bar-close detection.  |
//| Once the CC closes, the EA watches price tick-by-tick and treats  |
//| the very first tick that touches the LUCC Low / LDCC High as the  |
//| RC, executing the market order immediately on that tick — not on  |
//| the candle after it. This is still non-repainting: the only       |
//| closed-bar confirmation is the CC; the RC is a real-time price     |
//| event that, once it happens, is a fixed historical fact and is    |
//| never re-evaluated or undone.                                     |
//|                                                                    |
//| Offset convention: BarX(0) = the bar that JUST closed (equivalent |
//| to offset 0 / "close[0]" at the instant barstate.isconfirmed was  |
//| true in the indicator). BarX(i) = i bars before that. In MQL5     |
//| shift terms this is always (i + 1), because shift 0 is the        |
//| still-forming live bar, which the closed-bar part of this EA      |
//| never reads.                                                       |
//+------------------------------------------------------------------+
#include <Trade/Trade.mqh>

//======================================================================
// Inputs
//======================================================================
input group "Risk Management"
input double InpRiskPercent          = 1.0;     // Risk per trade (% of the FIXED reference balance below)
input double InpFixedRiskBalance     = 0;       // Reference balance for risk sizing (0 = use balance at EA start; never updated after that, so no compounding)
input long   InpMagicNumber          = 20260716; // Magic number
input int    InpSlippagePoints       = 20;       // Max slippage (points)

input group "Stop Loss & Take Profit"
input double InpTakeProfitRMultiple  = 3.0;   // TP distance = this many x the FINAL SL distance
                                               // (spec: fixed 1:3 R:R measured from the buffered stop,
                                               // so realized reward is a true 3x the money risked.
                                               // Left as an input so Strategy Tester's Optimizer can
                                               // still sweep it.)
input double InpStopLossMultiplier    = 1.3;  // FINAL SL distance = original structural SL range x this.
                                               // Proportional buffer that scales with the setup size
                                               // (e.g. 10p->13p, 20p->26p, 30p->39p), replacing the old
                                               // fixed +pip pad. Risk is held constant (lots shrink).
input double InpPipSizePoints         = 0;    // Points per pip for the CSV pip conversions (0 = auto:
                                               // 10 points on 3/5-digit symbols, 1 point on 2/4-digit)

input group "Breakeven Stop (V6: BE @ +1.2R)"
input bool   InpUseBreakeven         = true;  // Move the SL to breakeven once the trade reaches the R-trigger below
input double InpBreakevenTriggerR    = 1.2;   // V6: arm breakeven when floating profit reaches this many R (multiples
                                               // of the trade's OWN risk distance = |entry - initial SL|, NOT a fixed
                                               // pip value). V6 default 1.2R. Optimizer-sweepable.
input double InpBreakevenLockR       = 0.0;   // Where to park the SL when armed, in R from entry (0.0 = exact
                                               // breakeven). e.g. 0.1 locks +0.1R of profit to cover costs. Optional;
                                               // must be < InpBreakevenTriggerR. Leave at 0 for a pure breakeven.

input group "Partial Profit (V6: take 50% off at +2R)"
input bool   InpUsePartialClose      = true;  // V6: close part of the position at InpPartialCloseR and let the rest
                                               // run to the final target. Stage 2 of the trade-management ladder
                                               // (BE @1.2R -> partial 50% @2R -> target-% profit lock @82%).
input double InpPartialCloseR        = 2.0;   // Arm the partial close when floating profit reaches this many R.
input double InpPartialClosePct      = 50.0;  // Percent of the ORIGINAL position volume to close at that point
                                               // (the remainder runs to the final TP). 50 = take half off.

input group "Target-% Profit Lock (V6: 82% -> 50% profit lock on the runner)"
input bool   InpUseTargetLock        = true;  // Stage 3 of the ladder: once price reaches InpTargetLockTriggerPct of
                                               // the TOTAL target distance, move the remaining 50% runner's SL to
                                               // InpTargetLockSLPct of the target (locked profit). Percentage-based,
                                               // so it scales to ANY RR (3R -> arm 2.46R, lock 1.50R; 4R -> arm 3.28R,
                                               // lock 2.00R) with no code change. Only ever tightens the stop further
                                               // into profit — it runs after BE@1.2R and the +2R partial and
                                               // supersedes them (parks the SL deeper in profit).
input double InpTargetLockTriggerPct = 82.0;  // Arm when floating profit reaches this % of the target distance
                                               // (e.g. 82% of a 3R target = 2.46R; of a 4R target = 3.28R).
input double InpTargetLockSLPct      = 50.0;   // Move the SL to this % of the target distance, in profit
                                               // (e.g. 50% of a 3R target = 1.50R; of a 4R target = 2.00R).
                                               // Must be < InpTargetLockTriggerPct. Both are optimizable.
input bool   InpTargetLockCountsAsWin = false; // Does a trade stopped at this profit-lock count as a TP-style WIN
                                               // for the "stop trading after a win per weekly bias" rule?
                                               // false (default) = only a FULL take-profit stops the weekly bias;
                                               //   a lock exit banks profit but the EA keeps hunting the same bias.
                                               // true = a profit-lock exit also arms the stop-after-win rule.
                                               // (P&L/win-rate stats always count a lock exit as a winning trade.)

input group "Weekly-Target Fixation & Entry Adjustment (V5)"
input bool   InpUseWeeklyTargetFixation = true; // ON  = target the Weekly Candle-1 High (buy) / Low (sell) with the
                                                //       RR-band entry logic below, instead of a fixed-RR take-profit.
                                                // OFF = fall back to the classic fixed 1:InpTakeProfitRMultiple TP.
input double InpMinTargetRR          = 2.5;   // Case 1: if RR from the (RCx1.3) stop to the fixed target is BELOW
                                               // this, DON'T reject — keep the SL fixed and place a pending BUY/SELL
                                               // LIMIT at a better entry so the final RR becomes exactly this value.
input double InpMaxTargetRR          = 4.0;   // Case 3: if the fixed target gives MORE than this many R, ignore the
                                               // level and use a hard target of exactly this many R (market entry).
                                               // (Case 2, InpMinTargetRR..InpMaxTargetRR, is taken as-is at market.)
input double InpMinStopLossPips      = 10.0;  // V6: MINIMUM stop-loss distance in pips. This value ALREADY includes
                                               // the 1.3 buffer — it is NOT multiplied by InpStopLossMultiplier again.
                                               // Case 1 improves the entry (reducing the SL distance) only until the
                                               // stop reaches this floor; it is never tightened below it.
input double InpCappedTP_R           = 4.0;   // V6: if, at the 10-pip SL floor, the C1 target still can't provide
                                               // InpMinTargetRR, DON'T reject the trade — use a fixed SL = the floor
                                               // and a fixed TP = this many R (default 4 => 10-pip SL, 40-pip TP,
                                               // 1:4). The TP is allowed to extend beyond the Weekly/Daily C1 level.
input bool   InpCancelLimitOnDailyBreak = true; // V6: while a Case-1 pending limit is unfilled, if price trades beyond
                                               // Daily C1 (buy: above C1 High; sell: below C1 Low) delete the limit
                                               // immediately, mark the setup expired, and hunt a brand-new setup.

input group "Timezone (all logged times = Africa/Nairobi, UTC+3, no DST)"
input bool   InpAutoDetectBrokerOffset = true; // Auto-detect the broker's UTC offset (TimeCurrent-TimeGMT)
                                               // so logged times always land on Africa/Nairobi and match
                                               // TradingView. If your broker/tester reports GMT oddly and
                                               // times look wrong, turn this OFF and set the manual offset
                                               // below. The detected offset is printed to the Experts log.
input double InpBrokerGmtOffsetHours = 2.0;   // MANUAL broker STANDARD (winter) UTC offset (used only when
                                               // auto-detect is OFF, or as the pre-detect fallback)
input bool   InpBrokerUsesDst        = true;  // Broker shifts its clock for EU-style DST
// V3: all trading-session / hour-of-day restrictions have been REMOVED. The EA
// trades 24/5 whenever a valid strategy setup exists; time of day never blocks
// a trade. (Timezone settings above only convert LOGGED timestamps to Nairobi.)

input group "Trade Journal"
input bool   InpEnableTradeLog       = true;                          // Write a per-trade CSV log
input string InpTradeLogFileName     = "LUCC_LDCC_TradeLog.csv";      // Per-trade CSV file (MQL5/Files)
input string InpWeeklyStatsFileName  = "LUCC_LDCC_WeeklyStats.csv";   // Per-week summary CSV
input bool   InpFilesToCommonFolder  = true;  // Write CSVs to the shared Common\Files folder (ONE fixed,
                                               // easy-to-find location — strongly recommended for the
                                               // Strategy Tester, whose per-agent sandbox is hard to find).
                                               // The exact full path is printed to the Experts log.
input bool   InpEnableExcursionTracking = true;  // Keep watching price past the actual exit for true MFE/MAE
input int    InpExcursionTrackingHours  = 120;   // Hours from ENTRY to keep tracking (uncapped by SL/TP)
input bool            InpEnablePathLog   = true;                        // Per-trade bar-by-bar PATH log (enables
                                                                        // offline replay of trailing/BE/RR exits)
input string          InpPathLogFileName = "LUCC_LDCC_PathLog.csv";     // Path-log CSV file
input ENUM_TIMEFRAMES InpPathLogTimeframe = PERIOD_H1;                  // Granularity of the path log (H1 = entry
                                                                        // TF; set M15/M5 for a finer path)
input bool   InpLogMissedSetups   = true;  // Log every armed setup (LUCC/LDCC + CC) that NEVER produced an RC
                                           // entry, with a HYPOTHETICAL "enter at CC close, no retest" outcome.
                                           // This is the RC-filter opportunity-cost dataset: how many setups we
                                           // skipped by requiring the retest, and how far they would have run
                                           // (unconstrained MaxFavR, and stop-constrained TP/SL) had we entered.
input string InpMissedLogFileName = "LUCC_LDCC_MissedSetups.csv";      // Missed-setup (RC opportunity-cost) CSV
input bool   InpLogSkippedSetups  = true;  // V6: also capture setups that WERE ready to trade but got skipped by a
                                           // rule (bias gate, Daily confirmation, stop-after-win, per-episode dupe,
                                           // and Case-1 limits cancelled by the Daily-C1 break). Each is written to
                                           // the same missed-setup CSV with its skip reason + a hypothetical
                                           // "enter at CC close" forward outcome, so the opportunity cost of every
                                           // rule can be measured offline. (Uses InpMissedLogFileName.)

input group "1W Bias Filter"
input bool   InpUseBiasFilter        = true;  // Gate entries on the Weekly (1W) directional bias

// V5: the Daily confirmation filter is MANDATORY and hard-wired ON — it can no
// longer be switched off from the inputs. A BUY still needs >=1 Daily BUY pattern
// and a SELL needs >=1 Daily SELL pattern before entry; the Daily timeframe never
// sets the bias or generates entries. Kept as a compile-time constant so every
// existing reference keeps enforcing it and can never be bypassed in any run.
const bool   InpUseDailyConfirmation = true;

input group "Daily-Level Breakeven (V4 — OFF by default in V6)"
input bool   InpMoveToBEOnDailyBreak = false; // V6: OFF by default so the V6 management (BE @ +1.2R + partial @
                                               // +2R) is the single, unambiguous scheme — this V4 rule could
                                               // otherwise move the SL to BE before +1.2R and conflict with it.
                                               // Kept for A/B research: while a trade is open, if price trades
                                               // beyond Daily Candle-1 (BUY: above C1 High; SELL: below C1 Low)
                                               // move the SL to breakeven. (Whichever BE rule fires first wins.)

input group "Weekly-Bias Trade Rule (A/B toggle)"
input bool   InpStopAfterFirstWin    = true;  // ON  = after a WIN in the current weekly bias direction,
                                               //       skip all further setups in that direction until a
                                               //       NEW weekly bias (new weekly candle) begins.
                                               // OFF = unlimited trades per weekly bias.
                                               // Flip this to produce the two datasets to compare.
                                               // (Losses never stop the direction; only a win does.)

input group "Pending Retest Expiration"
input bool   InpExpirePendingDaily   = true;  // At the start of each new (Nairobi) day, discard any armed
                                               // but UN-triggered retest setup (CC formed, retest not yet
                                               // hit). The old setup is NOT reused — the EA waits for a
                                               // completely new valid setup. Open trades are unaffected.
                                               // (The 120-candle lookback & setup detection are unchanged.)

input group "Stale-Entry Filter (V6: 2R away-from-entry expiration)"
input bool   InpUseStaleEntryFilter  = true;  // V6: expire a NOT-YET-TRIGGERED entry if price first ran too far
                                               // AWAY (in the profit direction) from the planned RC entry level
                                               // before returning to retest it. Applies to the armed retest wait
                                               // AND to an unfilled Case-1 pending limit. Never touches open trades.
input double InpMaxAwayR              = 2.0;   // Max allowed away-move before the entry, in R (multiples of the
                                               // planned SL distance). If price travels more than this many R past
                                               // the planned entry before returning, the setup is stale: cancel any
                                               // pending limit, mark it Expired, and hunt a brand-new setup.
                                               // (The furthest away-move is always LOGGED per trade/setup even when
                                               //  the filter is off, so the opportunity cost is measurable.)

input group "Filters (isolation / debugging)"
// NOTE: the trading-session gate has been REMOVED in this version — every valid
// setup is taken regardless of session (data-collection mode). Session/UTC are
// still COMPUTED and LOGGED per trade for later analysis, just never used to
// block a trade or a reference candle.
input bool   InpUseBarCloseRetest    = true;  // Detect the retest on bar close too (range brackets the
                                               // level), not only tick-by-tick — REQUIRED for entries in
                                               // the tester's "Open prices"/"1 min OHLC" modes
input bool   InpDebugLog             = true;  // Print a detailed accept/reject trace to the Experts log

input group "Info Panel"
input bool   InpShowPanel            = true;         // Show the on-chart info panel
input int    InpPanelX               = 12;           // Panel left offset (px)
input int    InpPanelY               = 22;           // Panel top offset (px)
input int    InpPanelFontSize        = 9;            // Panel font size
input color  InpPanelBackColor       = C'18,18,22';  // Panel background color

//======================================================================
// Constants (indicator logic parameters — preserved exactly, not
// exposed as inputs, so optimization can never alter the signal rules)
//======================================================================
#define LOOKBACK 120   // rolling window: only the latest 120 closed candles are ever searched

//======================================================================
// V7/V9 — multi-engine constants (must precede all per-engine state below).
// Six fully independent engines, differing ONLY in the higher-timeframe
// hierarchy (bias TF -> confirmation TF); all share the 2H entry TF (V8):
//   Engine 0: 1W  -> 1D -> 2H
//   Engine 1: 2W  -> 2D -> 2H
//   Engine 2: 10D -> 2D -> 2H
//   Engine 3: 5D  -> 1D -> 2H
//   Engine 4: 5D  -> 2D -> 2H
//   Engine 5: 1W  -> 2D -> 2H
//======================================================================
#define ENG_1W1D    0          // kept for the info panel's default engine
#define NUM_ENGINES 6

// Bias-timeframe "kind" (how W* accessors resolve) and confirmation-timeframe
// "kind" (how D* accessors resolve) for each engine.
#define BK_W1   0
#define BK_2W   1
#define BK_5D   2
#define BK_10D  3
#define CK_D1   0
#define CK_2D   1

int    g_curEng = ENG_1W1D;   // engine whose higher-TF candles the accessors resolve to
int    g_engBias[NUM_ENGINES] = { BK_W1, BK_2W, BK_10D, BK_5D,  BK_5D, BK_W1 };
int    g_engConf[NUM_ENGINES] = { CK_D1, CK_2D, CK_2D,  CK_D1,  CK_2D, CK_2D };
string g_engName[NUM_ENGINES] = { "1W-1D","2W-2D","10D-2D","5D-1D","5D-2D","1W-2D" };
string EngineName(int e) { return (e >= 0 && e < NUM_ENGINES) ? g_engName[e] : "?"; }

//======================================================================
// V8 — ENTRY TIMEFRAME. All entry-signal detection (LUCC/LDCC, CC, RC),
// the new-bar trigger, pending-order / expiration logic, and every
// entry-candle count run on this timeframe. V8 raises it from H1 to H2.
// Nothing else (Weekly/2W bias, Daily/2D confirmation, trade management,
// targets, stops, partial/BE/lock, CSV structure, stats) changes.
// ENTRY_TF_SECS mirrors ENTRY_TF in seconds for entry-candle bar counts.
//======================================================================
#define ENTRY_TF       PERIOD_H2
#define ENTRY_TF_SECS  7200

//======================================================================
// Per-direction signal + trade-management state
// (one instance for SELL/LUCC, one for BUY/LDCC — fully independent,
// exactly as in the indicator and as required by the daily trade rules)
//======================================================================
struct SSignalState
{
   // --- detection state only (LUCC/LDCC/CC/RC) + per-side per-day counters ---
   datetime refTime;    // bar time of the active LUCC / LDCC candle (0 = none)
   double   refHigh;
   double   refLow;
   datetime ccTime;     // bar time of the Confirmation Candle (0 = none yet)
   datetime rcTime;      // RC that opened a trade for the CURRENT detection cycle (0 = none)
   datetime lastAttemptBar; // H1 bar time of the last entry ATTEMPT — throttles retries to 1/bar so a
                            // rejected touch neither spams nor permanently kills the setup
   double   slLevel;    // the indicator's "Stop Loss Level" for this cycle
   datetime expiredRefTime; // a reference whose armed retest was EXPIRED at a day boundary: it stays
                            // dormant (no CC/entry) until a genuinely NEW reference appears. 0 = none.
   bool     rcLevelTouched; // (missed-setup research) did price reach the retest level at least once while
                            // this CC was armed but before any entry? Distinguishes "RC filter blocked us"
                            // (touched, no entry) from "price never came back" (never touched). Reset when a
                            // new CC arms / the reference changes; set on any retest touch (tick or bar close).
   bool     skipLogged;     // V6: this armed setup already logged ONE opportunity-cost skip row (the first
                            // blocking rule it hit), so repeated rejected touches don't spam the log. Reset
                            // when a new CC arms / the reference changes.
   double   awayExtreme;    // V6: furthest price reached in the PROFIT direction since the CC formed (sell: the
                            // lowest low, buy: the highest high). With the RC level this gives how far price ran
                            // AWAY from the planned entry before the retest — the stale-entry (2R) measure.
                            // Initialised at the CC bar and updated every tick while armed.
   int      tradesToday;
   bool     doneToday;   // true once a trade in this direction has won today
};

// Per-engine signal state: [ENG_1W1D] = 1W->1D->1H, [ENG_2W2D] = 2W->2D->1H.
SSignalState g_sell[NUM_ENGINES];   // SELL side, driven by the Bullish LUCC (one per engine)
SSignalState g_buy[NUM_ENGINES];    // BUY side,  driven by the Bearish LDCC (one per engine)

//======================================================================
// One record per CURRENTLY-OPEN trade. MULTIPLE may be open at once — even
// in the same direction — as long as they originate from DIFFERENT weekly-
// bias episodes (different weekly candles). This is exactly what lets a
// Week-2 buy bias open a new buy trade while a Week-1 buy trade is still
// running: each weekly bias is an independent instance with its own trade.
// All origin/market fields are frozen at entry; mfe/maePrice track live.
//======================================================================
struct SOpenTrade
{
   int      engine;         // V7: which engine owns this trade (ENG_1W1D / ENG_2W2D)
   bool     isSell;
   long     positionId;
   datetime episode;        // weekly-bias candle time this trade belongs to (bias identity)
   datetime refTime; double refHigh; double refLow;
   datetime ccTime;  datetime rcTime;
   datetime entryTime; double entryPrice; double slPrice; double tpPrice;
   double   structuralSl; double requestedEntry;
   double   riskAmount; double lots; int tradeSeqToday;
   double   balanceBeforeEntry; double equityBefore;
   double   bidAtEntry; double askAtEntry; double spreadPoints; double atrH1AtEntry;
   string   biasDir; string biasBuyText; string biasSellText; string sideBiasText;
   datetime biasCandleTime;
   double   weekO, weekH, weekL, weekC;
   double   dayO, dayH, dayL, dayC;
   double   mfePrice; double maePrice;   // in-trade excursion, updated live each tick
   // --- V4 breakeven management ---
   double   initRiskDist;   // |entryPrice - initial SL| frozen at entry — the "1R" the BE trigger is measured in
   bool     beArmed;        // true once the SL has been moved to breakeven
   double   beLevelPrice;   // the price the SL was moved to (entry, or entry +/- the optional lock)
   datetime beArmTime;      // V6: server time the SL was first moved to breakeven (0 = never)
   // --- V4 target-% profit lock (stage above breakeven) ---
   bool     tgtLockArmed;   // true once the SL has been moved to the target-% profit lock
   double   tgtLockPrice;   // the price the SL was parked at (InpTargetLockSLPct of the target, in profit)
   // --- V6 entry-type / limit-wait research fields ---
   string   entryType;      // "MARKET" or "LIMIT" (Case-1 pending BUY/SELL LIMIT)
   string   targetSource;   // WeeklyC1 / DailyC1 / cap / limit / min10SL ... (the target/entry regime)
   datetime limitPlacedTime;// server time a Case-1 limit was placed (0 for a market entry)
   double   plannedRR;      // RR planned at entry = |tp-entry| / |entry-sl|
   string   dailyBuyText;   // Daily buy patterns present at entry ("-" if none)
   string   dailySellText;  // Daily sell patterns present at entry
   string   dailySideText;  // the Daily patterns on THIS trade's side (the confirmation set)
   // --- V6 partial-close (take 50% off at +2R) ---
   bool     partialDone;    // true once the partial has been taken
   datetime partialTime;    // server time of the partial close (0 = none)
   double   partialPrice;   // fill price of the partial close
   double   partialLots;    // volume closed at the partial
   double   partialProfit;  // realized money of the partial (profit+comm+swap accumulated at HandleClose)
   double   partialComm; double partialSwap;
   // --- V6 lifecycle timing / drawdown research fields ---
   double   maxDDMoney;     // running worst floating loss in money (>=0)
   long     secsInProfit;   // accumulated seconds the trade spent in floating profit
   long     secsInDraw;     // accumulated seconds the trade spent in floating drawdown
   datetime lastTickTime;   // previous tick's server time, for the profit/DD time accumulation
   datetime firstFavRTime;  // first time the trade reached +1R (0 = never)
   datetime tpHitTime;      // first time price touched the TP level (0 = never) — "time to TP"
   double   maxAwayBeforeEntry; // V6: furthest price moved AWAY (profit direction) from the planned RC entry
                                // level before this entry filled, in PRICE. Combines the armed-wait excursion
                                // and (for a Case-1 limit) the post-placement excursion. Logged in R and pips.
};
SOpenTrade g_openTrades[];

//======================================================================
// V5 — Case-1 pending LIMIT entries. When the RR to the fixed target is
// below InpMinTargetRR the EA does NOT enter at market; it places a
// BUY/SELL LIMIT at an improved price (so RR = InpMinTargetRR) and waits.
// The full entry snapshot is frozen here at PLACEMENT; when the limit
// fills (OnTradeTransaction, DEAL_ENTRY_IN) the snapshot is finalised into
// g_openTrades. Unfilled limits are cancelled at the next Nairobi day.
//======================================================================
struct SPendingEntry
{
   SOpenTrade snap;         // frozen entry snapshot (posId/entryPrice/entryTime set at fill)
   long       orderTicket;  // the pending BUY/SELL LIMIT ticket (matches the fill deal's DEAL_ORDER)
   datetime   placedTime;   // server time the limit was placed (for the log)
   double     awayExtreme;  // V6: furthest price (profit direction) reached since placement — for the 2R
                            // stale-limit expiration and the away-before-entry measurement. Init = limit price.
};
SPendingEntry g_pendingEntries[];

// Weekly-bias episodes (per side) in which a WIN has already been booked.
// Enforces "only one winning trade per weekly-bias instance"; because an
// episode IS a weekly candle, each new week is automatically a fresh,
// independent instance and the restriction resets with no lingering state.
// V7: win episodes are engine-tagged so each engine's "one win per weekly-bias
// episode" rule is fully independent (a win in one engine never blocks the other).
struct SWinEpisode { int engine; bool isSell; datetime episode; };
SWinEpisode g_winEpisodes[];

// All open-trade / pending / win queries are engine-scoped: engine 1 (1W->1D)
// and engine 2 (2W->2D) are counted separately so neither ever blocks the other.
bool HasOpenTradeForEpisode(int eng, bool isSell, datetime episode)
{
   for(int i = 0; i < ArraySize(g_openTrades); i++)
      if(g_openTrades[i].engine == eng && g_openTrades[i].isSell == isSell && g_openTrades[i].episode == episode)
         return true;
   return false;
}
// V5: a Case-1 limit is not yet in g_openTrades, so also check the pending
// limits when enforcing "one trade per weekly-bias episode per side".
bool HasPendingLimitForEpisode(int eng, bool isSell, datetime episode)
{
   for(int i = 0; i < ArraySize(g_pendingEntries); i++)
      if(g_pendingEntries[i].snap.engine == eng && g_pendingEntries[i].snap.isSell == isSell
         && g_pendingEntries[i].snap.episode == episode)
         return true;
   return false;
}
bool HasOpenTrade(int eng, bool isSell)
{
   for(int i = 0; i < ArraySize(g_openTrades); i++)
      if(g_openTrades[i].engine == eng && g_openTrades[i].isSell == isSell)
         return true;
   return false;
}
int OpenTradeCount(int eng, bool isSell)
{
   int c = 0;
   for(int i = 0; i < ArraySize(g_openTrades); i++)
      if(g_openTrades[i].engine == eng && g_openTrades[i].isSell == isSell)
         c++;
   return c;
}
bool HasWinEpisode(int eng, bool isSell, datetime episode)
{
   if(episode == 0)
      return false;
   for(int i = 0; i < ArraySize(g_winEpisodes); i++)
      if(g_winEpisodes[i].engine == eng && g_winEpisodes[i].isSell == isSell && g_winEpisodes[i].episode == episode)
         return true;
   return false;
}
void AddWinEpisode(int eng, bool isSell, datetime episode)
{
   if(HasWinEpisode(eng, isSell, episode))
      return;
   int n = ArraySize(g_winEpisodes); ArrayResize(g_winEpisodes, n + 1);
   g_winEpisodes[n].engine = eng; g_winEpisodes[n].isSell = isSell; g_winEpisodes[n].episode = episode;
}

//======================================================================
// A trade that has already closed, still being watched so its MFE/MAE
// aren't capped by the actual SL/TP — see the "Trade Journal — excursion
// tracking" section below for why this exists.
//======================================================================
struct SPendingLog
{
   int      engine;         // V7: owning engine (ENG_1W1D / ENG_2W2D)
   bool     isSell;
   long     posId;
   datetime refTime;
   double   refHigh;
   double   refLow;
   datetime ccTime;
   datetime rcTime;
   datetime entryTime;
   double   entryPrice;
   double   slPrice;
   double   tpPrice;
   double   riskAmount;
   double   lots;
   int      tradeSeqToday;
   double   balanceBeforeEntry;
   datetime exitTime;
   double   exitPrice;
   string   exitReason;
   double   grossProfit;
   double   commission;
   double   swap;
   double   mfePriceAtClose; // frozen the instant the REAL position closed — the only
   double   maePriceAtClose; // valid basis for "when to move to breakeven" questions
   double   mfePrice;        // continues updating past the actual exit, until trackUntil —
   double   maePrice;        // answers "how far could price have run", NOT "in-trade excursion"
   datetime trackUntil;

   // --- extended research snapshot (carried over from SSignalState at close) ---
   double   structuralSl;
   double   requestedEntry;
   double   bidAtEntry;
   double   askAtEntry;
   double   spreadPoints;
   double   atrH1AtEntry;
   string   biasDir;
   string   biasBuyText;
   string   biasSellText;
   string   sideBiasText;
   datetime biasCandleTime;
   double   equityBefore;
   double   weekO, weekH, weekL, weekC;
   double   dayO,  dayH,  dayL,  dayC;
   bool     firstWinOfBias;   // this trade was the FIRST winning trade of its weekly-bias episode
   // --- V4 breakeven management ---
   string   outcome;          // "TP" / "LOCK" / "BE" / "LOSS" — decided by exit PRICE, the source of truth for Result
   bool     beArmed;          // SL was moved to breakeven during the trade
   double   beLevelPrice;     // where the breakeven SL sat
   double   initRiskDist;     // |entry - initial SL| (used to classify the exit robustly)
   bool     tgtLockArmed;     // SL was moved to the target-% profit lock during the trade
   double   tgtLockPrice;     // where the target-% profit-lock SL sat
   // --- V6 research snapshot (carried from SOpenTrade at close) ---
   string   entryType;        // MARKET / LIMIT
   string   targetSource;     // WeeklyC1 / DailyC1 / cap / limit / min10SL ...
   datetime limitPlacedTime;  // when a Case-1 limit was placed (0 = market)
   double   plannedRR;        // RR planned at entry
   string   dailyBuyText;     // Daily buy patterns present at entry
   string   dailySellText;    // Daily sell patterns present at entry
   string   dailySideText;    // Daily patterns on this trade's side (confirmation set)
   datetime beArmTime;        // when the SL was first moved to BE (0 = never)
   bool     partialDone;      // a partial close was taken
   datetime partialTime;      // time of the partial close
   double   partialPrice;     // fill price of the partial close
   double   partialLots;      // volume closed at the partial
   double   partialProfit;    // realized money of the partial leg (already folded into grossProfit)
   double   maxDDMoney;       // worst floating loss (money) while open
   long     secsInProfit;     // seconds spent in floating profit
   long     secsInDraw;       // seconds spent in floating drawdown
   datetime firstFavRTime;    // first time the trade reached +1R (0 = never)
   datetime tpHitTime;        // first time price touched the TP level (0 = never)
   double   maxAwayBeforeEntry; // furthest away-move (profit dir) from the planned entry before fill, in price
};

SPendingLog g_pending[];

//======================================================================
// MISSED SETUP — one record per armed setup (LUCC/LDCC reference + a
// closed Confirmation Candle) that NEVER produced a Retest-Candle entry,
// so no real trade was ever taken. Captured the instant the setup is
// abandoned (reference changed / lost, day-boundary expiration, or the
// run ended while still armed). Each carries a HYPOTHETICAL "enter at the
// CC close, ignore the retest requirement" trade so we can measure the
// RC filter's opportunity cost: how far the setup would have run
// unconstrained (MaxFavR -> 1R/2R/3R/4R buckets) and whether it would
// have hit TP or SL first under the same padded stop / fixed-RR target.
// Finalized (its future H1 path scanned) once the tracking window from
// the CC has fully elapsed, mirroring the SPendingLog excursion mechanism.
//======================================================================
struct SMissedSetup
{
   bool     isSell;
   datetime refTime; double refHigh; double refLow;
   datetime ccTime;
   double   slLevel;        // structural SL level frozen at the CC (same span the real trade would use)
   double   hypoEntry;      // CC close — the hypothetical "no-retest" entry price
   double   hypoSL;         // padded SL: hypoEntry +/- |hypoEntry - slLevel| * InpStopLossMultiplier
   double   hypoTP;         // fixed-RR TP measured from the padded stop
   double   initRiskDist;   // final padded risk distance = |hypoEntry - hypoSL| (the "1R" for the buckets)
   string   reason;         // why it never entered: "RefChanged" / "RefLost" / "DayExpired" / "RunEnded"
   int      engine;         // V7: owning engine (ENG_1W1D / ENG_2W2D)
   bool     rcLevelTouched; // did price reach the retest level at all while armed (but no entry followed)?
   bool     biasAllowed;    // was the Weekly bias supporting this side at discard? (real entries need this)
   bool     dailyConfirm;   // did the Daily confirmation agree with this side at discard?
   string   biasDir; string sideBiasText;
   string   dailySideText;  // V6: the Daily patterns present on this side at discard ("-" if none)
   datetime biasCandleTime;
   datetime discardTime;    // server time the setup was abandoned
   datetime trackUntil;     // ccTime + InpExcursionTrackingHours*3600 — when its path is complete
};
SMissedSetup g_missed[];

CTrade   g_trade;
datetime g_lastBarTime  = 0;
datetime g_lastResetDay = 0;
double   g_prevMid      = 0.0;   // previous tick's mid price, for level-crossing detection
bool     g_havePrevMid  = false;
int      g_logHandle    = INVALID_HANDLE;
int      g_logCols      = 0;                // column count from the header — row-width sanity guard
int      g_pathHandle   = INVALID_HANDLE;   // per-trade bar-by-bar path log
datetime g_lastPathBar  = 0;                // last path-TF bar already logged
int      g_missedHandle = INVALID_HANDLE;   // missed-setup (RC opportunity-cost) log
int      g_atrHandle    = INVALID_HANDLE;   // H1 ATR(14) — logged as volatility context at entry
double   g_riskBalance  = 0.0;   // frozen once in OnInit; every trade's risk% is % of THIS, not of
                                  // the live/current balance, so wins/losses never change position size

//======================================================================
// Diagnostic counters — a running tally of how far each side gets through
// the funnel, printed at shutdown so "no trades" always has an explanation
// (e.g. "500 refs, 60 CCs, 40 retest touches, 40 blocked by bias").
//======================================================================
long g_cntRef        = 0;   // reference candles selected (LUCC + LDCC)
long g_cntCc         = 0;   // confirmation candles formed
long g_cntTouch      = 0;   // retest touches seen (tick or bar-close)
long g_cntEntries    = 0;   // orders actually sent OK
long g_rejPosOpen    = 0;
long g_rejDoneToday  = 0;
long g_rejMaxTrades  = 0;
long g_rejBias       = 0;
long g_rejDailyConf  = 0;   // entries rejected: no Daily pattern confirming the direction
long g_rejSlInvalid  = 0;
long g_rejMinStop    = 0;
long g_rejLots       = 0;
long g_rejOrderFail  = 0;
long g_skippedAfterWin = 0;   // setups skipped by the stop-after-first-win-per-weekly-bias rule
long g_expiredPending  = 0;   // armed retest setups discarded at a day boundary (pending-expiration rule)
long g_beDailyMoved    = 0;   // trades whose SL was moved to BE by the Daily-C1 break rule
long g_missedCaptured  = 0;   // armed setups (CC formed) that never produced an RC entry (opportunity-cost log)
long g_missedWouldWin  = 0;   // of those, how many the hypothetical "enter at CC close" trade would have WON
long g_cntLimitsPlaced = 0;   // V5: Case-1 pending BUY/SELL LIMIT entries placed
long g_cntLimitsFilled = 0;   // V5: of those, how many actually filled and became trades
long g_cntLimitsExpired = 0;  // V5: unfilled limits cancelled at the next Nairobi day

double g_brokerStdOffsetHours   = 2.0;   // broker's resolved STANDARD (winter) UTC offset (hours)
bool   g_brokerOffsetResolved   = false; // set once TimeCurrent/TimeGMT are valid (or manual mode)


// Detailed accept/reject trace to the Experts log, gated by InpDebugLog.
void Dbg(const string msg)
{
   if(InpDebugLog)
      Print("[DBG ", TimeToString(GetNairobiTime(TimeCurrent()), TIME_DATE | TIME_MINUTES | TIME_SECONDS), "] ", msg);
}

// FileOpen flags for the CSVs — adds FILE_COMMON when writing to the shared
// Common\Files folder (a single fixed location, easy to find after a test).
int FileFlagsCsv()
{
   int f = FILE_WRITE | FILE_CSV | FILE_ANSI;
   if(InpFilesToCommonFolder)
      f |= FILE_COMMON;
   return f;
}

// The absolute on-disk path a given output file will land at, so it can be
// printed to the Experts log (the reliable way to find tester output).
string FullFilePath(const string name)
{
   if(InpFilesToCommonFolder)
      return TerminalInfoString(TERMINAL_COMMONDATA_PATH) + "\\Files\\" + name;
   return TerminalInfoString(TERMINAL_DATA_PATH) + "\\MQL5\\Files\\" + name;
}

//======================================================================
// Candle helpers — off is the "just-closed bar" offset described above
//======================================================================
double BarOpen(int off)  { return iOpen(_Symbol, ENTRY_TF, off + 1); }
double BarClose(int off) { return iClose(_Symbol, ENTRY_TF, off + 1); }
double BarHigh(int off)  { return iHigh(_Symbol, ENTRY_TF, off + 1); }
double BarLow(int off)   { return iLow(_Symbol, ENTRY_TF, off + 1); }
datetime BarTime(int off){ return iTime(_Symbol, ENTRY_TF, off + 1); }

bool   IsBullish(int off) { return BarClose(off) > BarOpen(off); }
bool   IsBearish(int off) { return BarClose(off) < BarOpen(off); }
double BodyHigh(int off)  { return MathMax(BarOpen(off), BarClose(off)); }
double BodyLow(int off)   { return MathMin(BarOpen(off), BarClose(off)); }

//+------------------------------------------------------------------+
//| Largest safe lookback offset given the amount of history we have.|
//| Mirrors Pine's `maxBack = math.min(LOOKBACK - 1, bar_index)`,    |
//| additionally making sure the breakout check's high[i+1]/low[i+1] |
//| lookup at i = maxBack always has a valid bar behind it.          |
//+------------------------------------------------------------------+
int GetMaxBack()
{
   int totalBars = iBars(_Symbol, ENTRY_TF);
   int maxShift   = totalBars - 1;      // highest valid shift index
   int cap        = maxShift - 2;       // leave room for the i+1 breakout reference
   int maxBack    = MathMin(LOOKBACK - 1, cap);
   return maxBack;                      // negative => not enough history yet
}

//+------------------------------------------------------------------+
//| Search the most recent qualifying LUCC (isSell=true) or LDCC     |
//| (isSell=false) candidate in the last LOOKBACK closed candles.    |
//| Exact mirror of the indicator's scan: qualification (bullish/    |
//| bearish + breakout), PROTECTED filter, then the shared NOT        |
//| CONTAINED range-containment filter. (The session gate that used   |
//| to skip off-hours candidates has been removed — every valid setup |
//| is now eligible regardless of session.) Returns -1 if none found. |
//+------------------------------------------------------------------+
int FindReferenceOffset(bool isSell)
{
   int maxBack = GetMaxBack();
   if(maxBack < 0)
      return -1;

   for(int i = 0; i <= maxBack; i++)
   {
      bool qualifies = isSell
         ? (IsBullish(i) && BarClose(i) > BarHigh(i + 1))
         : (IsBearish(i) && BarClose(i) < BarLow(i + 1));
      if(!qualifies)
         continue;

      bool valid = true;

      // PROTECTED — no more-recent candle may have broken past this one
      if(i > 0)
      {
         for(int k = 0; k < i && valid; k++)
         {
            if(isSell) { if(BodyHigh(k) > BarHigh(i)) valid = false; }
            else       { if(BodyLow(k)  < BarLow(i))  valid = false; }
         }
      }

      // NOT CONTAINED — identical for both sides, exactly as in the indicator
      if(valid && i < maxBack)
      {
         for(int m = i + 1; m <= maxBack && valid; m++)
         {
            if(BarHigh(i) <= BarHigh(m) && BarLow(i) >= BarLow(m))
               valid = false;
         }
      }

      if(valid)
         return i;
   }
   return -1;
}

//+------------------------------------------------------------------+
//| Runs the closed-bar part of the state machine for one direction: |
//| (re)selection/invalidation of the reference candle, then the     |
//| Confirmation Candle check. The Retest Candle is deliberately NOT |
//| handled here — see MonitorRetest(), which watches for it tick by |
//| tick once ccTime is set below.                                   |
//+------------------------------------------------------------------+
void UpdateDirection(bool isSell, SSignalState &st)
{
   int foundOffset = FindReferenceOffset(isSell);
   datetime newRefTime = (foundOffset == -1) ? 0 : BarTime(foundOffset);
   double   newRefHigh  = (foundOffset == -1) ? 0 : BarHigh(foundOffset);
   double   newRefLow   = (foundOffset == -1) ? 0 : BarLow(foundOffset);

   // (Re)selection / invalidation — new/changed reference candle resets
   // the confirmation & retest state for this direction only.
   if(newRefTime != st.refTime)
   {
      // The old setup is being abandoned. If it had armed (CC formed) but never
      // produced an RC entry, log it as a missed setup BEFORE the state is wiped
      // (RC opportunity-cost dataset). A na/changed reference are distinct reasons.
      if(st.refTime != 0 && st.ccTime != 0 && st.rcTime == 0)
         CaptureMissedSetup(isSell, st, (newRefTime == 0) ? "RefLost" : "RefChanged");

      st.refTime = newRefTime;
      st.refHigh = newRefHigh;
      st.refLow  = newRefLow;
      st.ccTime  = 0;
      st.rcTime  = 0;
      st.slLevel = 0;
      st.lastAttemptBar = 0;
      st.rcLevelTouched = false;
      st.skipLogged     = false;
      // A genuinely NEW (non-zero) reference clears any pending-expiration lock,
      // so the fresh setup can arm normally. A reference that becomes na (0) or
      // that returns to the previously expired one keeps the lock in place.
      if(st.refTime != 0 && st.refTime != st.expiredRefTime)
         st.expiredRefTime = 0;
      if(st.refTime != 0)
      {
         g_cntRef++;
         Dbg(StringFormat("%s reference selected @ %s  high=%.5f low=%.5f",
                          isSell ? "LUCC(SELL)" : "LDCC(BUY)",
                          TimeToString(GetNairobiTime(st.refTime), TIME_DATE | TIME_MINUTES), st.refHigh, st.refLow));
      }
   }

   // Confirmation Candle — never re-arms a reference whose pending retest was
   // expired at a day boundary (it stays dormant until a new reference forms).
   if(st.refTime != 0 && st.ccTime == 0 && st.refTime != st.expiredRefTime)
   {
      bool ccTriggered = isSell ? (BodyLow(0) < st.refLow) : (BodyHigh(0) > st.refHigh);
      if(ccTriggered)
      {
         st.ccTime = BarTime(0);
         st.rcLevelTouched = false;   // fresh arm — no retest touch has happened yet for this CC
         st.skipLogged     = false;   // fresh arm — allow one opportunity-cost skip capture
         // V6 stale-entry: seed the profit-direction "away" extreme with the CC
         // bar's own extreme (sell: its low, buy: its high); ticks extend it while armed.
         st.awayExtreme    = isSell ? BarLow(0) : BarHigh(0);

         // Stop Loss Level — highest high (sell) / lowest low (buy) from the
         // reference candle through the CC, inclusive. Same span the
         // indicator draws its orange dashed line across.
         int refShift    = iBarShift(_Symbol, ENTRY_TF, st.refTime, true);
         int refOffsetNow = refShift - 1;
         double extreme = isSell ? BarHigh(0) : BarLow(0);
         for(int j = 0; j <= refOffsetNow; j++)
            extreme = isSell ? MathMax(extreme, BarHigh(j)) : MathMin(extreme, BarLow(j));
         st.slLevel = extreme;

         g_cntCc++;
         Dbg(StringFormat("%s CC formed @ %s  SL level=%.5f (now awaiting retest of %.5f)",
                          isSell ? "SELL" : "BUY", TimeToString(GetNairobiTime(st.ccTime), TIME_DATE | TIME_MINUTES),
                          st.slLevel, isSell ? st.refLow : st.refHigh));
      }
   }

   // Closed-bar RETEST fallback (indicator-faithful): the first bar AFTER the
   // CC whose range brackets the level is a retest. This is what lets entries
   // fire in the tester's "Open prices"/"1 min OHLC" modes, where the tick
   // path in MonitorRetest never samples the intrabar touch. The tick path
   // still runs for live/every-tick precision; whichever sees the touch first
   // wins, and positionOpen/rcTime keep them from double-firing.
   // V6 stale-entry: fold each just-closed bar's profit-direction extreme into the
   // away tracker too, so the measure stays correct in the tester's Open-prices /
   // 1-min OHLC modes where the tick path barely samples the intrabar move.
   if(st.refTime != 0 && st.ccTime != 0 && st.rcTime == 0 && BarTime(0) > st.ccTime)
      st.awayExtreme = isSell ? MathMin(st.awayExtreme, BarLow(0)) : MathMax(st.awayExtreme, BarHigh(0));

   if(InpUseBarCloseRetest && st.refTime != 0 && st.ccTime != 0 && st.rcTime == 0
      && BarTime(0) > st.ccTime && st.lastAttemptBar != BarTime(0))
   {
      double level    = isSell ? st.refLow : st.refHigh;
      bool   brackets = (BarLow(0) <= level && BarHigh(0) >= level);
      if(brackets)
      {
         st.lastAttemptBar = BarTime(0);
         st.rcLevelTouched = true;   // the retest level WAS reached (for missed-setup analysis)
         g_cntTouch++;
         Dbg(StringFormat("%s RETEST touch (bar close) @ %s level %.5f",
                          isSell ? "SELL" : "BUY", TimeToString(GetNairobiTime(BarTime(0)), TIME_DATE | TIME_MINUTES), level));
         if(TryOpen(isSell, st))
            st.rcTime = BarTime(0);
      }
   }
}

//+------------------------------------------------------------------+
//| Tick-by-tick Retest Candle detection. Active only while a CC has |
//| closed (st.ccTime != 0) and no RC has fired yet for this cycle    |
//| (st.rcTime == 0) — i.e. exactly the "waiting for retest" state.   |
//| Since UpdateDirection() only sets/clears ccTime on closed bars,   |
//| this can never start before the CC bar has actually closed, and  |
//| a reference-candle invalidation on a later closed bar (ccTime     |
//| reset to 0) automatically cancels an in-progress wait.            |
//|                                                                    |
//| "Touch" = the level is reachable by the live market right now:    |
//| either it sits inside the current Bid/Ask spread, or price        |
//| jumped straight across it between two consecutive ticks (a        |
//| plain Bid/Ask-vs-level check alone would miss that second case    |
//| whenever ticks don't land exactly on the level, e.g. coarser      |
//| tick generation during backtests). The instant either is true,    |
//| the order is sent — same tick, no waiting for a candle close.     |
//+------------------------------------------------------------------+
void MonitorRetest(bool isSell, SSignalState &st, double bid, double ask, double mid)
{
   // Active only while a CC has closed and no trade has been taken for this
   // detection cycle yet (rcTime == 0). rcTime latches ONLY when an entry
   // actually opens (see below), so a touch that gets rejected does NOT
   // permanently kill the setup — a later, valid touch can still fire.
   // (No global "position open" guard: overlapping trades from different
   //  weekly-bias episodes are allowed; TryOpen enforces one-per-episode.)
   if(st.ccTime == 0 || st.rcTime != 0)
      return;

   // V6 stale-entry: extend the profit-direction "away" extreme every tick while
   // armed (sell profits as price falls -> track the low; buy -> track the high).
   st.awayExtreme = isSell ? MathMin(st.awayExtreme, bid) : MathMax(st.awayExtreme, ask);

   double level    = isSell ? st.refLow : st.refHigh;
   bool   straddle = (bid <= level && ask >= level);
   bool   crossed  = g_havePrevMid && ((g_prevMid - level) * (mid - level) < 0);
   if(!(straddle || crossed))
      return;

   // Throttle to one entry attempt per H1 bar per side, so a sustained
   // straddle doesn't spam TryOpen (and the Experts log) every tick.
   datetime curBar = iTime(_Symbol, ENTRY_TF, 0);
   st.rcLevelTouched = true;   // the retest level WAS reached (for missed-setup analysis)
   if(st.lastAttemptBar == curBar)
      return;
   st.lastAttemptBar = curBar;

   g_cntTouch++;
   Dbg(StringFormat("%s RETEST touch (tick) @ level %.5f", isSell ? "SELL" : "BUY", level));
   if(TryOpen(isSell, st))
      st.rcTime = curBar; // the currently-forming bar is the RC that opened the trade
}

//+------------------------------------------------------------------+
//| Tracks Maximum Favorable/Adverse Excursion for EVERY open trade   |
//| (there can be several at once, from different weekly-bias         |
//| episodes) — the best/worst price each reached before it closed.   |
//+------------------------------------------------------------------+
void UpdateOpenExcursions(double bid, double ask)
{
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   datetime now = TimeCurrent();

   for(int i = 0; i < ArraySize(g_openTrades); i++)
   {
      double favPx = 0.0, floatMove = 0.0; // floatMove = signed price move in our favor (profit>0, drawdown<0)
      if(g_openTrades[i].isSell)
      {
         g_openTrades[i].mfePrice = MathMin(g_openTrades[i].mfePrice, bid); // lower = favorable for a sell
         g_openTrades[i].maePrice = MathMax(g_openTrades[i].maePrice, ask); // higher = adverse for a sell
         favPx     = bid;
         floatMove = g_openTrades[i].entryPrice - bid;   // sell profits as bid falls
      }
      else
      {
         g_openTrades[i].mfePrice = MathMax(g_openTrades[i].mfePrice, ask);
         g_openTrades[i].maePrice = MathMin(g_openTrades[i].maePrice, bid);
         favPx     = ask;
         floatMove = ask - g_openTrades[i].entryPrice;   // buy profits as ask rises
      }

      // --- V6 lifecycle research: time in profit vs drawdown, max floating DD ---
      long dt = (g_openTrades[i].lastTickTime > 0) ? (long)(now - g_openTrades[i].lastTickTime) : 0;
      if(dt > 0 && dt < 24 * 3600)   // guard against gaps (weekends / history jumps)
      {
         if(floatMove > 0.0)      g_openTrades[i].secsInProfit += dt;
         else if(floatMove < 0.0) g_openTrades[i].secsInDraw   += dt;
      }
      g_openTrades[i].lastTickTime = now;

      if(floatMove < 0.0 && tickSize > 0.0)
      {
         double ddMoney = (-floatMove) / tickSize * tickValue * g_openTrades[i].lots;
         g_openTrades[i].maxDDMoney = MathMax(g_openTrades[i].maxDDMoney, ddMoney);
      }

      double risk = (g_openTrades[i].initRiskDist > 0.0) ? g_openTrades[i].initRiskDist : MathAbs(g_openTrades[i].entryPrice - g_openTrades[i].slPrice);
      if(g_openTrades[i].firstFavRTime == 0 && risk > 0.0 && floatMove >= risk)
         g_openTrades[i].firstFavRTime = now;            // first time the trade reached +1R
      if(g_openTrades[i].tpHitTime == 0)
      {
         bool tpTouched = g_openTrades[i].isSell ? (favPx <= g_openTrades[i].tpPrice)
                                                 : (favPx >= g_openTrades[i].tpPrice);
         if(tpTouched) g_openTrades[i].tpHitTime = now;  // first time price touched the TP level
      }
   }
}

//+------------------------------------------------------------------+
//| V4 — Breakeven stop management. For every open trade that has NOT |
//| yet been moved to breakeven, arm it the instant floating profit    |
//| reaches InpBreakevenTriggerR (in R = multiples of that trade's own |
//| entry->initial-SL distance, so it scales per-setup and is never a  |
//| fixed pip value). The SL is moved to the entry price, or to        |
//| entry +/- InpBreakevenLockR of locked profit. TP is left untouched.|
//| The favorable price is read with the SAME side convention used for |
//| MFE (sell measured on Bid, buy on Ask) so the R-trigger matches the |
//| logged MFE_R exactly.                                              |
//+------------------------------------------------------------------+
void UpdateBreakeven(double bid, double ask)
{
   if(!InpUseBreakeven || InpBreakevenTriggerR <= 0.0)
      return;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = 0; i < ArraySize(g_openTrades); i++)
   {
      if(g_openTrades[i].beArmed || g_openTrades[i].tgtLockArmed || g_openTrades[i].initRiskDist <= 0.0)
         continue; // already at BE, or already advanced to the target-% lock (never loosen it)

      double trigDist = InpBreakevenTriggerR * g_openTrades[i].initRiskDist;
      double lockDist = InpBreakevenLockR    * g_openTrades[i].initRiskDist;

      bool   reached;
      double newSl;
      double stopSidePrice;   // the price that would trigger the SL, for the min-distance check
      if(g_openTrades[i].isSell)
      {
         reached       = (bid <= g_openTrades[i].entryPrice - trigDist); // sell profits as Bid falls
         newSl         = g_openTrades[i].entryPrice - lockDist;          // lock>0 parks SL below entry (in profit)
         stopSidePrice = ask;                                            // a sell's SL is hit on the Ask
      }
      else
      {
         reached       = (ask >= g_openTrades[i].entryPrice + trigDist); // buy profits as Ask rises
         newSl         = g_openTrades[i].entryPrice + lockDist;          // lock>0 parks SL above entry (in profit)
         stopSidePrice = bid;                                            // a buy's SL is hit on the Bid
      }
      if(!reached)
         continue;

      newSl = NormalizeDouble(newSl, digits);

      // Respect the broker's minimum stop distance; if the fresh SL would sit
      // inside it (only possible with a large lock), wait — we'll retry on a
      // later tick once price has advanced further from the level.
      if(minDist > 0 && MathAbs(stopSidePrice - newSl) < minDist)
         continue;

      double curTp = g_openTrades[i].tpPrice;
      if(g_trade.PositionModify((ulong)g_openTrades[i].positionId, newSl, curTp))
      {
         g_openTrades[i].beArmed      = true;
         g_openTrades[i].beLevelPrice = newSl;
         if(g_openTrades[i].beArmTime == 0)
            g_openTrades[i].beArmTime = TimeCurrent();   // V6: time to BE (research)
         Dbg(StringFormat("%s BREAKEVEN armed: posId=%d SL->%.5f (%.2fR trigger, %.2fR lock) entry=%.5f",
                          g_openTrades[i].isSell ? "SELL" : "BUY", g_openTrades[i].positionId, newSl,
                          InpBreakevenTriggerR, InpBreakevenLockR, g_openTrades[i].entryPrice));
      }
      else
      {
         Dbg(StringFormat("%s BREAKEVEN modify FAILED posId=%d retcode=%d (%s) — will retry",
                          g_openTrades[i].isSell ? "SELL" : "BUY", g_openTrades[i].positionId,
                          g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      }
   }
}

//+------------------------------------------------------------------+
//| V6 — Partial profit. The instant floating profit reaches           |
//| InpPartialCloseR (default +2R, measured on the trade's own risk    |
//| distance, MFE side convention) close InpPartialClosePct of the     |
//| ORIGINAL volume and let the remainder run to the final target. By  |
//| then BE (armed at +1.2R) already protects the runner, so the       |
//| remaining leg can only exit at BE or TP. Booked once per trade.    |
//| The realized partial P&L is captured in HandleClose (the partial   |
//| out-deal) and folded into the trade's total for the journal.       |
//+------------------------------------------------------------------+
void UpdatePartialClose(double bid, double ask)
{
   if(!InpUsePartialClose || InpPartialCloseR <= 0.0 || InpPartialClosePct <= 0.0)
      return;

   double volStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double volMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(volStep <= 0.0) volStep = 0.01;

   for(int i = 0; i < ArraySize(g_openTrades); i++)
   {
      if(g_openTrades[i].partialDone || g_openTrades[i].initRiskDist <= 0.0)
         continue;

      double trigDist = InpPartialCloseR * g_openTrades[i].initRiskDist;
      bool   reached  = g_openTrades[i].isSell ? (bid <= g_openTrades[i].entryPrice - trigDist)
                                               : (ask >= g_openTrades[i].entryPrice + trigDist);
      if(!reached)
         continue;

      // Volume to close = pct of the ORIGINAL lots, snapped to the broker's step.
      double closeVol = g_openTrades[i].lots * InpPartialClosePct / 100.0;
      closeVol = MathFloor(closeVol / volStep) * volStep;
      double posVol = 0.0;
      if(PositionSelectByTicket((ulong)g_openTrades[i].positionId))
         posVol = PositionGetDouble(POSITION_VOLUME);
      // Never try to close more than is open, and leave at least one step running.
      if(posVol > 0.0)
         closeVol = MathMin(closeVol, posVol - volStep);

      if(closeVol < volMin || closeVol < volStep)
      {
         // Position too small to split meaningfully — skip the partial, let it run
         // whole to the target, but don't retry every tick.
         g_openTrades[i].partialDone = true;
         continue;
      }

      if(g_trade.PositionClosePartial((ulong)g_openTrades[i].positionId, closeVol))
      {
         g_openTrades[i].partialDone  = true;
         g_openTrades[i].partialTime  = TimeCurrent();
         g_openTrades[i].partialLots  = closeVol;
         g_openTrades[i].partialPrice = g_trade.ResultPrice();
         Dbg(StringFormat("%s PARTIAL CLOSE %.2f lots @ %.5f (+%.2fR) posId=%d — %.2f lots left to target",
                          g_openTrades[i].isSell ? "SELL" : "BUY", closeVol, g_openTrades[i].partialPrice,
                          InpPartialCloseR, g_openTrades[i].positionId, posVol - closeVol));
      }
      else
      {
         Dbg(StringFormat("%s PARTIAL CLOSE FAILED posId=%d vol=%.2f retcode=%d (%s) — will retry",
                          g_openTrades[i].isSell ? "SELL" : "BUY", g_openTrades[i].positionId, closeVol,
                          g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      }
   }
}

//+------------------------------------------------------------------+
//| Daily-level breakeven — while a trade is open, if price trades    |
//| beyond Daily Candle-1 (BUY: above Daily-C1 High; SELL: below      |
//| Daily-C1 Low — the same levels that invalidate new setups), move  |
//| the SL to breakeven (entry). Touch-based (incl. the live tick).   |
//| Reuses beArmed/beLevelPrice so a stop at this level is classified |
//| as BE, and so the R-based breakeven never double-moves it. TP is  |
//| left untouched. Independent of / additive to the R-based rule.    |
//+------------------------------------------------------------------+
void UpdateDailyBreakeven(double bid, double ask)
{
   if(!InpMoveToBEOnDailyBreak || iBars(_Symbol, PERIOD_D1) < 2)
      return;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   int    digits  = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   for(int i = 0; i < ArraySize(g_openTrades); i++)
   {
      if(g_openTrades[i].beArmed || g_openTrades[i].tgtLockArmed)
         continue; // already at BE, or already advanced to the target-% lock (never loosen it)

      // V7: the "Daily Candle-1" here is THIS trade's engine timeframe (1D or 2D).
      g_curEng = g_openTrades[i].engine;
      double dC1High = DHigh(1);
      double dC1Low  = DLow(1);
      double dHiNow  = MathMax(DHigh(0), ask); // running (2-)day high so far, incl. live tick
      double dLoNow  = MathMin(DLow(0),  bid); // running (2-)day low  so far, incl. live tick

      bool trigger = g_openTrades[i].isSell ? (dLoNow < dC1Low) : (dHiNow > dC1High);
      if(!trigger)
         continue;

      double newSl         = NormalizeDouble(g_openTrades[i].entryPrice, digits); // pure breakeven = entry
      double stopSidePrice = g_openTrades[i].isSell ? ask : bid;
      double need          = (minDist > 0) ? minDist : point;
      // Breakeven must sit on the valid side of price by at least the broker
      // min-stop (SL below Bid for a buy, above Ask for a sell). If the trade
      // isn't yet in enough profit for that, skip and retry on a later tick —
      // the Daily-C1 break stays latched (the running Daily high/low is
      // monotonic through the day), so it arms as soon as BE becomes valid.
      bool sideOk = g_openTrades[i].isSell ? (newSl - stopSidePrice >= need)
                                           : (stopSidePrice - newSl >= need);
      if(!sideOk)
         continue;

      double curTp = g_openTrades[i].tpPrice;
      if(g_trade.PositionModify((ulong)g_openTrades[i].positionId, newSl, curTp))
      {
         g_openTrades[i].beArmed      = true;
         g_openTrades[i].beLevelPrice = newSl;
         if(g_openTrades[i].beArmTime == 0)
            g_openTrades[i].beArmTime = TimeCurrent();   // V6: time to BE (research)
         g_beDailyMoved++;
         Dbg(StringFormat("%s DAILY-BE: price beyond Daily-C1 %s -> SL moved to BE %.5f posId=%d",
                          g_openTrades[i].isSell ? "SELL" : "BUY",
                          g_openTrades[i].isSell ? "Low" : "High", newSl, g_openTrades[i].positionId));
      }
      else
      {
         Dbg(StringFormat("%s DAILY-BE modify FAILED posId=%d retcode=%d (%s) — will retry",
                          g_openTrades[i].isSell ? "SELL" : "BUY", g_openTrades[i].positionId,
                          g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      }
   }
}

//+------------------------------------------------------------------+
//| V4 — Target-% profit lock. Once floating profit reaches           |
//| InpTargetLockTriggerPct of the TOTAL target distance (|TP-entry|),|
//| move the SL to InpTargetLockSLPct of that same target distance,   |
//| locking in profit. Because both levels are % of the CURRENT       |
//| target, the rule is identical in R terms for ANY RR: 82%/50% of a |
//| 3R target = arm 2.46R -> lock 1.50R; of a 4R target = 3.28R ->     |
//| 2.00R; of a 5R target = 4.10R -> 2.50R — no code change needed.    |
//| It is a stage ABOVE breakeven: it only ever moves the SL FURTHER  |
//| into profit, never loosens it. Favorable price uses the MFE        |
//| convention (sell measured on Bid, buy on Ask).                    |
//+------------------------------------------------------------------+
void UpdateTargetLock(double bid, double ask)
{
   if(!InpUseTargetLock || InpTargetLockTriggerPct <= 0.0)
      return;

   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minDist  = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double trigFrac = InpTargetLockTriggerPct / 100.0;
   double slFrac   = InpTargetLockSLPct      / 100.0;

   for(int i = 0; i < ArraySize(g_openTrades); i++)
   {
      if(g_openTrades[i].tgtLockArmed)
         continue;

      double targetDist = MathAbs(g_openTrades[i].tpPrice - g_openTrades[i].entryPrice);
      if(targetDist <= 0.0)
         continue;

      double trigDist = trigFrac * targetDist;   // how far in profit the trigger sits
      double lockDist = slFrac   * targetDist;   // how far in profit the new SL sits

      bool   reached;
      double newSl, stopSidePrice, curStop;
      if(g_openTrades[i].isSell)
      {
         reached       = (bid <= g_openTrades[i].entryPrice - trigDist);
         newSl         = g_openTrades[i].entryPrice - lockDist;
         stopSidePrice = ask;                                            // a sell's SL is hit on the Ask
         curStop       = g_openTrades[i].beArmed ? g_openTrades[i].beLevelPrice : g_openTrades[i].slPrice;
      }
      else
      {
         reached       = (ask >= g_openTrades[i].entryPrice + trigDist);
         newSl         = g_openTrades[i].entryPrice + lockDist;
         stopSidePrice = bid;                                            // a buy's SL is hit on the Bid
         curStop       = g_openTrades[i].beArmed ? g_openTrades[i].beLevelPrice : g_openTrades[i].slPrice;
      }
      if(!reached)
         continue;

      newSl = NormalizeDouble(newSl, digits);

      // Only ever tighten into profit: never loosen a stop already advanced by a
      // (pathologically large) breakeven lock. If it doesn't improve, do nothing
      // (leave the current SL in force) and re-check on later ticks.
      bool improves = g_openTrades[i].isSell ? (newSl < curStop - point * 0.5)
                                             : (newSl > curStop + point * 0.5);
      if(!improves)
         continue;

      // Respect the broker minimum stop distance; retry on a later tick if inside it.
      if(minDist > 0 && MathAbs(stopSidePrice - newSl) < minDist)
         continue;

      double curTp = g_openTrades[i].tpPrice;
      if(g_trade.PositionModify((ulong)g_openTrades[i].positionId, newSl, curTp))
      {
         g_openTrades[i].tgtLockArmed = true;
         g_openTrades[i].tgtLockPrice = newSl;
         Dbg(StringFormat("%s TARGET-LOCK armed: posId=%d SL->%.5f (%.0f%% target trigger -> %.0f%% target lock) entry=%.5f tp=%.5f",
                          g_openTrades[i].isSell ? "SELL" : "BUY", g_openTrades[i].positionId, newSl,
                          InpTargetLockTriggerPct, InpTargetLockSLPct, g_openTrades[i].entryPrice, g_openTrades[i].tpPrice));
      }
      else
      {
         Dbg(StringFormat("%s TARGET-LOCK modify FAILED posId=%d retcode=%d (%s) — will retry",
                          g_openTrades[i].isSell ? "SELL" : "BUY", g_openTrades[i].positionId,
                          g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      }
   }
}

//+------------------------------------------------------------------+
//| V4 — Classify a just-closed trade by its EXIT PRICE (not net-profit|
//| sign): TP = reached take-profit (the only true WIN); LOCK = stopped|
//| at the target-% profit lock (a real profit, but not a full TP);    |
//| BE = stopped at breakeven (neither win nor loss); LOSS = hit the   |
//| original stop. Tolerance scales with the trade's risk so slippage  |
//| never mis-buckets a fill. LOCK is checked before BE because when    |
//| both armed the active stop is the (further-in-profit) lock.        |
//+------------------------------------------------------------------+
string ClassifyOutcome(const SOpenTrade &t, double exitPrice)
{
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double riskDist = (t.initRiskDist > 0.0) ? t.initRiskDist : MathAbs(t.entryPrice - t.slPrice);
   double tol      = MathMax(3.0 * point, riskDist * 0.15);

   if(MathAbs(exitPrice - t.tpPrice) <= tol)
      return "TP";
   if(t.tgtLockArmed && MathAbs(exitPrice - t.tgtLockPrice) <= tol)
      return "LOCK";
   if(t.beArmed && MathAbs(exitPrice - t.beLevelPrice) <= tol)
      return "BE";
   return "LOSS";
}

//+------------------------------------------------------------------+
//| Nairobi (EAT, UTC+3, no DST) TIMESTAMP handling — for LOG display |
//| only. There is no session/hour gate in V3; the EA trades 24/5.    |
//+------------------------------------------------------------------+

// Last Sunday of `month` in `year`, at 00:00 (used as the EU-style DST
// switch date; the exact switch is 01:00 UTC on that day).
datetime LastSundayOfMonth(int year, int month)
{
   int nextMonth = month + 1, nextYear = year;
   if(nextMonth > 12) { nextMonth = 1; nextYear++; }

   MqlDateTime dtNext;
   dtNext.year = nextYear; dtNext.mon = nextMonth; dtNext.day = 1;
   dtNext.hour = 0; dtNext.min = 0; dtNext.sec = 0;
   datetime firstOfNextMonth = StructToTime(dtNext);
   datetime lastDayOfMonth   = firstOfNextMonth - 86400;

   MqlDateTime dtLast;
   TimeToStruct(lastDayOfMonth, dtLast);
   return lastDayOfMonth - dtLast.day_of_week * 86400; // day_of_week: 0 = Sunday
}

// Is a given UTC instant inside the EU-style DST window (last Sunday of March
// 01:00 UTC to last Sunday of October 01:00 UTC)?
bool IsEuDstUtc(datetime utc)
{
   MqlDateTime dt;
   TimeToStruct(utc, dt);
   datetime dstStart = LastSundayOfMonth(dt.year, 3)  + 3600;
   datetime dstEnd   = LastSundayOfMonth(dt.year, 10) + 3600;
   return (utc >= dstStart && utc < dstEnd);
}

// Resolve the broker's STANDARD (winter) UTC offset ONCE. Auto mode derives it
// from TimeCurrent()-TimeGMT() (which auto-includes the broker's current DST),
// backing out the current DST to get the standard offset. Falls back to the
// manual input if auto-detect isn't available yet or is switched off.
void ResolveBrokerOffset()
{
   if(g_brokerOffsetResolved)
      return;
   if(!InpAutoDetectBrokerOffset)
   {
      g_brokerStdOffsetHours = InpBrokerGmtOffsetHours;
      g_brokerOffsetResolved = true;
      return;
   }
   datetime srv = TimeCurrent();
   datetime gmt = TimeGMT();
   if(srv <= 0 || gmt <= 0)
      return; // times not ready yet — retry on a later tick (manual value used meanwhile)
   double curOffH = MathRound((double)((long)srv - (long)gmt) / 3600.0);
   bool   dstNow  = InpBrokerUsesDst && IsEuDstUtc(gmt);
   g_brokerStdOffsetHours = curOffH - (dstNow ? 1.0 : 0.0);
   g_brokerOffsetResolved = true;
}

// Whether the broker is observing EU-style DST at serverTime, using the
// resolved standard offset to back out an approximate UTC.
bool IsBrokerDstActive(datetime serverTime)
{
   if(!InpBrokerUsesDst)
      return false;
   datetime approxUtc = (datetime)(serverTime - (long)(g_brokerStdOffsetHours * 3600));
   return IsEuDstUtc(approxUtc);
}

// Converts broker server time to true Nairobi time (EAT, fixed UTC+3, no DST),
// compensating for the broker's resolved GMT offset + DST. Every timestamp
// written to the logs goes through this so it matches Africa/Nairobi on
// TradingView regardless of the broker's server timezone.
datetime GetNairobiTime(datetime serverTime)
{
   double offsetHours = g_brokerStdOffsetHours;
   if(IsBrokerDstActive(serverTime))
      offsetHours += 1.0;

   datetime utcTime = (datetime)(serverTime - (long)(offsetHours * 3600));
   return utcTime + 3 * 3600; // Nairobi = UTC+3, year-round
}

// True UTC for a broker server time (same offset/DST compensation as the
// Nairobi conversion, minus the +3). Used to classify the FX session an
// entry fell in, independent of the broker's own clock.
datetime GetUtcTime(datetime serverTime)
{
   return GetNairobiTime(serverTime) - 3 * 3600;
}

// Coarse FX-session label from a UTC timestamp. Sessions overlap, so more
// than one can be active — they are '+'-joined (e.g. "London+NewYork"),
// which is exactly the high-value window to filter on later. "Off" = none.
string SessionNameUtc(datetime utc)
{
   MqlDateTime d;
   TimeToStruct(utc, d);
   int h = d.hour;
   bool tokyo  = (h >= 0  && h < 9);            // Tokyo      00:00-09:00 UTC
   bool london = (h >= 7  && h < 16);           // London     07:00-16:00 UTC
   bool ny     = (h >= 12 && h < 21);           // New York   12:00-21:00 UTC
   bool sydney = (h >= 21 || h < 6);            // Sydney     21:00-06:00 UTC
   string s = "";
   if(london) s += (StringLen(s) ? "+" : "") + "London";
   if(ny)     s += (StringLen(s) ? "+" : "") + "NewYork";
   if(tokyo)  s += (StringLen(s) ? "+" : "") + "Tokyo";
   if(sydney) s += (StringLen(s) ? "+" : "") + "Sydney";
   return (StringLen(s) == 0) ? "Off" : s;
}

// V3: the Nairobi trading-session window and IsWithinSession()/IsBarWithinSession()
// have been removed entirely. There is NO time-of-day gate anywhere — the EA is
// eligible to trade every hour, 24/5. (The FX-session LABEL for the log still
// comes from SessionNameUtc() above; it is analysis metadata, not a filter.)

// Pending-retest expiration: if a side has an ARMED but UN-triggered setup
// (CC formed, retest not yet hit, so no trade was taken), discard it at the
// day boundary. expiredRefTime is stamped so the SAME reference can't re-arm
// — the EA must wait for a genuinely new reference. Open trades and the
// 120-candle setup search are untouched.
void ExpirePendingIfArmed(bool isSell, SSignalState &st)
{
   if(!InpExpirePendingDaily)
      return;
   bool armedUntriggered = (st.refTime != 0 && st.ccTime != 0 && st.rcTime == 0);
   if(!armedUntriggered)
      return;
   // Log the abandoned setup for the RC opportunity-cost dataset before wiping it.
   CaptureMissedSetup(isSell, st, "DayExpired");
   st.expiredRefTime = st.refTime;
   st.ccTime         = 0;
   st.slLevel        = 0;
   st.lastAttemptBar = 0;
   st.rcLevelTouched = false;
   g_expiredPending++;
   Dbg(StringFormat("%s PENDING EXPIRED at new day: untriggered retest on ref @ %s discarded; awaiting a new setup",
                    isSell ? "SELL" : "BUY", TimeToString(GetNairobiTime(st.expiredRefTime), TIME_DATE | TIME_MINUTES)));
}

// Resets both directions' daily trade counters at the start of each new
// Nairobi calendar day (the whole session model is Nairobi-based, so the
// "trading day" boundary follows the same clock).
void CheckDailyReset()
{
   datetime nairobiNow = GetNairobiTime(TimeCurrent());
   MqlDateTime dt;
   TimeToStruct(nairobiNow, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime today = StructToTime(dt);

   if(today != g_lastResetDay)
   {
      // Once-a-day progress heartbeat (shared funnel counters) + each engine's bias.
      if(g_lastResetDay != 0)
      {
         Dbg(StringFormat("DAY %04d.%02d.%02d | funnel refs=%d CCs=%d touches=%d entries=%d",
                          dt.year, dt.mon, dt.day, g_cntRef, g_cntCc, g_cntTouch, g_cntEntries));
         for(int e = 0; e < NUM_ENGINES; e++)
            Dbg(StringFormat("   [%s] bias dir=%s buy=[%s]%s sell=[%s]%s", EngineName(e), g_bias[e].dir,
                             g_bias[e].buyText,  g_bias[e].buyInvalid  ? " INVALID" : "",
                             g_bias[e].sellText, g_bias[e].sellInvalid ? " INVALID" : ""));
      }

      // V7: expire each engine's armed-but-untriggered retest, and reset each
      // engine's per-side daily counters. Engines are reset independently.
      for(int e = 0; e < NUM_ENGINES; e++)
      {
         g_curEng = e;
         RebuildSyntheticFor(e);
         ExpirePendingIfArmed(true,  g_sell[e]);
         ExpirePendingIfArmed(false, g_buy[e]);
         g_sell[e].tradesToday = 0; g_sell[e].doneToday = false;
         g_buy[e].tradesToday  = 0; g_buy[e].doneToday  = false;
      }

      // V5/V7: cancel any unfilled Case-1 limits (both engines) at the new day.
      CancelPendingLimits();

      g_lastResetDay = today;
   }
}

//======================================================================
// 1W BIAS ENGINE  (direct, CRT-free port of the reference bias patterns,
// evaluated ONLY on the Weekly timeframe — the exact mirror of the
// indicator's Bias engine). Per the agreed design the Weekly shift maps
// 1:1 onto the reference's Pine offset, so each pattern reads exactly the
// candle it was written against:
//   * BC / DC / BSB / SBS   -> shifts 1 & 2 (LAST-CLOSED weekly candles),
//                              fixed the moment candle 1 closed.
//   * 3DP / 3DP-DS / N-3DP  -> include shift 0 (the LIVE forming weekly
//     / N-DS                   candle), so an intraweek sweep of the prior
//                              candle's high/low confirms them the same week,
//                              exactly as in the reference's live read.
//
// The bias only GATES whether a Retest-Candle entry is actionable — it
// never touches the LUCC/LDCC/CC/RC detection above.
//======================================================================
//======================================================================
// V7 — DUAL ENGINE INFRASTRUCTURE (constants defined near the top of the
// file, before any per-engine state uses them; see g_curEng / NUM_ENGINES).
// A single global "current engine" context (g_curEng) makes every higher-
// timeframe candle accessor (W*/D*) and every pattern function resolve to the
// right timeframe with no change to the pattern code itself. All trading STATE
// is per-engine (see g_bias[2]/g_sell[2]/g_buy[2], engine-tagged trade records,
// and the per-engine win-episode store); the two engines never share state.
//======================================================================

// Monday epoch for deterministic day/week bucketing (2000-01-03 = Monday).
#define EPOCH_MON  (datetime)946857600   // 2000.01.03 00:00:00 UTC

// N-WEEKDAY bucket id: non-overlapping consecutive blocks of N trading days
// (Mon-Fri), weekends never counted (Sat/Sun fold into the preceding Friday).
// `anchor` is the trading-day-index phase at which a block begins, measured
// from the Monday epoch (Mon=0,Tue=1,Wed=2,Thu=3,Fri=4). So:
//   N=2,  anchor=0 -> 2-Day  (Mon-Tue / Wed-Thu / Fri-Mon ...; realigns every 2 wks)
//   N=5,  anchor=3 -> 5-Day  (each block STARTS on Thursday: Thu-Fri-Mon-Tue-Wed)
//   N=10, anchor=3 -> 10-Day (two consecutive Thursday-anchored 5-Day blocks)
long BucketWeekday(datetime t, int N, int anchor)
{
   long calDays = (long)((long)(t - EPOCH_MON) / 86400);
   long weeks   = calDays / 7;
   long dow     = calDays - weeks * 7;          // 0 = Mon .. 6 = Sun (epoch is Monday)
   if(dow < 0) { dow += 7; weeks -= 1; }
   int  wd      = (dow <= 4) ? (int)dow : 4;    // clamp Sat/Sun into the Friday block
   long wdIndex = weeks * 5 + wd - anchor;      // shift so a block begins at `anchor`
   long q       = wdIndex / N;                  // floor division (handle negatives too)
   if(wdIndex < 0 && (wdIndex % N) != 0) q--;
   return q;
}
// N-WEEK bucket id: discrete, non-overlapping blocks of N calendar weeks
// (N=2 -> two consecutive weekly candles share a block).
long BucketWeek(datetime weekStart, int N)
{
   long weeks = (long)((long)(weekStart - EPOCH_MON) / (7 * 86400));
   if(weekStart < EPOCH_MON && ((long)(weekStart - EPOCH_MON) % (7 * 86400)) != 0) weeks -= 1;
   return weeks / N;
}

// Synthetic candle caches (index 0 = current/forming block). Four distinct
// higher-timeframe constructions are needed across the six engines:
//   2W  (from W1, 2 weeks)   -> bias for Engine 2
//   5D  (from D1, 5 weekdays)-> bias for Engines 4 & 5
//   10D (from D1,10 weekdays)-> bias for Engine 3
//   2D  (from D1, 2 weekdays)-> confirmation for Engines 2/3/5/6
#define SYN_MAX 20
double   g_c2wO[],  g_c2wH[],  g_c2wL[],  g_c2wC[];  datetime g_c2wT[];  int g_n2w  = 0;
double   g_c5dO[],  g_c5dH[],  g_c5dL[],  g_c5dC[];  datetime g_c5dT[];  int g_n5d  = 0;
double   g_c10dO[], g_c10dH[], g_c10dL[], g_c10dC[]; datetime g_c10dT[]; int g_n10d = 0;
double   g_c2dO[],  g_c2dH[],  g_c2dL[],  g_c2dC[];  datetime g_c2dT[];  int g_n2d  = 0;
datetime g_c2wBuilt = 0, g_c5dBuilt = 0, g_c10dBuilt = 0, g_c2dBuilt = 0;

// Aggregate native bars of `tf` into non-overlapping blocks (byWeek chooses the
// week-index vs weekday-index bucketing; groupN = block size) and store the
// newest SYN_MAX blocks, index 0 = the block containing the newest (forming)
// bar. O = open of the oldest bar in the block, C = close of the newest, H/L =
// extremes, T = oldest bar's time (block start).
void BuildSynthetic(ENUM_TIMEFRAMES tf, bool byWeek, int groupN, int anchor,
                    double &aO[], double &aH[], double &aL[], double &aC[], datetime &aT[], int &n)
{
   int bars = iBars(_Symbol, tf);
   int need = MathMin(bars, SYN_MAX * groupN + groupN + 4);
   ArrayResize(aO, SYN_MAX); ArrayResize(aH, SYN_MAX); ArrayResize(aL, SYN_MAX);
   ArrayResize(aC, SYN_MAX); ArrayResize(aT, SYN_MAX);
   n = 0;
   long curB = LONG_MIN; int idx = -1;
   for(int s = 0; s < need && idx < SYN_MAX - 1; s++)
   {
      datetime bt = iTime(_Symbol, tf, s);
      if(bt == 0) break;
      long b = byWeek ? BucketWeek(bt, groupN) : BucketWeekday(bt, groupN, anchor);
      double o = iOpen(_Symbol, tf, s), h = iHigh(_Symbol, tf, s),
             l = iLow(_Symbol, tf, s),  c = iClose(_Symbol, tf, s);
      if(b != curB)
      {
         idx++; curB = b;
         aC[idx] = c; aH[idx] = h; aL[idx] = l; aO[idx] = o; aT[idx] = bt; // newest bar seeds C
      }
      else
      {
         aH[idx] = MathMax(aH[idx], h); aL[idx] = MathMin(aL[idx], l);
         aO[idx] = o; aT[idx] = bt;   // older bar within the block extends O / start time
      }
   }
   n = idx + 1;
}
// Each rebuild is dirty-checked on its source TF's newest bar (cheap to call
// every tick) and then refreshes the forming block [0] with the live bar.
void RebuildSynDaily(int groupN, int anchor, double &aO[], double &aH[], double &aL[], double &aC[], datetime &aT[], int &n, datetime &built)
{
   datetime t0 = iTime(_Symbol, PERIOD_D1, 0);
   if(t0 != built) { BuildSynthetic(PERIOD_D1, false, groupN, anchor, aO, aH, aL, aC, aT, n); built = t0; }
   if(n > 0) { aH[0] = MathMax(aH[0], iHigh(_Symbol, PERIOD_D1, 0));
               aL[0] = MathMin(aL[0], iLow(_Symbol, PERIOD_D1, 0));
               aC[0] = iClose(_Symbol, PERIOD_D1, 0); }
}
// 2D: Monday-anchored pairs.  5D/10D: Thursday-anchored (anchor=3), 10D = 2x5D.
void RebuildSynthetic2D()  { RebuildSynDaily(2,  0, g_c2dO,  g_c2dH,  g_c2dL,  g_c2dC,  g_c2dT,  g_n2d,  g_c2dBuilt);  }
void RebuildSynthetic5D()  { RebuildSynDaily(5,  3, g_c5dO,  g_c5dH,  g_c5dL,  g_c5dC,  g_c5dT,  g_n5d,  g_c5dBuilt);  }
void RebuildSynthetic10D() { RebuildSynDaily(10, 3, g_c10dO, g_c10dH, g_c10dL, g_c10dC, g_c10dT, g_n10d, g_c10dBuilt); }
void RebuildSynthetic2W()
{
   datetime t0 = iTime(_Symbol, PERIOD_W1, 0);
   if(t0 != g_c2wBuilt) { BuildSynthetic(PERIOD_W1, true, 2, 0, g_c2wO, g_c2wH, g_c2wL, g_c2wC, g_c2wT, g_n2w); g_c2wBuilt = t0; }
   if(g_n2w > 0) { g_c2wH[0] = MathMax(g_c2wH[0], iHigh(_Symbol, PERIOD_W1, 0));
                   g_c2wL[0] = MathMin(g_c2wL[0], iLow(_Symbol, PERIOD_W1, 0));
                   g_c2wC[0] = iClose(_Symbol, PERIOD_W1, 0); }
}
// Rebuild exactly the synthetic caches this engine's bias/confirmation need
// (native W1/D1 need no cache). Shared caches are dirty-checked, so a repeat
// call the same tick is a no-op.
void RebuildSyntheticFor(int eng)
{
   int bk = g_engBias[eng], ck = g_engConf[eng];
   if(bk == BK_2W)  RebuildSynthetic2W();
   if(bk == BK_5D)  RebuildSynthetic5D();
   if(bk == BK_10D) RebuildSynthetic10D();
   if(ck == CK_2D)  RebuildSynthetic2D();
}

// --- Engine-aware WEEKLY (bias TF) accessors. Offset 0 = forming block,
//     1 = last closed. Resolve to the current engine's bias construction. ---
double   WOpen(int s)
{
   switch(g_engBias[g_curEng])
   {
      case BK_2W:  return (s >= 0 && s < g_n2w)  ? g_c2wO[s]  : 0.0;
      case BK_5D:  return (s >= 0 && s < g_n5d)  ? g_c5dO[s]  : 0.0;
      case BK_10D: return (s >= 0 && s < g_n10d) ? g_c10dO[s] : 0.0;
      default:     return iOpen(_Symbol, PERIOD_W1, s);   // BK_W1
   }
}
double   WHigh(int s)
{
   switch(g_engBias[g_curEng])
   {
      case BK_2W:  return (s >= 0 && s < g_n2w)  ? g_c2wH[s]  : 0.0;
      case BK_5D:  return (s >= 0 && s < g_n5d)  ? g_c5dH[s]  : 0.0;
      case BK_10D: return (s >= 0 && s < g_n10d) ? g_c10dH[s] : 0.0;
      default:     return iHigh(_Symbol, PERIOD_W1, s);
   }
}
double   WLow(int s)
{
   switch(g_engBias[g_curEng])
   {
      case BK_2W:  return (s >= 0 && s < g_n2w)  ? g_c2wL[s]  : 0.0;
      case BK_5D:  return (s >= 0 && s < g_n5d)  ? g_c5dL[s]  : 0.0;
      case BK_10D: return (s >= 0 && s < g_n10d) ? g_c10dL[s] : 0.0;
      default:     return iLow(_Symbol, PERIOD_W1, s);
   }
}
double   WClose(int s)
{
   switch(g_engBias[g_curEng])
   {
      case BK_2W:  return (s >= 0 && s < g_n2w)  ? g_c2wC[s]  : 0.0;
      case BK_5D:  return (s >= 0 && s < g_n5d)  ? g_c5dC[s]  : 0.0;
      case BK_10D: return (s >= 0 && s < g_n10d) ? g_c10dC[s] : 0.0;
      default:     return iClose(_Symbol, PERIOD_W1, s);
   }
}
datetime WTime(int s)
{
   switch(g_engBias[g_curEng])
   {
      case BK_2W:  return (s >= 0 && s < g_n2w)  ? g_c2wT[s]  : 0;
      case BK_5D:  return (s >= 0 && s < g_n5d)  ? g_c5dT[s]  : 0;
      case BK_10D: return (s >= 0 && s < g_n10d) ? g_c10dT[s] : 0;
      default:     return iTime(_Symbol, PERIOD_W1, s);
   }
}
int      WBars()
{
   switch(g_engBias[g_curEng])
   {
      case BK_2W:  return g_n2w;
      case BK_5D:  return g_n5d;
      case BK_10D: return g_n10d;
      default:     return iBars(_Symbol, PERIOD_W1);
   }
}

// --- Buy-side patterns ---
bool Bias_BC_Buy()    { return WClose(1) > WHigh(2); }
bool Bias_DC_Buy()    { return WLow(1) < WLow(2) && WHigh(1) > WHigh(2) && WClose(1) > WOpen(1); }
bool Bias_BSB_Buy()   { return WClose(2) > WOpen(2) && WHigh(1) <= WHigh(2) && WLow(1) >= WLow(2); }
bool Bias_3DP_Buy()   { return WClose(1) >= WLow(2) && WClose(1) <= WHigh(2) && WLow(0) < WLow(1) && WLow(0) < WLow(2); }
bool Bias_DS_Buy()    { return WClose(1) < WLow(2) && WClose(1) < WLow(3) &&
                               WClose(2) >= WLow(1) && WClose(2) >= WLow(2) && WClose(2) >= WLow(3) &&
                               WLow(0) < WLow(1); }
bool Bias_N3DP_Buy()  { return WHigh(1) <= WHigh(2) && WLow(1) >= WLow(2) && WLow(0) < WLow(1) && WLow(0) < WLow(2); }
bool Bias_NDS_Buy()   { return WHigh(2) <= WHigh(3) && WLow(2) >= WLow(3) &&
                               WClose(1) < WLow(2) && WClose(1) < WLow(3) &&
                               WLow(0) < WLow(1) && WLow(0) < WLow(2) && WLow(0) < WLow(3) &&
                               WHigh(1) <= WHigh(3) && WHigh(0) <= WHigh(3); }

// --- Sell-side patterns ---
bool Bias_BC_Sell()   { return WClose(1) < WLow(2); }
bool Bias_DC_Sell()   { return WHigh(1) > WHigh(2) && WLow(1) < WLow(2) && WClose(1) < WOpen(1); }
bool Bias_SBS_Sell()  { return WClose(2) < WOpen(2) && WHigh(1) <= WHigh(2) && WLow(1) >= WLow(2); }
bool Bias_3DP_Sell()  { return WClose(1) >= WLow(2) && WClose(1) <= WHigh(2) && WHigh(0) > WHigh(1) && WHigh(0) > WHigh(2); }
bool Bias_DS_Sell()   { return WClose(1) > WHigh(2) && WClose(1) > WHigh(3) &&
                               WClose(2) <= WHigh(1) && WClose(2) <= WHigh(2) && WClose(2) <= WHigh(3) &&
                               WHigh(0) > WHigh(1); }
bool Bias_N3DP_Sell() { return WHigh(1) <= WHigh(2) && WLow(1) >= WLow(2) && WHigh(0) > WHigh(1) && WHigh(0) > WHigh(2); }
bool Bias_NDS_Sell()  { return WHigh(2) <= WHigh(3) && WLow(2) >= WLow(3) &&
                               WClose(1) > WHigh(2) && WClose(1) > WHigh(3) &&
                               WHigh(0) > WHigh(1) && WHigh(0) > WHigh(2) && WHigh(0) > WHigh(3) &&
                               WLow(1) >= WLow(3) && WLow(0) >= WLow(3); }

string Bias_BuyText()
{
   string t = "";
   if(Bias_BC_Buy())   t += "BC ";
   if(Bias_DC_Buy())   t += "DC ";
   if(Bias_BSB_Buy())  t += "BSB ";
   if(Bias_3DP_Buy())  t += "3DP ";
   if(Bias_DS_Buy())   t += "3DP-DS ";
   if(Bias_N3DP_Buy()) t += "N-3DP ";
   if(Bias_NDS_Buy())  t += "N-DS ";
   return (t == "") ? "-" : t;
}
string Bias_SellText()
{
   string t = "";
   if(Bias_BC_Sell())   t += "BC ";
   if(Bias_DC_Sell())   t += "DC ";
   if(Bias_SBS_Sell())  t += "SBS ";
   if(Bias_3DP_Sell())  t += "3DP ";
   if(Bias_DS_Sell())   t += "3DP-DS ";
   if(Bias_N3DP_Sell()) t += "N-3DP ";
   if(Bias_NDS_Sell())  t += "N-DS ";
   return (t == "") ? "-" : t;
}

//======================================================================
// DAILY CONFIRMATION PATTERNS — the SAME seven patterns as the Weekly
// bias set, evaluated on the DAILY timeframe. Used ONLY as a directional
// confirmation filter before an entry (a Buy needs >=1 Daily buy pattern,
// a Sell needs >=1 Daily sell pattern). The Daily timeframe does NOT set
// the bias and does NOT generate entries.
//======================================================================
// Engine-aware DAILY (confirmation TF) accessors: native D1 for engine 0,
// synthetic 2D for engine 1. Offset 0 = forming block, 1 = last closed.
// Engine-aware DAILY (confirmation TF) accessors: native D1 (CK_D1) or
// synthetic 2D (CK_2D). Offset 0 = forming block, 1 = last closed.
double   DOpen(int s)  { if(g_engConf[g_curEng] == CK_2D) return (s >= 0 && s < g_n2d) ? g_c2dO[s] : 0.0; return iOpen(_Symbol, PERIOD_D1, s); }
double   DHigh(int s)  { if(g_engConf[g_curEng] == CK_2D) return (s >= 0 && s < g_n2d) ? g_c2dH[s] : 0.0; return iHigh(_Symbol, PERIOD_D1, s); }
double   DLow(int s)   { if(g_engConf[g_curEng] == CK_2D) return (s >= 0 && s < g_n2d) ? g_c2dL[s] : 0.0; return iLow(_Symbol, PERIOD_D1, s); }
double   DClose(int s) { if(g_engConf[g_curEng] == CK_2D) return (s >= 0 && s < g_n2d) ? g_c2dC[s] : 0.0; return iClose(_Symbol, PERIOD_D1, s); }
datetime DTime(int s)  { if(g_engConf[g_curEng] == CK_2D) return (s >= 0 && s < g_n2d) ? g_c2dT[s] : 0;   return iTime(_Symbol, PERIOD_D1, s); }
int      DBars()       { return (g_engConf[g_curEng] == CK_2D) ? g_n2d : iBars(_Symbol, PERIOD_D1); }

// --- Daily Buy-side patterns ---
bool Daily_BC_Buy()    { return DClose(1) > DHigh(2); }
bool Daily_DC_Buy()    { return DLow(1) < DLow(2) && DHigh(1) > DHigh(2) && DClose(1) > DOpen(1); }
bool Daily_BSB_Buy()   { return DClose(2) > DOpen(2) && DHigh(1) <= DHigh(2) && DLow(1) >= DLow(2); }
bool Daily_3DP_Buy()   { return DClose(1) >= DLow(2) && DClose(1) <= DHigh(2) && DLow(0) < DLow(1) && DLow(0) < DLow(2); }
bool Daily_DS_Buy()    { return DClose(1) < DLow(2) && DClose(1) < DLow(3) &&
                                DClose(2) >= DLow(1) && DClose(2) >= DLow(2) && DClose(2) >= DLow(3) &&
                                DLow(0) < DLow(1); }
bool Daily_N3DP_Buy()  { return DHigh(1) <= DHigh(2) && DLow(1) >= DLow(2) && DLow(0) < DLow(1) && DLow(0) < DLow(2); }
bool Daily_NDS_Buy()   { return DHigh(2) <= DHigh(3) && DLow(2) >= DLow(3) &&
                                DClose(1) < DLow(2) && DClose(1) < DLow(3) &&
                                DLow(0) < DLow(1) && DLow(0) < DLow(2) && DLow(0) < DLow(3) &&
                                DHigh(1) <= DHigh(3) && DHigh(0) <= DHigh(3); }

// --- Daily Sell-side patterns ---
bool Daily_BC_Sell()   { return DClose(1) < DLow(2); }
bool Daily_DC_Sell()   { return DHigh(1) > DHigh(2) && DLow(1) < DLow(2) && DClose(1) < DOpen(1); }
bool Daily_SBS_Sell()  { return DClose(2) < DOpen(2) && DHigh(1) <= DHigh(2) && DLow(1) >= DLow(2); }
bool Daily_3DP_Sell()  { return DClose(1) >= DLow(2) && DClose(1) <= DHigh(2) && DHigh(0) > DHigh(1) && DHigh(0) > DHigh(2); }
bool Daily_DS_Sell()   { return DClose(1) > DHigh(2) && DClose(1) > DHigh(3) &&
                                DClose(2) <= DHigh(1) && DClose(2) <= DHigh(2) && DClose(2) <= DHigh(3) &&
                                DHigh(0) > DHigh(1); }
bool Daily_N3DP_Sell() { return DHigh(1) <= DHigh(2) && DLow(1) >= DLow(2) && DHigh(0) > DHigh(1) && DHigh(0) > DHigh(2); }
bool Daily_NDS_Sell()  { return DHigh(2) <= DHigh(3) && DLow(2) >= DLow(3) &&
                                DClose(1) > DHigh(2) && DClose(1) > DHigh(3) &&
                                DHigh(0) > DHigh(1) && DHigh(0) > DHigh(2) && DHigh(0) > DHigh(3) &&
                                DLow(1) >= DLow(3) && DLow(0) >= DLow(3); }

// Daily-confirmation text (which patterns fired) — for the log/Dbg.
string Daily_BuyText()
{
   string t = "";
   if(Daily_BC_Buy())   t += "BC ";
   if(Daily_DC_Buy())   t += "DC ";
   if(Daily_BSB_Buy())  t += "BSB ";
   if(Daily_3DP_Buy())  t += "3DP ";
   if(Daily_DS_Buy())   t += "3DP-DS ";
   if(Daily_N3DP_Buy()) t += "N-3DP ";
   if(Daily_NDS_Buy())  t += "N-DS ";
   return (t == "") ? "-" : t;
}
string Daily_SellText()
{
   string t = "";
   if(Daily_BC_Sell())   t += "BC ";
   if(Daily_DC_Sell())   t += "DC ";
   if(Daily_SBS_Sell())  t += "SBS ";
   if(Daily_3DP_Sell())  t += "3DP ";
   if(Daily_DS_Sell())   t += "3DP-DS ";
   if(Daily_N3DP_Sell()) t += "N-3DP ";
   if(Daily_NDS_Sell())  t += "N-DS ";
   return (t == "") ? "-" : t;
}

// At least one Daily pattern agrees with the trade direction? Needs >=4 Daily
// bars (the DS/N-DS patterns reach shift 3). This is a confirmation filter only.
bool DailyBuyConfirms()  { return DBars() >= 4 && Daily_BuyText()  != "-"; }
bool DailySellConfirms() { return DBars() >= 4 && Daily_SellText() != "-"; }

struct SBiasState
{
   datetime c1Time;      // time of the last-CLOSED weekly candle (W1 shift 1) — rollover marker
   bool     buyInvalid;  // this week's price has traded ABOVE candle-1 high -> BUY bias dead for the week
   bool     sellInvalid; // this week's price has traded BELOW candle-1 low  -> SELL bias dead for the week
   string   dir;         // "BUY" / "SELL" / "BOTH" / "NONE"
   string   buyText;     // active buy patterns, or "-"
   string   sellText;    // active sell patterns, or "-"
   bool     buyPresent;
   bool     sellPresent;
};
SBiasState g_bias[NUM_ENGINES];

// Recompute the Weekly bias every tick: pattern presence/direction (read
// LIVE, exactly like the reference), plus the price-based invalidation
// latches. Must be called before the retest gate each tick.
void ComputeBias(double bid, double ask)
{
   // A new weekly candle clears both invalidation latches — an invalidation
   // can never carry across weeks, exactly like the indicator resetting its
   // bias invalidation once per new higher-timeframe candle.
   datetime c1 = WTime(1);
   if(c1 != g_bias[g_curEng].c1Time)
   {
      g_bias[g_curEng].c1Time      = c1;
      g_bias[g_curEng].buyInvalid  = false;
      g_bias[g_curEng].sellInvalid = false;
   }

   // The DS / N-DS patterns reach back to shift 3, so we need candles 0..3
   // before any bias can be evaluated; until then there is no bias.
   if(WBars() < 4)
   {
      g_bias[g_curEng].buyText     = "-"; g_bias[g_curEng].sellText    = "-";
      g_bias[g_curEng].buyPresent  = false; g_bias[g_curEng].sellPresent = false;
      g_bias[g_curEng].dir         = "NONE";
      return;
   }

   g_bias[g_curEng].buyText     = Bias_BuyText();
   g_bias[g_curEng].sellText    = Bias_SellText();
   g_bias[g_curEng].buyPresent  = (g_bias[g_curEng].buyText  != "-");
   g_bias[g_curEng].sellPresent = (g_bias[g_curEng].sellText != "-");
   g_bias[g_curEng].dir =
       (g_bias[g_curEng].buyPresent && !g_bias[g_curEng].sellPresent) ? "BUY"  :
       (g_bias[g_curEng].sellPresent && !g_bias[g_curEng].buyPresent) ? "SELL" :
       (g_bias[g_curEng].buyPresent &&  g_bias[g_curEng].sellPresent) ? "BOTH" : "NONE";

   // Invalidation — price-based and latched for the rest of the Weekly candle.
   // Reference = candle 1 (last closed weekly). BUY dies once this week's price
   // trades above candle-1 high; SELL dies once it trades below candle-1 low.
   // The two latches are INDEPENDENT so that under BOTH, one side breaking
   // never silences the other (buy and sell run independently, per spec).
   double c1High   = WHigh(1);
   double c1Low    = WLow(1);
   double weekHigh = MathMax(WHigh(0), ask); // running high so far this week, incl. the live tick
   double weekLow  = MathMin(WLow(0),  bid); // running low  so far this week, incl. the live tick
   if(weekHigh > c1High) g_bias[g_curEng].buyInvalid  = true;
   if(weekLow  < c1Low)  g_bias[g_curEng].sellInvalid = true;
}

// A direction is tradeable only if a Weekly pattern of that side is present
// AND that side hasn't been invalidated. With the filter switched off the
// gate is transparent (always allowed).
// V5: BC and DC are EXEMPT from the "price traded through Weekly Candle-1"
// invalidation — they stay valid for the rest of the week; every other Weekly
// pattern is still invalidated. Token-based match so it never partial-matches.
bool HasExemptPattern(string patterns)
{
   if(patterns == "-" || patterns == "")
      return false;
   string parts[];
   int n = StringSplit(patterns, ' ', parts);
   for(int i = 0; i < n; i++)
      if(parts[i] == "BC" || parts[i] == "DC")
         return true;
   return false;
}

// A side is tradeable if its Weekly pattern is present AND (the side hasn't been
// invalidated OR an invalidation-exempt pattern (BC/DC) is present). With the
// bias filter off the gate is transparent.
bool BuyBiasAllowed()  { return !InpUseBiasFilter || (g_bias[g_curEng].buyPresent  && (!g_bias[g_curEng].buyInvalid  || HasExemptPattern(g_bias[g_curEng].buyText))); }
bool SellBiasAllowed() { return !InpUseBiasFilter || (g_bias[g_curEng].sellPresent && (!g_bias[g_curEng].sellInvalid || HasExemptPattern(g_bias[g_curEng].sellText))); }

//+------------------------------------------------------------------+
//| Pattern-text helpers for the research log. A pattern text looks   |
//| like "BC DC 3DP " (space-separated tokens, "-" when none).        |
//| PatternCount = how many patterns fired; ComboKey collapses them   |
//| to a stable "BC+DC+3DP" so the CSV can be GROUP-BY'd directly.    |
//+------------------------------------------------------------------+
int PatternCount(string patterns)
{
   if(patterns == "-" || patterns == "")
      return 0;
   string parts[];
   int n = StringSplit(patterns, ' ', parts);
   int c = 0;
   for(int i = 0; i < n; i++)
      if(StringLen(parts[i]) > 0)
         c++;
   return c;
}

string ComboKey(string patterns)
{
   if(patterns == "-" || patterns == "")
      return "NONE";
   string parts[];
   int n = StringSplit(patterns, ' ', parts);
   string outKey = "";
   for(int i = 0; i < n; i++)
      if(StringLen(parts[i]) > 0)
         outKey += (StringLen(outKey) == 0 ? "" : "+") + parts[i];
   return (StringLen(outKey) == 0) ? "NONE" : outKey;
}

//+------------------------------------------------------------------+
//| 1 pip in price terms. Auto = 10 points on 3/5-digit symbols, 1   |
//| point on 2/4-digit; override via InpPipSizePoints.               |
//+------------------------------------------------------------------+
double PipSize()
{
   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pipPoints = InpPipSizePoints;
   if(pipPoints <= 0)
   {
      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
      pipPoints = (digits == 3 || digits == 5) ? 10.0 : 1.0;
   }
   return pipPoints * point;
}

//+------------------------------------------------------------------+
//| Position sizing — fixed risk only, no compounding.                |
//| lots = riskAmount / (SL distance expressed in money/lot)          |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistance, double riskAmount)
{
   if(slDistance <= 0 || riskAmount <= 0)
      return 0.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0)
      return 0.0;

   double lossPerLot = (slDistance / tickSize) * tickValue;
   if(lossPerLot <= 0)
      return 0.0;

   double lots = riskAmount / lossPerLot;

   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      step = minLot;

   lots = MathFloor(lots / step) * step;
   lots = MathMax(minLot, MathMin(maxLot, lots));

   int stepDigits = (int)MathRound(-MathLog10(step));
   return NormalizeDouble(lots, MathMax(0, stepDigits));
}

//+------------------------------------------------------------------+
//| H1 ATR(14), last CLOSED bar — a stable volatility reading logged  |
//| as market context at entry. 0 if the handle/history isn't ready.  |
//+------------------------------------------------------------------+
double CurrentAtrH1()
{
   if(g_atrHandle == INVALID_HANDLE)
      return 0.0;
   double buf[];
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) == 1)
      return buf[0];
   return 0.0;
}

// V6: capture ONE opportunity-cost row for an armed setup that a rule skipped
// (so the cost of each rule is measurable offline). Guarded to once per setup.
void LogSkip(bool isSell, SSignalState &st, string reason)
{
   if(!InpLogSkippedSetups || st.skipLogged)
      return;
   st.skipLogged = true;
   CaptureSetupOutcome(isSell, st.refTime, st.refHigh, st.refLow, st.ccTime, st.slLevel, st.rcLevelTouched, reason);
}

//+------------------------------------------------------------------+
//| Attempts to open one trade for a just-confirmed Retest Candle.    |
//| Entry logic, SL/TP, risk sizing and daily rules all live here — no |
//| time-of-day / session gate (V3 trades 24/5).                       |
//| all live here — none of it touches the signal-detection state     |
//| machine above.                                                    |
//+------------------------------------------------------------------+
bool TryOpen(bool isSell, SSignalState &st)
{
   string side = isSell ? "SELL" : "BUY";

   // One open trade per weekly-bias EPISODE per side. A trade from a DIFFERENT
   // (earlier) weekly bias may still be open — that does NOT block this one,
   // which is the whole point: overlapping trades are allowed when they come
   // from different weekly biases.
   if(HasOpenTradeForEpisode(g_curEng, isSell, g_bias[g_curEng].c1Time) || HasPendingLimitForEpisode(g_curEng, isSell, g_bias[g_curEng].c1Time))
   { g_rejPosOpen++; Dbg(side + " retest REJECT: a trade (or pending Case-1 limit) for the current weekly-bias episode already exists"); return false; }
   if(st.doneToday)
   { g_rejDoneToday++; LogSkip(isSell, st, "SkipDoneToday"); Dbg(side + " retest REJECT: this side already booked a win today (doneToday)"); return false; }
   if(st.tradesToday >= 2)
   { g_rejMaxTrades++; LogSkip(isSell, st, "SkipMaxTrades"); Dbg(side + " retest REJECT: daily 2-trade limit reached"); return false; }
   // (Session gate removed — every valid setup is taken regardless of session.)

   // 1W bias gate — a Retest Candle only becomes an actionable entry if the
   // Weekly bias currently supports this direction and hasn't been invalidated.
   // Buy and sell are gated independently, so under a BOTH-bias day each side
   // can still trade on its own. This gates ONLY the entry; the LUCC/LDCC/
   // CC/RC detection above is untouched.
   bool biasOk = isSell ? SellBiasAllowed() : BuyBiasAllowed();
   if(!biasOk)
   {
      g_rejBias++;
      LogSkip(isSell, st, "SkipBias");
      Dbg(StringFormat("%s retest REJECT: bias gate (dir=%s buy=[%s]%s sell=[%s]%s)", side, g_bias[g_curEng].dir,
                       g_bias[g_curEng].buyText,  g_bias[g_curEng].buyInvalid  ? " INVALID" : "",
                       g_bias[g_curEng].sellText, g_bias[g_curEng].sellInvalid ? " INVALID" : ""));
      return false;
   }

   // Daily confirmation filter — the Daily timeframe must show at least one
   // pattern (of the same seven) agreeing with the trade direction. Confirmation
   // only: Daily never sets the bias or generates the entry.
   if(InpUseDailyConfirmation)
   {
      bool dailyOk = isSell ? DailySellConfirms() : DailyBuyConfirms();
      if(!dailyOk)
      {
         g_rejDailyConf++;
         LogSkip(isSell, st, "SkipDailyConf");
         Dbg(StringFormat("%s retest REJECT: no Daily %s confirmation (dailyBuy=[%s] dailySell=[%s])",
                          side, isSell ? "SELL" : "BUY", Daily_BuyText(), Daily_SellText()));
         return false;
      }
   }

   // Stop-after-first-win rule: once this side booked a WIN in the CURRENT
   // weekly-bias episode, skip further setups in this direction FOR THAT
   // EPISODE ONLY. Because episodes are per weekly candle, a new week is a
   // fresh instance with no restriction. Losses do not trigger this. Toggle
   // off for the "unlimited trades per weekly bias" dataset.
   if(InpStopAfterFirstWin && HasWinEpisode(g_curEng, isSell, g_bias[g_curEng].c1Time))
   {
      g_skippedAfterWin++;
      RecordWeeklySkip(g_curEng, TimeCurrent());
      LogSkip(isSell, st, "SkipAfterWin");
      Dbg(side + " retest SKIP: a win was already booked in the current weekly-bias episode");
      return false;
   }

   double entry = isSell ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                          : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double structuralSl = st.slLevel;

   // Sanity guard: the indicator's SL level is a high (sell) / low (buy)
   // spanning the reference-to-CC range, so it must sit on the correct
   // side of the current market price for a valid stop.
   if((isSell && structuralSl <= entry) || (!isSell && structuralSl >= entry))
   {
      g_rejSlInvalid++;
      Dbg(StringFormat("%s retest REJECT: structural SL %.5f on wrong side of entry %.5f", side, structuralSl, entry));
      return false;
   }

   // Proportional SL buffer — the FINAL stop distance is the original structural
   // SL range (ORIGINAL retest entry -> structural stop) x InpStopLossMultiplier
   // (e.g. x1.3). In V5 this yields a FIXED SL LEVEL (sl) that is never moved:
   // the entry may be adjusted (Case 1), but the stop stays exactly here.
   double eOrig      = entry;                                 // original retest (market) entry
   double origRange  = MathAbs(eOrig - structuralSl);
   double finalRange = origRange * InpStopLossMultiplier;
   double sl         = isSell ? eOrig + finalRange : eOrig - finalRange;   // FIXED stop level

   // V6 STALE-ENTRY FILTER — how far did price run AWAY (profit direction) from the
   // planned RC entry level before returning to retest it? Measured from the CC's
   // profit-side extreme (tracked while armed) to the RC level, in price. If it
   // exceeds InpMaxAwayR x the planned SL distance, the move we wanted already
   // happened without us: abandon this setup and hunt a brand-new one. Applies to
   // the (not-yet-triggered) armed wait for BOTH market and Case-1 limit entries.
   double rcLevel        = isSell ? st.refLow : st.refHigh;
   double awayBeforeEntry = isSell ? (rcLevel - st.awayExtreme) : (st.awayExtreme - rcLevel);
   if(awayBeforeEntry < 0.0) awayBeforeEntry = 0.0;
   if(InpUseStaleEntryFilter && finalRange > 0.0 && awayBeforeEntry > InpMaxAwayR * finalRange)
   {
      double pipv = PipSize();
      Dbg(StringFormat("%s retest EXPIRED (stale): price ran %.1f pips (%.2fR) away from entry %.5f before retest > %.1fR limit — hunting a new setup",
                       side, pipv > 0 ? awayBeforeEntry / pipv : 0.0,
                       awayBeforeEntry / finalRange, rcLevel, InpMaxAwayR));
      LogSkip(isSell, st, "SkipStale2R");     // opportunity-cost capture (before the state is wiped)
      st.expiredRefTime = st.refTime;         // this reference is done — wait for a genuinely new one
      st.ccTime         = 0;
      st.slLevel        = 0;
      st.rcLevelTouched = false;
      g_expiredPending++;
      return false;
   }

   // Defaults = classic fixed-RR TP at the original entry (used when V5 target
   // fixation is OFF). dist = risk distance |entry - SL|; entry stays at market.
   double dist     = finalRange;
   double tp       = isSell ? eOrig - dist * InpTakeProfitRMultiple : eOrig + dist * InpTakeProfitRMultiple;
   bool   useLimit = false;      // Case-1: a pending BUY/SELL LIMIT entry?
   string tgtSrc   = "FixedRR";  // target source, for the log

   if(InpUseWeeklyTargetFixation)
   {
      // Default target = Weekly Candle-1 High(buy)/Low(sell). For BC/DC only,
      // once price has traded through Weekly C1 (side invalidated) the target
      // responsibility shifts to Daily Candle-1 High(buy)/Low(sell).
      bool   exempt   = HasExemptPattern(isSell ? g_bias[g_curEng].sellText : g_bias[g_curEng].buyText);
      bool   thru     = isSell ? g_bias[g_curEng].sellInvalid : g_bias[g_curEng].buyInvalid;
      bool   useDaily = exempt && thru;
      double wLvl     = isSell ? WLow(1) : WHigh(1);
      double dLvl     = isSell ? DLow(1) : DHigh(1);
      double tgt      = useDaily ? dLvl : wLvl;
      tgtSrc          = useDaily ? "DailyC1" : "WeeklyC1";

      // The target must sit beyond the FIXED stop for a positive-RR trade.
      bool tgtValid = isSell ? (tgt < sl - _Point) : (tgt > sl + _Point);
      if(!tgtValid)
      {
         g_rejSlInvalid++;
         Dbg(StringFormat("%s retest REJECT: %s target %.5f not beyond fixed SL %.5f", side, tgtSrc, tgt, sl));
         return false;
      }

      // RR to the fixed target, measured from the ORIGINAL entry (R = finalRange).
      double rrOrig = isSell ? (eOrig - tgt) / finalRange : (tgt - eOrig) / finalRange;

      if(rrOrig > InpMaxTargetRR)
      {
         // Case 3 — cap at the hard R. Market entry at eOrig; TP at MaxTargetRR.
         dist    = finalRange;
         tp      = isSell ? eOrig - dist * InpMaxTargetRR : eOrig + dist * InpMaxTargetRR;
         tgtSrc  = tgtSrc + "|cap" + DoubleToString(InpMaxTargetRR, 1) + "R";
      }
      else if(rrOrig >= InpMinTargetRR)
      {
         // Case 2 — accept the level as-is. Market entry at eOrig.
         dist = finalRange;
         tp   = tgt;
      }
      else
      {
         // Case 1 — RR too small at market. Keep the SL LEVEL fixed at the
         // structural stop and move the ENTRY toward it (a pending limit), which
         // SHRINKS the risk distance and raises the RR to the fixed target:
         //   buy : (tgt - E)/(E - sl) = k  ->  E = (tgt + k*sl)/(k + 1)
         //   sell: (E - tgt)/(sl - E) = k  ->  E = (tgt + k*sl)/(k + 1)   (identical)
         // V6: the stop may only shrink until it reaches the 10-pip floor
         // (InpMinStopLossPips — already includes the 1.3 buffer, never re-applied).
         double pipv  = PipSize();
         double minSL = InpMinStopLossPips * pipv;        // 10-pip floor (final, pre-buffered)
         double k     = InpMinTargetRR;
         double eK    = (tgt + k * sl) / (k + 1.0);        // entry that yields exactly kR (SL fixed at sl)
         double distK = MathAbs(eK - sl);                  // its reduced risk distance

         if(distK >= minSL)
         {
            // Reaching InpMinTargetRR keeps the stop at/above the floor — good.
            entry    = eK;
            dist     = distK;
            tp       = tgt;
            useLimit = true;
            tgtSrc   = tgtSrc + "|limit" + DoubleToString(InpMinTargetRR, 1) + "R";
         }
         else
         {
            // Even at the 10-pip floor the C1 target can't provide InpMinTargetRR.
            // V6: DON'T reject — fix the stop at the floor and use a fixed
            // InpCappedTP_R target (default 4R => 10-pip SL, 40-pip TP). The TP is
            // allowed to extend beyond the Weekly/Daily C1 level.
            dist  = minSL;
            entry = isSell ? sl - minSL : sl + minSL;       // 10 pips from the fixed structural stop
            tp    = isSell ? entry - dist * InpCappedTP_R : entry + dist * InpCappedTP_R;
            // A valid improving limit needs the entry better than market (buy
            // below Ask / sell above Bid). If the raw padded stop is already <=
            // the floor the "improved" entry sits at/through the market — fall
            // back to a market entry with the stop floored to 10 pips.
            bool validLimit = isSell ? (entry > eOrig + _Point) : (entry < eOrig - _Point);
            if(validLimit)
            {
               useLimit = true;
               tgtSrc   = tgtSrc + "|min10SL|" + DoubleToString(InpCappedTP_R, 1) + "R";
            }
            else
            {
               entry    = eOrig;                                   // market entry
               sl       = isSell ? eOrig + minSL : eOrig - minSL;  // stop floored to 10 pips from market
               dist     = minSL;
               tp       = isSell ? entry - dist * InpCappedTP_R : entry + dist * InpCappedTP_R;
               useLimit = false;
               tgtSrc   = tgtSrc + "|min10SLmkt|" + DoubleToString(InpCappedTP_R, 1) + "R";
            }
         }
      }
   }

   // V6: universal 10-pip minimum stop for MARKET entries (Cases 2/3 and the
   // fixed-RR fallback). Case-1 limits already honor the floor above. Widening
   // the stop only reduces RR to the (unchanged) target — the floor always wins.
   if(!useLimit)
   {
      double minSLm = InpMinStopLossPips * PipSize();
      if(minSLm > 0.0 && MathAbs(eOrig - sl) < minSLm - _Point)
      {
         sl     = isSell ? eOrig + minSLm : eOrig - minSLm;
         dist   = minSLm;
         tgtSrc = tgtSrc + "|SLfloor10";
      }
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   entry = NormalizeDouble(entry, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   double point         = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStopPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist        = minStopPoints * point;
   if(minDist > 0 && (MathAbs(entry - sl) < minDist || MathAbs(entry - tp) < minDist))
   {
      g_rejMinStop++;
      Dbg(StringFormat("%s retest REJECT: SL/TP inside broker min stop distance (%.0f pts). entry=%.5f sl=%.5f tp=%.5f",
                       side, minStopPoints, entry, sl, tp));
      return false;
   }

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);   // for the journal only — not used for sizing
   double riskAmount = g_riskBalance * InpRiskPercent / 100.0; // fixed reference balance — no compounding
   double lots = CalcLotSize(dist, riskAmount);
   if(lots <= 0)
   {
      g_rejLots++;
      Dbg(StringFormat("%s retest REJECT: computed lots <= 0 (riskAmount=%.2f slDist=%.5f)", side, riskAmount, dist));
      return false;
   }

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   // Market-condition snapshot at the entry tick (for the research log).
   double bidAtEntry   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double askAtEntry   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spreadPoints = (point > 0) ? (askAtEntry - bidAtEntry) / point : 0.0;
   double atrH1AtEntry = CurrentAtrH1();

   // Freeze the full entry snapshot. For a market entry it is completed and
   // pushed immediately; for a Case-1 limit it is stored and completed at fill.
   // (positionId / entryPrice / entryTime / initRiskDist are set at fill.)
   SOpenTrade ot;
   ot.engine          = g_curEng;         // V7: this trade belongs to the current engine
   ot.isSell          = isSell;
   ot.positionId      = 0;
   ot.episode         = g_bias[g_curEng].c1Time;   // this trade's weekly-bias identity
   ot.refTime         = st.refTime;  ot.refHigh = st.refHigh;  ot.refLow = st.refLow;
   ot.ccTime          = st.ccTime;   ot.rcTime  = st.rcTime;
   ot.entryTime       = TimeCurrent();
   ot.entryPrice      = entry;            // provisional (= requested); overwritten by the real fill
   ot.slPrice         = sl;   ot.tpPrice = tp;
   ot.structuralSl    = structuralSl;   ot.requestedEntry = entry;
   ot.riskAmount      = riskAmount;   ot.lots = lots;   ot.tradeSeqToday = st.tradesToday + 1;
   ot.balanceBeforeEntry = balance;   ot.equityBefore = AccountInfoDouble(ACCOUNT_EQUITY);
   ot.bidAtEntry      = bidAtEntry;   ot.askAtEntry = askAtEntry;
   ot.spreadPoints    = spreadPoints; ot.atrH1AtEntry = atrH1AtEntry;
   ot.biasDir         = g_bias[g_curEng].dir;   ot.biasBuyText = g_bias[g_curEng].buyText;   ot.biasSellText = g_bias[g_curEng].sellText;
   ot.sideBiasText    = isSell ? g_bias[g_curEng].sellText : g_bias[g_curEng].buyText;
   ot.biasCandleTime  = g_bias[g_curEng].c1Time;
   ot.weekO = WOpen(1); ot.weekH = WHigh(1); ot.weekL = WLow(1); ot.weekC = WClose(1);
   ot.dayO  = DOpen(1); ot.dayH = DHigh(1);
   ot.dayL  = DLow(1);  ot.dayC = DClose(1);
   ot.mfePrice = entry; ot.maePrice = entry;
   ot.initRiskDist = MathAbs(entry - sl);   // the trade's own 1R (finalised on fill)
   ot.beArmed      = false;   ot.beLevelPrice = entry;   ot.beArmTime = 0;
   ot.tgtLockArmed = false;   ot.tgtLockPrice = 0.0;
   // --- V6 research fields ---
   ot.entryType       = useLimit ? "LIMIT" : "MARKET";
   ot.targetSource    = tgtSrc;
   ot.limitPlacedTime = useLimit ? TimeCurrent() : 0;
   ot.plannedRR       = (dist > 0.0) ? MathAbs(tp - entry) / dist : 0.0;
   ot.dailyBuyText    = Daily_BuyText();
   ot.dailySellText   = Daily_SellText();
   ot.dailySideText   = isSell ? ot.dailySellText : ot.dailyBuyText;
   ot.partialDone     = false; ot.partialTime = 0; ot.partialPrice = 0.0;
   ot.partialLots     = 0.0; ot.partialProfit = 0.0; ot.partialComm = 0.0; ot.partialSwap = 0.0;
   ot.maxDDMoney      = 0.0; ot.secsInProfit = 0; ot.secsInDraw = 0; ot.lastTickTime = 0;
   ot.firstFavRTime   = 0; ot.tpHitTime = 0;
   ot.maxAwayBeforeEntry = awayBeforeEntry;   // V6: armed-wait away-move; a Case-1 limit extends it post-placement

   if(useLimit)
   {
      // === Case 1 — pending BUY/SELL LIMIT at the improved (better) price ===
      bool okL = isSell
         ? g_trade.SellLimit(lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "LUCC-RC SellLimit")
         : g_trade.BuyLimit (lots, entry, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "LDCC-RC BuyLimit");
      if(!okL)
      {
         g_rejOrderFail++;
         PrintFormat("LUCC/LDCC EA: %s LIMIT place failed, retcode=%d (%s)",
                     side, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         return false;
      }
      st.tradesToday++;   // the placement consumes a daily slot (reset next day, when unfilled limits are cancelled)
      int pe = ArraySize(g_pendingEntries);
      ArrayResize(g_pendingEntries, pe + 1);
      g_pendingEntries[pe].snap        = ot;
      g_pendingEntries[pe].orderTicket = (long)g_trade.ResultOrder();
      g_pendingEntries[pe].placedTime  = TimeCurrent();
      g_pendingEntries[pe].awayExtreme = entry;   // V6: seed the post-placement away-extreme at the limit price
      g_cntLimitsPlaced++;
      Dbg(StringFormat("%s CASE-1 LIMIT placed @ %.5f sl=%.5f tp=%.5f (%s, RR=%.2f) lots=%.2f ticket=%d",
                       side, entry, sl, tp, tgtSrc, InpMinTargetRR, lots, g_pendingEntries[pe].orderTicket));
      return true;
   }

   // === Cases 2 & 3 (and fixed-RR fallback) — immediate MARKET entry ===
   bool ok = isSell
      ? g_trade.Sell(lots, _Symbol, entry, sl, tp, "LUCC-RC Sell")
      : g_trade.Buy(lots, _Symbol, entry, sl, tp, "LDCC-RC Buy");

   if(ok)
   {
      st.tradesToday++;
      long posId = 0;
      ulong dealTicket = g_trade.ResultDeal();
      if(HistoryDealSelect(dealTicket))
         posId = (long)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
      double fillPrice = g_trade.ResultPrice();

      ot.positionId   = posId;
      ot.entryTime    = TimeCurrent();
      ot.entryPrice   = (fillPrice > 0) ? fillPrice : entry;
      ot.tradeSeqToday = st.tradesToday;
      ot.initRiskDist = MathAbs(ot.entryPrice - sl);
      ot.beLevelPrice = ot.entryPrice;
      ot.mfePrice     = ot.entryPrice; ot.maePrice = ot.entryPrice;

      int oi = ArraySize(g_openTrades);
      ArrayResize(g_openTrades, oi + 1);
      g_openTrades[oi] = ot;

      g_cntEntries++;
      Dbg(StringFormat("%s ENTRY OK (market): fill=%.5f sl=%.5f tp=%.5f lots=%.2f risk=%.2f (%s) episode=%s bias[%s] (openTrades=%d)",
                       side, ot.entryPrice, sl, tp, lots, riskAmount, tgtSrc,
                       TimeToString(GetNairobiTime(ot.episode), TIME_DATE), ot.sideBiasText, ArraySize(g_openTrades)));
      return true;
   }

   g_rejOrderFail++;
   PrintFormat("LUCC/LDCC EA: %s order failed, retcode=%d (%s)",
               side, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| V5 — a Case-1 pending LIMIT filled. Match the fill deal to its     |
//| stored snapshot (by the pending order ticket), finalise the entry  |
//| (real fill price / position id / time), and push it onto the live  |
//| open-trade list so BE / target-lock / close handling all apply.    |
//+------------------------------------------------------------------+
void HandleFill(ulong dealTicket)
{
   long orderTicket = (long)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
   int idx = -1;
   for(int i = 0; i < ArraySize(g_pendingEntries); i++)
      if(g_pendingEntries[i].orderTicket == orderTicket) { idx = i; break; }
   if(idx < 0)
      return; // a market fill (already handled synchronously) or not one of ours

   SOpenTrade ot = g_pendingEntries[idx].snap;
   ot.positionId = (long)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);
   ot.entryTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
   double fill   = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
   ot.entryPrice = (fill > 0) ? fill : ot.requestedEntry;
   ot.initRiskDist = MathAbs(ot.entryPrice - ot.slPrice);
   ot.beLevelPrice = ot.entryPrice;
   ot.mfePrice = ot.entryPrice; ot.maePrice = ot.entryPrice;

   int oi = ArraySize(g_openTrades);
   ArrayResize(g_openTrades, oi + 1);
   g_openTrades[oi] = ot;
   ArrayRemove(g_pendingEntries, idx, 1);

   g_cntLimitsFilled++;
   g_cntEntries++;
   Dbg(StringFormat("%s CASE-1 LIMIT FILLED: fill=%.5f sl=%.5f tp=%.5f posId=%d (openTrades=%d, pendingLimits=%d)",
                    ot.isSell ? "SELL" : "BUY", ot.entryPrice, ot.slPrice, ot.tpPrice, ot.positionId,
                    ArraySize(g_openTrades), ArraySize(g_pendingEntries)));
}

//+------------------------------------------------------------------+
//| V5 — cancel every unfilled Case-1 limit. Called at the new Nairobi |
//| day so no adjusted-entry order lives past the day it was placed.   |
//+------------------------------------------------------------------+
void CancelPendingLimits()
{
   for(int i = ArraySize(g_pendingEntries) - 1; i >= 0; i--)
   {
      if(g_trade.OrderDelete((ulong)g_pendingEntries[i].orderTicket))
      {
         g_cntLimitsExpired++;
         Dbg(StringFormat("%s CASE-1 LIMIT expired (new day) ticket=%d cancelled",
                          g_pendingEntries[i].snap.isSell ? "SELL" : "BUY", g_pendingEntries[i].orderTicket));
      }
      ArrayRemove(g_pendingEntries, i, 1);
   }
}

//+------------------------------------------------------------------+
//| V6 (Change 2) — Daily invalidation of an UNFILLED Case-1 limit.    |
//| While a limit waits to fill, if price trades beyond Daily Candle-1 |
//| (buy: above C1 High; sell: below C1 Low) the entry has expired:    |
//| delete the order immediately, capture the opportunity-cost row,    |
//| and let the EA hunt a completely new setup. Called every tick.     |
//| Daily C1 = the previous completed daily candle, frozen with the    |
//| snapshot (constant within the day; day-boundary cancels the rest). |
//+------------------------------------------------------------------+
void ExpireLimitsOnDailyBreak(double bid, double ask)
{
   if(!InpCancelLimitOnDailyBreak || ArraySize(g_pendingEntries) == 0 || iBars(_Symbol, PERIOD_D1) < 2)
      return;

   for(int i = ArraySize(g_pendingEntries) - 1; i >= 0; i--)
   {
      SOpenTrade snap = g_pendingEntries[i].snap;
      // V7: evaluate the Daily-C1 break on THIS pending's engine timeframe.
      g_curEng = snap.engine;
      double dHiNow = MathMax(DHigh(0), MathMax(bid, ask)); // running (2-)day high, incl. tick
      double dLoNow = MathMin(DLow(0),  MathMin(bid, ask)); // running (2-)day low,  incl. tick
      double c1High = snap.dayH;   // (2-)Daily Candle-1 High frozen at placement
      double c1Low  = snap.dayL;   // (2-)Daily Candle-1 Low  frozen at placement
      bool   broke  = snap.isSell ? (dLoNow < c1Low) : (dHiNow > c1High);
      if(!broke)
         continue;

      if(g_trade.OrderDelete((ulong)g_pendingEntries[i].orderTicket))
      {
         g_cntLimitsExpired++;
         Dbg(StringFormat("%s CASE-1 LIMIT expired (Daily-C1 %s traded through) ticket=%d deleted — hunting a new setup",
                          snap.isSell ? "SELL" : "BUY", snap.isSell ? "Low" : "High",
                          g_pendingEntries[i].orderTicket));
      }
      else
      {
         Dbg(StringFormat("%s CASE-1 LIMIT Daily-break delete FAILED ticket=%d retcode=%d (%s)",
                          snap.isSell ? "SELL" : "BUY", g_pendingEntries[i].orderTicket,
                          g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      }
      // Opportunity-cost capture: the setup was ready but the entry expired.
      CaptureSetupOutcome(snap.isSell, snap.refTime, snap.refHigh, snap.refLow, snap.ccTime,
                          snap.structuralSl, true, "LimitDailyBreak");
      ArrayRemove(g_pendingEntries, i, 1);
   }
}

//+------------------------------------------------------------------+
//| V6 (Stale-entry, pending-limit phase) — while a Case-1 limit is    |
//| unfilled, track the furthest price it reaches in the PROFIT        |
//| direction away from the limit price; if that exceeds InpMaxAwayR x  |
//| the limit's SL distance before it fills, the move already happened  |
//| without us: delete the order, capture the opportunity cost, and     |
//| hunt a new setup. Also keeps snap.maxAwayBeforeEntry current so a   |
//| limit that DOES fill logs its true away-before-entry. Every tick.   |
//+------------------------------------------------------------------+
void UpdatePendingLimitStale(double bid, double ask)
{
   if(ArraySize(g_pendingEntries) == 0)
      return;
   double pipv = PipSize();
   for(int i = ArraySize(g_pendingEntries) - 1; i >= 0; i--)
   {
      g_curEng        = g_pendingEntries[i].snap.engine;   // V7: engine context for the opp-cost capture
      bool   isSell   = g_pendingEntries[i].snap.isSell;
      double limitPx  = g_pendingEntries[i].snap.requestedEntry;
      double slDist   = MathAbs(g_pendingEntries[i].snap.requestedEntry - g_pendingEntries[i].snap.slPrice);

      // Extend the profit-direction extreme since placement.
      g_pendingEntries[i].awayExtreme = isSell ? MathMin(g_pendingEntries[i].awayExtreme, bid)
                                               : MathMax(g_pendingEntries[i].awayExtreme, ask);
      double awayDist = isSell ? (limitPx - g_pendingEntries[i].awayExtreme)
                               : (g_pendingEntries[i].awayExtreme - limitPx);
      if(awayDist < 0.0) awayDist = 0.0;
      // Carry the larger of the armed-wait and post-placement away-move onto the
      // snapshot, so a fill logs the true worst away-before-entry.
      if(awayDist > g_pendingEntries[i].snap.maxAwayBeforeEntry)
         g_pendingEntries[i].snap.maxAwayBeforeEntry = awayDist;

      if(!InpUseStaleEntryFilter || slDist <= 0.0 || awayDist <= InpMaxAwayR * slDist)
         continue;

      SOpenTrade snap = g_pendingEntries[i].snap;
      if(g_trade.OrderDelete((ulong)g_pendingEntries[i].orderTicket))
      {
         g_cntLimitsExpired++;
         Dbg(StringFormat("%s CASE-1 LIMIT EXPIRED (stale): ran %.1f pips (%.2fR) away from limit %.5f before fill > %.1fR — deleted, hunting a new setup",
                          isSell ? "SELL" : "BUY", pipv > 0 ? awayDist / pipv : 0.0,
                          awayDist / slDist, limitPx, InpMaxAwayR));
      }
      else
      {
         Dbg(StringFormat("%s CASE-1 LIMIT stale-delete FAILED ticket=%d retcode=%d (%s)",
                          isSell ? "SELL" : "BUY", g_pendingEntries[i].orderTicket,
                          g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      }
      CaptureSetupOutcome(snap.isSell, snap.refTime, snap.refHigh, snap.refLow, snap.ccTime,
                          snap.structuralSl, true, "LimitStale2R");
      ArrayRemove(g_pendingEntries, i, 1);
   }
}

//+------------------------------------------------------------------+
//| Once-per-bar entry point — the EA's equivalent of the indicator's |
//| `if barstate.isconfirmed` block. Runs both directions in the same |
//| order the indicator's script does (SELL/LUCC, then BUY/LDCC).     |
//+------------------------------------------------------------------+
void ProcessNewBar()
{
   if(GetMaxBack() < 0)
      return;
   // V7: run reference/CC detection for BOTH engines on the just-closed H1 bar.
   // Each engine reads its own higher-TF candles (via g_curEng) and its own
   // per-side signal state — the H1 detection code is shared and unchanged.
   for(int eng = 0; eng < NUM_ENGINES; eng++)
   {
      g_curEng = eng;
      RebuildSyntheticFor(eng);
      UpdateDirection(true,  g_sell[eng]);
      UpdateDirection(false, g_buy[eng]);
   }
}

//+------------------------------------------------------------------+
//| Trade journal — one CSV row per closed trade.                     |
//|                                                                    |
//| R_Realized is what the trade actually made at whatever TP         |
//| InpTakeProfitRMultiple currently sets, so by construction it will |
//| basically always read ~+InpTakeProfitRMultiple or ~-1 — it does   |
//| NOT tell you whether a DIFFERENT target would have worked better. |
//| MFE_R / MAE_R exist for that: they are NOT capped at the actual   |
//| exit. Once a trade closes it moves to a "pending" queue (see      |
//| SPendingLog) where UpdatePendingExcursions() keeps extending      |
//| mfePrice/maePrice for InpExcursionTrackingHours from ENTRY, same  |
//| as if the trade had no stop or target at all, before the row is   |
//| finally written. Treat MFE_R as directional evidence only — it    |
//| doesn't know whether the ORIGINAL SL would have been hit before a |
//| wider target. For a rigorous answer, sweep InpTakeProfitRMultiple |
//| itself through Strategy Tester's Optimizer and compare net profit |
//| directly; that replays the real price path against both the real |
//| SL and each candidate TP, which MFE_R alone cannot do.            |
//+------------------------------------------------------------------+
string CsvEscape(string s)
{
   StringReplace(s, ",", ";");
   StringReplace(s, "\n", " ");
   StringReplace(s, "\r", " ");
   return s;
}

string FmtTime(datetime t)
{
   return (t == 0) ? "-" : TimeToString(t, TIME_DATE | TIME_MINUTES | TIME_SECONDS);
}

// Same, but converts a broker SERVER time to Africa/Nairobi first. Used for
// every event timestamp in the log so they match TradingView (Nairobi).
string FmtNairobi(datetime serverTime)
{
   return (serverTime == 0) ? "-" : TimeToString(GetNairobiTime(serverTime), TIME_DATE | TIME_MINUTES | TIME_SECONDS);
}

// Joins one row of fields with commas and writes it as a single line. Using
// one string (rather than a variadic FileWrite) keeps the ~70-column row
// safely under FileWrite's argument limit and guarantees the header and the
// data rows share the exact same column count / order.
void WriteCsvRow(const string &fields[])
{
   string line = "";
   for(int i = 0; i < ArraySize(fields); i++)
      line += (i == 0 ? "" : ",") + fields[i];
   FileWrite(g_logHandle, line);
   FileFlush(g_logHandle);
}

//======================================================================
// Per-trade PATH log — one row per path-TF bar per tracked trade, with the
// bar OHLC plus favorable/adverse excursion in R at that bar. This is what
// makes trailing-stop / breakeven / RR exit rules EXACTLY replayable offline
// (no rerun): join to the trade log on TradeID and walk the bars in order.
// Phase = OPEN (position live) or EXTENDED (closed but still inside the
// excursion-tracking window, so you can also test exits that hold longer
// than the current SL/TP).
//======================================================================
void WritePathHeader()
{
   FileWrite(g_pathHandle,
      "TradeID,Direction,EntryPattern,Phase,BarTime,Open,High,Low,Close,"
      "EntryPrice,InitSL,TP,InitRiskPips,BarFavR,BarAdvR,BarsSinceEntry");
}

void WritePathRow(long tradeId, bool isSell, string phase, datetime barTime,
                  double o, double h, double l, double c,
                  double entry, double sl, double tp, double riskDist, datetime entryTime)
{
   if(g_pathHandle == INVALID_HANDLE)
      return;
   double risk = (riskDist > 0.0) ? riskDist : MathAbs(entry - sl);
   double favR = 0.0, advR = 0.0;   // this bar's best-favorable / worst-adverse excursion, in R
   if(risk > 0.0)
   {
      if(isSell) { favR = (entry - l) / risk; advR = (entry - h) / risk; }
      else       { favR = (h - entry) / risk; advR = (l - entry) / risk; }
   }
   double pip       = PipSize();
   int    secs      = PeriodSeconds(InpPathLogTimeframe); if(secs <= 0) secs = 3600;
   int    barsSince = (int)((long)(barTime - entryTime) / secs);
   string entryPat  = isSell ? "LUCC" : "LDCC";
   string line = (string)tradeId + "," + (isSell ? "SELL" : "BUY") + "," + entryPat + "," + phase + ","
      + FmtNairobi(barTime) + "," + DoubleToString(o, _Digits) + "," + DoubleToString(h, _Digits) + ","
      + DoubleToString(l, _Digits) + "," + DoubleToString(c, _Digits) + "," + DoubleToString(entry, _Digits) + ","
      + DoubleToString(sl, _Digits) + "," + DoubleToString(tp, _Digits) + "," + DoubleToString(pip > 0 ? risk / pip : 0.0, 1) + ","
      + DoubleToString(favR, 3) + "," + DoubleToString(advR, 3) + "," + (string)barsSince;
   FileWrite(g_pathHandle, line);
}

// On each new path-TF bar, append the just-closed bar for every tracked trade
// (open positions + trades still in the excursion window). Self-guards so it
// runs once per path bar regardless of how often OnTick fires.
void WritePathBars()
{
   if(!InpEnablePathLog || g_pathHandle == INVALID_HANDLE)
      return;
   ENUM_TIMEFRAMES tf = InpPathLogTimeframe;
   datetime cur = iTime(_Symbol, tf, 0);
   if(cur == 0 || cur == g_lastPathBar)
      return;
   g_lastPathBar = cur;

   datetime bt = iTime(_Symbol, tf, 1);   // the just-closed path bar
   if(bt == 0)
      return;
   double o = iOpen(_Symbol, tf, 1), h = iHigh(_Symbol, tf, 1), l = iLow(_Symbol, tf, 1), c = iClose(_Symbol, tf, 1);

   for(int i = 0; i < ArraySize(g_openTrades); i++)
      WritePathRow(g_openTrades[i].positionId, g_openTrades[i].isSell, "OPEN", bt, o, h, l, c,
                   g_openTrades[i].entryPrice, g_openTrades[i].slPrice, g_openTrades[i].tpPrice,
                   g_openTrades[i].initRiskDist, g_openTrades[i].entryTime);

   for(int i = 0; i < ArraySize(g_pending); i++)
      WritePathRow(g_pending[i].posId, g_pending[i].isSell, "EXTENDED", bt, o, h, l, c,
                   g_pending[i].entryPrice, g_pending[i].slPrice, g_pending[i].tpPrice,
                   g_pending[i].initRiskDist, g_pending[i].entryTime);

   FileFlush(g_pathHandle);
}

//======================================================================
// MISSED-SETUP LOGGING (RC-filter opportunity cost)
//======================================================================

// CORE capture — builds one opportunity-cost record from the raw setup
// coordinates (a LUCC/LDCC reference + a closed CC + the structural SL) and a
// reason. The HYPOTHETICAL trade is "enter at the CC close, same padded stop,
// fixed-RR target"; its forward path is scanned later (FinalizeMissedSetup) so
// every non-traded setup — RC never formed, day-expired, or SKIPPED by a rule
// (bias / Daily-confirm / stop-after-win / per-episode dupe / limit cancelled
// on a Daily break) — carries the same MaxFavR / would-it-have-won measure.
void CaptureSetupOutcome(bool isSell, datetime refTime, double refHigh, double refLow,
                         datetime ccTime, double slLevel, bool rcTouched, string reason)
{
   // A "skip" reason (a rule blocked a ready setup, or a limit was cancelled on a
   // Daily break) is gated by InpLogSkippedSetups; a "missed" reason (the RC never
   // formed / day-expired / run-ended) by InpLogMissedSetups.
   bool isSkip = (StringFind(reason, "Skip") == 0) || (StringFind(reason, "Limit") == 0);
   if(isSkip  && !InpLogSkippedSetups) return;
   if(!isSkip && !InpLogMissedSetups)  return;
   if(refTime == 0 || ccTime == 0)   // only armed setups (a CC formed) qualify
      return;

   // Hypothetical entry = the CC close (the first moment a real trade could
   // have been taken had the retest requirement not existed).
   int ccShift = iBarShift(_Symbol, ENTRY_TF, ccTime, true);
   if(ccShift < 0)
      return;
   double hypoEntry = iClose(_Symbol, ENTRY_TF, ccShift);
   if(hypoEntry <= 0.0)
      return;

   // The structural stop must sit on the correct side of the CC-close entry,
   // exactly as TryOpen requires — otherwise the hypothetical trade is invalid.
   if(slLevel <= 0.0 || (isSell && slLevel <= hypoEntry) || (!isSell && slLevel >= hypoEntry))
      return;

   double origRange  = MathAbs(hypoEntry - slLevel);
   double finalRange = origRange * InpStopLossMultiplier;
   double hypoSL     = isSell ? hypoEntry + finalRange : hypoEntry - finalRange;
   double hypoTP     = isSell ? hypoEntry - finalRange * InpTakeProfitRMultiple
                              : hypoEntry + finalRange * InpTakeProfitRMultiple;

   SMissedSetup m;
   m.engine         = g_curEng;
   m.isSell         = isSell;
   m.refTime        = refTime;  m.refHigh = refHigh;  m.refLow = refLow;
   m.ccTime         = ccTime;
   m.slLevel        = slLevel;
   m.hypoEntry      = hypoEntry;
   m.hypoSL         = hypoSL;
   m.hypoTP         = hypoTP;
   m.initRiskDist   = finalRange;
   m.reason         = reason;
   m.rcLevelTouched = rcTouched;
   m.biasAllowed    = isSell ? SellBiasAllowed() : BuyBiasAllowed();
   m.dailyConfirm   = !InpUseDailyConfirmation ? true : (isSell ? DailySellConfirms() : DailyBuyConfirms());
   m.biasDir        = g_bias[g_curEng].dir;
   m.sideBiasText   = isSell ? g_bias[g_curEng].sellText : g_bias[g_curEng].buyText;
   m.dailySideText  = isSell ? Daily_SellText() : Daily_BuyText();
   m.biasCandleTime = g_bias[g_curEng].c1Time;
   m.discardTime    = TimeCurrent();
   m.trackUntil     = ccTime + (datetime)((long)InpExcursionTrackingHours * 3600);

   int n = ArraySize(g_missed);
   ArrayResize(g_missed, n + 1);
   g_missed[n] = m;
   g_missedCaptured++;
   Dbg(StringFormat("%s OPP-COST captured (%s): CC @ %s hypoEntry=%.5f hypoSL=%.5f hypoTP=%.5f touched=%s biasOK=%s (queued=%d)",
                    isSell ? "SELL" : "BUY", reason, FmtNairobi(ccTime), hypoEntry, hypoSL, hypoTP,
                    rcTouched ? "yes" : "no", m.biasAllowed ? "yes" : "no", ArraySize(g_missed)));
}

// Convenience wrapper: capture an armed setup from its live SSignalState (RC
// never formed / day-expired / run-ended). MUST be called BEFORE the state is
// wiped, so the original ref/CC/SL coordinates are still present.
void CaptureMissedSetup(bool isSell, const SSignalState &st, string reason)
{
   CaptureSetupOutcome(isSell, st.refTime, st.refHigh, st.refLow, st.ccTime, st.slLevel, st.rcLevelTouched, reason);
}

void WriteMissedHeader()
{
   if(g_missedHandle == INVALID_HANDLE)
      return;
   FileWrite(g_missedHandle,
      "MissID,Direction,EntryPattern,DiscardReason,RCLevelTouched,BiasDirection,TradeSideBiasPatterns,"
      "DailySidePatterns,BiasAllowed,DailyConfirm,BiasCandleTime,RefCandleTime,RefHigh,RefLow,CCTime,DiscardTime,BarsArmed,"
      "HypoEntry,StructuralSL,HypoSL,HypoTP,InitRiskPips,MaxFavR,MaxAdvR,"
      "Reached1R,Reached2R,Reached3R,Reached4R,ConstrainedOutcome,WouldBeWin,TimeToTP,TimeToSL,BarsScanned,TrackHours,Engine");
}

// Scans the CC's forward H1 path (up to trackUntil) and writes one row:
//  * unconstrained MaxFavR / MaxAdvR (ignores the stop — how far it ran)
//  * the R buckets it reached (1R/2R/3R/4R+)
//  * the stop-CONSTRAINED outcome under the padded SL + fixed-RR TP, scanned
//    bar-by-bar with a PESSIMISTIC SL-first rule (if a bar's range brackets
//    both levels, the stop is assumed hit first) — TP / SL / OPEN.
void FinalizeMissedSetup(const SMissedSetup &m)
{
   if(g_missedHandle == INVALID_HANDLE)
      return;

   double pip  = PipSize();
   double risk = m.initRiskDist;

   double maxFav = 0.0, maxAdv = 0.0;   // in price, relative to hypoEntry
   string outcome = "OPEN";
   datetime tpTime = 0, slTime = 0;
   int barsScanned = 0;

   int ccShift = iBarShift(_Symbol, ENTRY_TF, m.ccTime, true);
   if(ccShift < 0)
      ccShift = 0;
   // Walk bars strictly AFTER the CC bar, newest shift last. shift 0 is the
   // live bar; the bt>ccTime / bt<=trackUntil guards keep the scan in-window.
   for(int sh = ccShift - 1; sh >= 0; sh--)
   {
      datetime bt = iTime(_Symbol, ENTRY_TF, sh);
      if(bt == 0 || bt <= m.ccTime)
         continue;
      if(bt > m.trackUntil)
         break;
      double hi = iHigh(_Symbol, ENTRY_TF, sh);
      double lo = iLow(_Symbol, ENTRY_TF, sh);
      if(hi <= 0.0 || lo <= 0.0)
         continue;
      barsScanned++;

      double fav = m.isSell ? (m.hypoEntry - lo) : (hi - m.hypoEntry);   // best-case move in our favor
      double adv = m.isSell ? (m.hypoEntry - hi) : (lo - m.hypoEntry);   // worst-case move against us (<=0)
      maxFav = MathMax(maxFav, fav);
      maxAdv = MathMin(maxAdv, adv);

      if(outcome == "OPEN")
      {
         bool slHit = m.isSell ? (hi >= m.hypoSL) : (lo <= m.hypoSL);
         bool tpHit = m.isSell ? (lo <= m.hypoTP) : (hi >= m.hypoTP);
         if(slHit)      { outcome = "SL"; slTime = bt; }
         else if(tpHit) { outcome = "TP"; tpTime = bt; }
      }
   }

   double maxFavR = (risk > 0.0) ? maxFav / risk : 0.0;
   double maxAdvR = (risk > 0.0) ? maxAdv / risk : 0.0;   // negative
   bool   wouldWin = (outcome == "TP");
   if(wouldWin)
      g_missedWouldWin++;

   // How many H1 bars the setup stayed armed (CC close -> discard) before it was
   // abandoned for never producing an RC — i.e. how long the retest never came.
   int barsArmed = (m.discardTime > m.ccTime) ? (int)((long)(m.discardTime - m.ccTime) / ENTRY_TF_SECS) : 0;

   // Build the row explicitly (stable column order = WriteMissedHeader()).
   // MissID = CC bar time + side, a stable unique key per missed setup.
   string row =
        (string)m.ccTime + "-" + (m.isSell ? "S" : "B") + ","
      + (m.isSell ? "SELL" : "BUY") + ","
      + (m.isSell ? "LUCC" : "LDCC") + ","
      + m.reason + ","
      + (m.rcLevelTouched ? "1" : "0") + ","
      + CsvEscape(m.biasDir) + ","
      + CsvEscape(m.sideBiasText) + ","
      + CsvEscape(m.dailySideText) + ","
      + (m.biasAllowed ? "1" : "0") + ","
      + (m.dailyConfirm ? "1" : "0") + ","
      + FmtNairobi(m.biasCandleTime) + ","
      + FmtNairobi(m.refTime) + ","
      + DoubleToString(m.refHigh, _Digits) + ","
      + DoubleToString(m.refLow, _Digits) + ","
      + FmtNairobi(m.ccTime) + ","
      + FmtNairobi(m.discardTime) + ","
      + (string)barsArmed + ","
      + DoubleToString(m.hypoEntry, _Digits) + ","
      + DoubleToString(m.slLevel, _Digits) + ","
      + DoubleToString(m.hypoSL, _Digits) + ","
      + DoubleToString(m.hypoTP, _Digits) + ","
      + DoubleToString(pip > 0.0 ? m.initRiskDist / pip : 0.0, 1) + ","
      + DoubleToString(maxFavR, 3) + ","
      + DoubleToString(maxAdvR, 3) + ","
      + (maxFavR >= 1.0 ? "1" : "0") + ","
      + (maxFavR >= 2.0 ? "1" : "0") + ","
      + (maxFavR >= 3.0 ? "1" : "0") + ","
      + (maxFavR >= 4.0 ? "1" : "0") + ","
      + outcome + ","
      + (wouldWin ? "1" : "0") + ","
      + FmtNairobi(tpTime) + ","
      + FmtNairobi(slTime) + ","
      + (string)barsScanned + ","
      + (string)InpExcursionTrackingHours + ","
      + EngineName(m.engine);
   FileWrite(g_missedHandle, row);
   FileFlush(g_missedHandle);
}

// Finalize every queued missed setup whose forward tracking window is complete
// (its whole CC-forward path is now available). Removes finalized entries.
void ProcessMissedFinalize(bool force)
{
   if(g_missedHandle == INVALID_HANDLE)
      return;
   datetime now = TimeCurrent();
   for(int i = ArraySize(g_missed) - 1; i >= 0; i--)
   {
      if(force || now >= g_missed[i].trackUntil)
      {
         FinalizeMissedSetup(g_missed[i]);
         int last = ArraySize(g_missed) - 1;
         if(i != last)
            g_missed[i] = g_missed[last];
         ArrayResize(g_missed, last);
      }
   }
}

// The single source of truth for the column layout. FinalizePendingLog()
// builds its value array in this exact order.
void WriteTradeLogHeader()
{
   string h[] =
   {
      // --- identity / pattern taxonomy (the columns to GROUP BY) ---
      "TradeID", "Direction", "EntryPattern", "Symbol", "EntryTF", "BiasTF",
      "BiasDirection", "WeeklyBiasBuyPatterns", "WeeklyBiasSellPatterns",
      "TradeSideBiasPatterns", "BiasPatternCount", "BiasComboKey",
      "PatternSequence", "SetupQualityScore", "FiltersPassed",
      // --- timestamps ---
      "BiasCandleTime", "RefCandleTime", "CCTime", "RCTime_TouchTime",
      "EntryTime", "ExitTime", "HoldingMinutes", "CCToEntryMin", "RCToEntryMin",
      // --- prices / levels / risk geometry ---
      "RefHigh", "RefLow", "RefRange",
      "RequestedEntry", "EntryPrice", "EntrySlippagePips",
      "StructuralSL", "AdjustedSL", "SLPadPips", "TP",
      "RR_Planned", "RR_Realized", "SLDistancePips", "TPDistancePips",
      // --- market conditions at entry ---
      "BidAtEntry", "AskAtEntry", "SpreadPoints", "SpreadPips", "AtrH1AtEntry",
      "Lots", "RiskPercent", "RiskAmount",
      // --- outcome ---
      "ExitPrice", "ExitReason", "ExitType", "ProfitPips",
      "GrossProfit", "Commission", "Swap", "NetProfit",
      // --- excursions ---
      "MFE_R_InTrade", "MAE_R_InTrade", "MFE_R_Extended", "MAE_R_Extended",
      "MFE_Pips_InTrade", "MAE_Pips_InTrade",
      "HighestFloatingProfitMoney", "LargestFloatingDrawdownMoney",
      "ExcursionWindowHours", "ExcursionComplete",
      // --- calendar / session context ---
      "SessionUTC", "UTCHour", "NairobiDate", "NairobiWeekday", "NairobiHour",
      // --- account ---
      "BalanceBefore", "BalanceAfter", "Magic",
      // --- v2 research additions ---
      "Result", "HoldingHours", "MaxFavorableRR", "FinalRR",
      "BarsRefToCC", "BarsCCtoRC", "BarsRCtoEntry", "TriggerTiming", "EntryCandleTime",
      "EquityBefore",
      "WeeklyC1_Open", "WeeklyC1_High", "WeeklyC1_Low", "WeeklyC1_Close",
      "DailyPrev_Open", "DailyPrev_High", "DailyPrev_Low", "DailyPrev_Close",
      "EntryServerTime", "EntryUTCTime",
      "FirstWinOfBias", "StopAfterWinRule",
      // --- v4 breakeven additions ---
      "BEArmed", "BETriggerR", "BELockR", "BELevel",
      // --- drawdown % additions ---
      "MAE_Pct", "MaxDD_PctBalance",
      // --- v4 target-% profit lock additions ---
      "TgtLockArmed", "TgtLockTriggerPct", "TgtLockSLPct", "TgtLockLevel",
      // --- V6: entry regime / limit waiting ---
      "EntryType", "TargetSource", "PlannedRR_V6", "LimitPlacedTime", "LimitWaitBars", "LimitFilled",
      // --- V6: daily patterns + weekly x daily combos ---
      "DailyBuyPatterns", "DailySellPatterns", "DailyTradeSidePatterns", "DailyComboKey", "WeeklyDailyComboKey",
      // --- V6: breakeven timing + partial close ---
      "BEArmTime", "BarsToBE", "PartialTaken", "PartialTime", "PartialLots", "PartialPrice",
      "PartialProfit", "BarsToPartial", "PartialCloseR_Cfg",
      // --- V6: lifecycle timing / drawdown ---
      "MaxDD_Money", "SecondsInProfit", "SecondsInDrawdown", "PctTimeInProfit",
      "TimeToFirst1R_Min", "TimeToTP_Min", "MinStopLossPips_Cfg",
      // --- V6: away-from-entry (stale-entry 2R measure) ---
      "MaxAwayBeforeEntry_R", "MaxAwayBeforeEntry_Pips", "MaxAwayR_Cfg",
      // --- V7: which engine produced this trade ---
      "Engine"
   };
   g_logCols = ArraySize(h);
   WriteCsvRow(h);
}

// Queues a just-closed trade for extended tracking rather than writing it
// immediately, so MFE_R/MAE_R can keep growing past the real exit. All the
// origin/entry data comes from the frozen SOpenTrade record; mfe/maePrice
// were tracked live while the position was open, so the series is continuous.
void QueuePendingLog(const SOpenTrade &t,
                      datetime exitTime, double exitPrice, string exitReason,
                      double grossProfit, double commission, double swap,
                      bool firstWinOfBias, string outcome)
{
   int n = ArraySize(g_pending);
   ArrayResize(g_pending, n + 1);

   g_pending[n].engine             = t.engine;
   g_pending[n].isSell             = t.isSell;
   g_pending[n].posId              = t.positionId;
   g_pending[n].refTime            = t.refTime;
   g_pending[n].refHigh            = t.refHigh;
   g_pending[n].refLow             = t.refLow;
   g_pending[n].ccTime             = t.ccTime;
   g_pending[n].rcTime             = t.rcTime;
   g_pending[n].entryTime          = t.entryTime;
   g_pending[n].entryPrice         = t.entryPrice;
   g_pending[n].slPrice            = t.slPrice;
   g_pending[n].tpPrice            = t.tpPrice;
   g_pending[n].riskAmount         = t.riskAmount;
   g_pending[n].lots               = t.lots;
   g_pending[n].tradeSeqToday      = t.tradeSeqToday;
   g_pending[n].balanceBeforeEntry = t.balanceBeforeEntry;
   g_pending[n].exitTime           = exitTime;
   g_pending[n].exitPrice          = exitPrice;
   g_pending[n].exitReason         = exitReason;
   g_pending[n].grossProfit        = grossProfit;
   g_pending[n].commission         = commission;
   g_pending[n].swap               = swap;
   // t.mfePrice/maePrice are exactly as they were the instant the position
   // closed — freeze that as the true in-trade figure before extended
   // tracking carries the mfePrice/maePrice fields further past the exit.
   g_pending[n].mfePriceAtClose    = t.mfePrice;
   g_pending[n].maePriceAtClose    = t.maePrice;
   g_pending[n].mfePrice           = t.mfePrice;
   g_pending[n].maePrice           = t.maePrice;

   g_pending[n].structuralSl       = t.structuralSl;
   g_pending[n].requestedEntry     = t.requestedEntry;
   g_pending[n].bidAtEntry         = t.bidAtEntry;
   g_pending[n].askAtEntry         = t.askAtEntry;
   g_pending[n].spreadPoints       = t.spreadPoints;
   g_pending[n].atrH1AtEntry       = t.atrH1AtEntry;
   g_pending[n].biasDir            = t.biasDir;
   g_pending[n].biasBuyText        = t.biasBuyText;
   g_pending[n].biasSellText       = t.biasSellText;
   g_pending[n].sideBiasText       = t.sideBiasText;
   g_pending[n].biasCandleTime     = t.biasCandleTime;
   g_pending[n].equityBefore       = t.equityBefore;
   g_pending[n].weekO = t.weekO; g_pending[n].weekH = t.weekH;
   g_pending[n].weekL = t.weekL; g_pending[n].weekC = t.weekC;
   g_pending[n].dayO  = t.dayO;  g_pending[n].dayH  = t.dayH;
   g_pending[n].dayL  = t.dayL;  g_pending[n].dayC  = t.dayC;
   g_pending[n].firstWinOfBias = firstWinOfBias;
   g_pending[n].outcome        = outcome;          // V4: TP / LOCK / BE / LOSS (source of truth for Result)
   g_pending[n].beArmed        = t.beArmed;
   g_pending[n].beLevelPrice   = t.beLevelPrice;
   g_pending[n].initRiskDist   = t.initRiskDist;
   g_pending[n].tgtLockArmed   = t.tgtLockArmed;
   g_pending[n].tgtLockPrice   = t.tgtLockPrice;
   // --- V6 research snapshot ---
   g_pending[n].entryType       = t.entryType;
   g_pending[n].targetSource    = t.targetSource;
   g_pending[n].limitPlacedTime = t.limitPlacedTime;
   g_pending[n].plannedRR       = t.plannedRR;
   g_pending[n].dailyBuyText    = t.dailyBuyText;
   g_pending[n].dailySellText   = t.dailySellText;
   g_pending[n].dailySideText   = t.dailySideText;
   g_pending[n].beArmTime       = t.beArmTime;
   g_pending[n].partialDone     = t.partialDone;
   g_pending[n].partialTime     = t.partialTime;
   g_pending[n].partialPrice    = t.partialPrice;
   g_pending[n].partialLots     = t.partialLots;
   g_pending[n].partialProfit   = t.partialProfit;
   g_pending[n].maxDDMoney      = t.maxDDMoney;
   g_pending[n].secsInProfit    = t.secsInProfit;
   g_pending[n].secsInDraw      = t.secsInDraw;
   g_pending[n].firstFavRTime   = t.firstFavRTime;
   g_pending[n].tpHitTime       = t.tpHitTime;
   g_pending[n].maxAwayBeforeEntry = t.maxAwayBeforeEntry;

   datetime windowEnd = t.entryTime + InpExcursionTrackingHours * 3600;
   g_pending[n].trackUntil = InpEnableExcursionTracking ? MathMax(exitTime, windowEnd) : exitTime;
}

//======================================================================
// Weekly statistics — one aggregated row per calendar week, keyed by the
// broker's weekly-candle start (each trade counted in the week it was
// ENTERED). Streamed as trades finalize; the CSV is written at shutdown.
//======================================================================
struct SWeekStat
{
   int      engine;          // V7: which engine this weekly row belongs to
   datetime weekStart;
   int      trades, wins, losses, breakeven;
   double   totalR;
   int      curWin, curLoss, maxWin, maxLoss;
   int      setupsSkipped;   // setups skipped this week by the stop-after-first-win rule
};
SWeekStat g_weeks[];

datetime WeekStartOf(datetime t)
{
   int sh = iBarShift(_Symbol, PERIOD_W1, t, false);
   return (sh < 0) ? 0 : iTime(_Symbol, PERIOD_W1, sh);
}

// V7: weekly buckets are keyed by (engine, weekStart) so each engine keeps its
// own weekly statistics. Calendar-week bucketing is shared for readability; the
// authoritative per-engine stats are the per-trade CSV rows (Engine column).
int WeekBucketIndex(int eng, datetime weekStart)
{
   for(int i = 0; i < ArraySize(g_weeks); i++)
      if(g_weeks[i].engine == eng && g_weeks[i].weekStart == weekStart)
         return i;
   int idx = ArraySize(g_weeks);
   ArrayResize(g_weeks, idx + 1);
   g_weeks[idx].engine = eng;
   g_weeks[idx].weekStart = weekStart;
   g_weeks[idx].trades = 0; g_weeks[idx].wins = 0; g_weeks[idx].losses = 0; g_weeks[idx].breakeven = 0;
   g_weeks[idx].totalR = 0; g_weeks[idx].curWin = 0; g_weeks[idx].curLoss = 0;
   g_weeks[idx].maxWin = 0; g_weeks[idx].maxLoss = 0; g_weeks[idx].setupsSkipped = 0;
   return idx;
}

// A setup was skipped by the stop-after-first-win rule — tally it into the
// week it occurred in, for the engine that skipped it.
void RecordWeeklySkip(int eng, datetime whenServerTime)
{
   int idx = WeekBucketIndex(eng, WeekStartOf(whenServerTime));
   g_weeks[idx].setupsSkipped++;
}

void UpdateWeeklyStats(int eng, datetime entryTime, double rRealized, string outcome)
{
   int idx = WeekBucketIndex(eng, WeekStartOf(entryTime));
   g_weeks[idx].trades++;
   g_weeks[idx].totalR += rRealized;
   // V4: bucket by the price-based outcome. TP and a target-% LOCK are both
   // profitable trades -> counted as wins for the weekly win-rate/streaks. A BE
   // exit (with a possible small +swap) is breakeven, never a win, and resets
   // both streak counters, exactly like the old flat-net breakeven case.
   if(outcome == "TP" || outcome == "LOCK")
   {
      g_weeks[idx].wins++; g_weeks[idx].curWin++; g_weeks[idx].curLoss = 0;
      if(g_weeks[idx].curWin > g_weeks[idx].maxWin) g_weeks[idx].maxWin = g_weeks[idx].curWin;
   }
   else if(outcome == "LOSS")
   {
      g_weeks[idx].losses++; g_weeks[idx].curLoss++; g_weeks[idx].curWin = 0;
      if(g_weeks[idx].curLoss > g_weeks[idx].maxLoss) g_weeks[idx].maxLoss = g_weeks[idx].curLoss;
   }
   else
   {
      g_weeks[idx].breakeven++; g_weeks[idx].curWin = 0; g_weeks[idx].curLoss = 0;
   }
}

void WriteWeeklyStats()
{
   int n = ArraySize(g_weeks);
   for(int i = 1; i < n; i++)   // insertion sort by weekStart (few rows)
   {
      SWeekStat key = g_weeks[i];
      int j = i - 1;
      while(j >= 0 && g_weeks[j].weekStart > key.weekStart) { g_weeks[j + 1] = g_weeks[j]; j--; }
      g_weeks[j + 1] = key;
   }

   int h = FileOpen(InpWeeklyStatsFileName, FileFlagsCsv(), ',');
   if(h == INVALID_HANDLE)
   {
      PrintFormat("LUCC/LDCC EA: could not open weekly-stats '%s', error=%d", InpWeeklyStatsFileName, GetLastError());
      return;
   }
   FileWrite(h, "Engine,WeekStart,Trades,Wins,Losses,Breakeven,WinRatePct,TotalR,AvgR,MaxConsecWins,MaxConsecLosses,SetupsSkippedAfterWin,StopAfterWinRule");
   for(int i = 0; i < n; i++)
   {
      double winRate = (g_weeks[i].trades > 0) ? 100.0 * g_weeks[i].wins / g_weeks[i].trades : 0.0;
      double avgR    = (g_weeks[i].trades > 0) ? g_weeks[i].totalR / g_weeks[i].trades : 0.0;
      FileWrite(h, StringFormat("%s,%s,%d,%d,%d,%d,%.1f,%.3f,%.3f,%d,%d,%d,%s",
                EngineName(g_weeks[i].engine),
                TimeToString(GetNairobiTime(g_weeks[i].weekStart), TIME_DATE),
                g_weeks[i].trades, g_weeks[i].wins, g_weeks[i].losses, g_weeks[i].breakeven,
                winRate, g_weeks[i].totalR, avgR, g_weeks[i].maxWin, g_weeks[i].maxLoss,
                g_weeks[i].setupsSkipped, InpStopAfterFirstWin ? "ON" : "OFF"));
   }
   FileClose(h);
   PrintFormat("LUCC/LDCC EA: wrote %d weekly-stat rows -> %s", n, FullFilePath(InpWeeklyStatsFileName));
}

void FinalizePendingLog(const SPendingLog &p, bool windowComplete)
{
   if(g_logHandle == INVALID_HANDLE)
      return;

   double point     = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double pip       = PipSize();
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE) > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE) : 0.0;
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   double netProfit    = p.grossProfit + p.commission + p.swap;
   double riskDistance = MathAbs(p.entryPrice - p.slPrice);
   double rRealized    = (p.riskAmount > 0) ? netProfit / p.riskAmount : 0.0;

   // In-trade: excursion while the real position was actually open — the only
   // valid basis for "what R would a breakeven / trailing rule have triggered
   // on". Extended: keeps tracking past the real exit, for "how far could
   // price have run" / target-selection questions only.
   double mfeRInTrade  = (riskDistance > 0) ? MathAbs(p.entryPrice - p.mfePriceAtClose) / riskDistance : 0.0;
   double maeRInTrade  = (riskDistance > 0) ? MathAbs(p.entryPrice - p.maePriceAtClose) / riskDistance : 0.0;
   double mfeRExtended = (riskDistance > 0) ? MathAbs(p.entryPrice - p.mfePrice) / riskDistance : 0.0;
   double maeRExtended = (riskDistance > 0) ? MathAbs(p.entryPrice - p.maePrice) / riskDistance : 0.0;

   double mfePipsInTrade = (pip > 0) ? MathAbs(p.entryPrice - p.mfePriceAtClose) / pip : 0.0;
   double maePipsInTrade = (pip > 0) ? MathAbs(p.entryPrice - p.maePriceAtClose) / pip : 0.0;
   double floatProfitMoney = (tickSize > 0) ? MathAbs(p.entryPrice - p.mfePriceAtClose) / tickSize * tickValue * p.lots : 0.0;
   double floatDrawdownMoney = (tickSize > 0) ? MathAbs(p.entryPrice - p.maePriceAtClose) / tickSize * tickValue * p.lots : 0.0;

   double holdingMinutes = (double)(p.exitTime - p.entryTime) / 60.0;
   double ccToEntryMin   = (p.ccTime > 0) ? (double)(p.entryTime - p.ccTime) / 60.0 : 0.0;
   double rcToEntryMin   = (p.rcTime > 0) ? (double)(p.entryTime - p.rcTime) / 60.0 : 0.0;
   double balanceAfter   = p.balanceBeforeEntry + netProfit;

   double refRange       = p.refHigh - p.refLow;
   double slippagePips   = (pip > 0) ? (p.entryPrice - p.requestedEntry) / pip : 0.0;
   double slPadPips      = (pip > 0) ? MathAbs(p.slPrice - p.structuralSl) / pip : 0.0;
   double slDistPips     = (pip > 0) ? MathAbs(p.entryPrice - p.slPrice) / pip : 0.0;
   double tpDistPips     = (pip > 0) ? MathAbs(p.entryPrice - p.tpPrice) / pip : 0.0;
   // V5: the planned RR now varies per trade (target fixation 2.5..4R), so derive
   // it from the actual entry/SL/TP geometry instead of the fixed input multiple.
   double slDistPrice    = MathAbs(p.entryPrice - p.slPrice);
   double rrPlanned      = (slDistPrice > 0.0) ? MathAbs(p.tpPrice - p.entryPrice) / slDistPrice : InpTakeProfitRMultiple;
   double spreadPips     = (pip > 0) ? (p.askAtEntry - p.bidAtEntry) / pip : 0.0;
   double profitPips     = (pip > 0) ? (p.isSell ? (p.entryPrice - p.exitPrice) : (p.exitPrice - p.entryPrice)) / pip : 0.0;

   // Derived exit classification, independent of the broker's deal comment.
   // V4: recognise the breakeven exit (SL parked at entry) before the original
   // stop, so a BE close is tagged BE, not OTHER/SL.
   string exitType;
   double exitTol = MathMax(2 * point, riskDistance * 0.10);
   if(MathAbs(p.exitPrice - p.tpPrice) <= exitTol)                                  exitType = "TP";
   else if(p.tgtLockArmed && MathAbs(p.exitPrice - p.tgtLockPrice) <= exitTol)      exitType = "LOCK";
   else if(p.beArmed && MathAbs(p.exitPrice - p.beLevelPrice) <= exitTol)           exitType = "BE";
   else if(MathAbs(p.exitPrice - p.slPrice) <= exitTol)                             exitType = "SL";
   else                                                                             exitType = "OTHER";

   string entryPattern   = p.isSell ? "LUCC" : "LDCC";
   string sideCombo      = ComboKey(p.sideBiasText);
   int    biasCount      = PatternCount(p.sideBiasText);
   string patternSeq     = "WK[" + sideCombo + "]>" + entryPattern + ">CC>RC";
   // Every gate that had to pass for this trade to exist (all true by
   // construction — recorded so a future filter change is auditable).
   string filtersPassed  = "position_free;not_done_today;under_2_today;no_session_gate;bias_allowed;sl_valid;min_stop_ok";

   // --- v2 additions: timing, result, and context ---
   double   holdingHours  = holdingMinutes / 60.0;
   int      barsRefToCC   = (p.refTime > 0 && p.ccTime > 0) ? (int)MathRound((double)(p.ccTime - p.refTime) / (double)ENTRY_TF_SECS) : 0;
   int      barsCcToRc    = (p.ccTime > 0 && p.rcTime > 0)  ? (int)MathRound((double)(p.rcTime - p.ccTime) / (double)ENTRY_TF_SECS) : 0;
   int      barsRcToEntry = (p.rcTime > 0) ? (int)MathRound((double)(p.entryTime - p.rcTime) / (double)ENTRY_TF_SECS) : 0;
   // "IMMEDIATE" = retest on the first bar after the CC; "WAITED" = it took longer.
   string   triggerTiming = (barsCcToRc <= 1) ? "IMMEDIATE" : "WAITED";
   int      entryShift    = iBarShift(_Symbol, ENTRY_TF, p.entryTime, false);
   datetime entryCandle   = (entryShift < 0) ? p.entryTime : iTime(_Symbol, ENTRY_TF, entryShift);
   // V4: Result comes from the price-based outcome — TP is the only WIN; a BE
   // stop is BE (not a win) even if a +swap left netProfit slightly positive.
   // V4: Result is the price-based outcome. A full TP is WIN; a target-% lock exit
   // is its own LOCK label (a real profit, distinct from a full TP); BE is BE.
   string   result        = (p.outcome == "TP")   ? "WIN"  :
                            (p.outcome == "LOCK") ? "LOCK" :
                            (p.outcome == "BE")   ? "BE"   : "LOSS";

   datetime nairobiEntry = GetNairobiTime(p.entryTime);
   datetime utcEntry     = GetUtcTime(p.entryTime);
   MqlDateTime dt, du;
   TimeToStruct(nairobiEntry, dt);
   TimeToStruct(utcEntry, du);
   string weekdayNames[7] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   string nairobiDate = StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day);

   // --- V6 derived research fields ---
   string dailyCombo    = ComboKey(p.dailySideText);
   string wdCombo       = ComboKey(p.sideBiasText) + "|" + dailyCombo;   // Weekly x Daily combination key
   int    limitWaitBars = (p.limitPlacedTime > 0 && p.entryTime > p.limitPlacedTime)
                          ? (int)((long)(p.entryTime - p.limitPlacedTime) / ENTRY_TF_SECS) : 0;
   int    barsToBE      = (p.beArmTime > 0 && p.beArmTime > p.entryTime)
                          ? (int)((long)(p.beArmTime - p.entryTime) / ENTRY_TF_SECS) : -1;
   int    barsToPartial = (p.partialDone && p.partialTime > p.entryTime)
                          ? (int)((long)(p.partialTime - p.entryTime) / ENTRY_TF_SECS) : -1;
   long   secsLive      = p.secsInProfit + p.secsInDraw;
   double pctInProfit   = (secsLive > 0) ? (double)p.secsInProfit / (double)secsLive * 100.0 : 0.0;
   double timeTo1RMin   = (p.firstFavRTime > 0 && p.firstFavRTime >= p.entryTime)
                          ? (double)(p.firstFavRTime - p.entryTime) / 60.0 : -1.0;
   double timeToTPMin   = (p.tpHitTime > 0 && p.tpHitTime >= p.entryTime)
                          ? (double)(p.tpHitTime - p.entryTime) / 60.0 : -1.0;
   double awayBeforeR   = (riskDistance > 0.0) ? p.maxAwayBeforeEntry / riskDistance : 0.0;
   double awayBeforePips = (pip > 0.0) ? p.maxAwayBeforeEntry / pip : 0.0;

   string v[] =
   {
      // identity / pattern taxonomy
      (string)p.posId, p.isSell ? "SELL" : "BUY", entryPattern, _Symbol, "H1", "W1",
      p.biasDir, CsvEscape(p.biasBuyText), CsvEscape(p.biasSellText),
      CsvEscape(p.sideBiasText), (string)biasCount, sideCombo,
      patternSeq, (string)biasCount, filtersPassed,
      // timestamps — all in Africa/Nairobi so they match TradingView
      FmtNairobi(p.biasCandleTime), FmtNairobi(p.refTime), FmtNairobi(p.ccTime), FmtNairobi(p.rcTime),
      FmtNairobi(p.entryTime), FmtNairobi(p.exitTime),
      DoubleToString(holdingMinutes, 1), DoubleToString(ccToEntryMin, 1), DoubleToString(rcToEntryMin, 1),
      // prices / levels / risk geometry
      DoubleToString(p.refHigh, _Digits), DoubleToString(p.refLow, _Digits), DoubleToString(refRange, _Digits),
      DoubleToString(p.requestedEntry, _Digits), DoubleToString(p.entryPrice, _Digits), DoubleToString(slippagePips, 2),
      DoubleToString(p.structuralSl, _Digits), DoubleToString(p.slPrice, _Digits), DoubleToString(slPadPips, 2), DoubleToString(p.tpPrice, _Digits),
      DoubleToString(rrPlanned, 2), DoubleToString(rRealized, 3), DoubleToString(slDistPips, 2), DoubleToString(tpDistPips, 2),
      // market conditions at entry
      DoubleToString(p.bidAtEntry, _Digits), DoubleToString(p.askAtEntry, _Digits),
      DoubleToString(p.spreadPoints, 1), DoubleToString(spreadPips, 2), DoubleToString(p.atrH1AtEntry, _Digits),
      DoubleToString(p.lots, 2), DoubleToString(InpRiskPercent, 2), DoubleToString(p.riskAmount, 2),
      // outcome
      DoubleToString(p.exitPrice, _Digits), CsvEscape(p.exitReason), exitType, DoubleToString(profitPips, 1),
      DoubleToString(p.grossProfit, 2), DoubleToString(p.commission, 2), DoubleToString(p.swap, 2), DoubleToString(netProfit, 2),
      // excursions
      DoubleToString(mfeRInTrade, 3), DoubleToString(maeRInTrade, 3), DoubleToString(mfeRExtended, 3), DoubleToString(maeRExtended, 3),
      DoubleToString(mfePipsInTrade, 1), DoubleToString(maePipsInTrade, 1),
      DoubleToString(floatProfitMoney, 2), DoubleToString(floatDrawdownMoney, 2),
      (string)InpExcursionTrackingHours, windowComplete ? "true" : "false",
      // calendar / session context
      SessionNameUtc(utcEntry), (string)du.hour, nairobiDate, weekdayNames[dt.day_of_week], (string)dt.hour,
      // account
      DoubleToString(p.balanceBeforeEntry, 2), DoubleToString(balanceAfter, 2), (string)InpMagicNumber,
      // --- v2 research additions ---
      result, DoubleToString(holdingHours, 2),
      DoubleToString(mfeRInTrade, 3), DoubleToString(rRealized, 3),
      (string)barsRefToCC, (string)barsCcToRc, (string)barsRcToEntry, triggerTiming, FmtNairobi(entryCandle),
      DoubleToString(p.equityBefore, 2),
      DoubleToString(p.weekO, _Digits), DoubleToString(p.weekH, _Digits), DoubleToString(p.weekL, _Digits), DoubleToString(p.weekC, _Digits),
      DoubleToString(p.dayO, _Digits),  DoubleToString(p.dayH, _Digits),  DoubleToString(p.dayL, _Digits),  DoubleToString(p.dayC, _Digits),
      FmtTime(p.entryTime), FmtTime(utcEntry),
      p.firstWinOfBias ? "true" : "false", InpStopAfterFirstWin ? "ON" : "OFF",
      // --- v4 breakeven additions ---
      p.beArmed ? "true" : "false", DoubleToString(InpBreakevenTriggerR, 2),
      DoubleToString(InpBreakevenLockR, 2), DoubleToString(p.beLevelPrice, _Digits),
      // --- drawdown % additions ---
      DoubleToString(p.entryPrice > 0 ? maePipsInTrade * pip / p.entryPrice * 100.0 : 0.0, 3),
      DoubleToString(p.balanceBeforeEntry > 0 ? floatDrawdownMoney / p.balanceBeforeEntry * 100.0 : 0.0, 3),
      // --- v4 target-% profit lock additions ---
      p.tgtLockArmed ? "true" : "false", DoubleToString(InpTargetLockTriggerPct, 1),
      DoubleToString(InpTargetLockSLPct, 1), DoubleToString(p.tgtLockPrice, _Digits),
      // --- V6: entry regime / limit waiting ---
      p.entryType, CsvEscape(p.targetSource), DoubleToString(p.plannedRR, 2),
      (p.limitPlacedTime > 0 ? FmtNairobi(p.limitPlacedTime) : ""), (string)limitWaitBars,
      (p.entryType == "LIMIT" ? "true" : "false"),
      // --- V6: daily patterns + weekly x daily combos ---
      CsvEscape(p.dailyBuyText), CsvEscape(p.dailySellText), CsvEscape(p.dailySideText),
      dailyCombo, wdCombo,
      // --- V6: breakeven timing + partial close ---
      (p.beArmTime > 0 ? FmtNairobi(p.beArmTime) : ""), (string)barsToBE,
      p.partialDone ? "true" : "false",
      (p.partialTime > 0 ? FmtNairobi(p.partialTime) : ""),
      DoubleToString(p.partialLots, 2), DoubleToString(p.partialPrice, _Digits),
      DoubleToString(p.partialProfit, 2), (string)barsToPartial, DoubleToString(InpPartialCloseR, 2),
      // --- V6: lifecycle timing / drawdown ---
      DoubleToString(p.maxDDMoney, 2), (string)p.secsInProfit, (string)p.secsInDraw, DoubleToString(pctInProfit, 1),
      DoubleToString(timeTo1RMin, 1), DoubleToString(timeToTPMin, 1), DoubleToString(InpMinStopLossPips, 1),
      // --- V6: away-from-entry (stale-entry 2R measure) ---
      DoubleToString(awayBeforeR, 3), DoubleToString(awayBeforePips, 1), DoubleToString(InpMaxAwayR, 2),
      // --- V7: engine identity ---
      EngineName(p.engine)
   };

   if(g_logCols > 0 && ArraySize(v) != g_logCols)
      PrintFormat("LUCC/LDCC EA: trade-log column mismatch (header=%d, row=%d) — check FinalizePendingLog.",
                  g_logCols, ArraySize(v));

   WriteCsvRow(v);
   UpdateWeeklyStats(p.engine, p.entryTime, rRealized, p.outcome);
}

// Called every tick: extends MFE/MAE for every trade still in its tracking
// window, and finalizes (writes + dequeues) any whose window has elapsed.
void UpdatePendingExcursions(double bid, double ask)
{
   for(int i = ArraySize(g_pending) - 1; i >= 0; i--)
   {
      if(g_pending[i].isSell)
      {
         g_pending[i].mfePrice = MathMin(g_pending[i].mfePrice, bid);
         g_pending[i].maePrice = MathMax(g_pending[i].maePrice, ask);
      }
      else
      {
         g_pending[i].mfePrice = MathMax(g_pending[i].mfePrice, ask);
         g_pending[i].maePrice = MathMin(g_pending[i].maePrice, bid);
      }

      if(TimeCurrent() >= g_pending[i].trackUntil)
      {
         if(InpEnableTradeLog)
            FinalizePendingLog(g_pending[i], true);
         ArrayRemove(g_pending, i, 1);
      }
   }
}

//+------------------------------------------------------------------+
//| An open position just closed — find it in g_openTrades by position |
//| id, book the outcome, queue the journal row, and remove it. Works  |
//| for any of the (possibly several) concurrently open trades.        |
//| "Win" = closed net profit (profit + swap + commission) > 0.        |
//+------------------------------------------------------------------+
void HandleClose(long closedPosId, datetime exitTime, double exitPrice, string exitReason,
                 double grossProfit, double commission, double swap)
{
   int idx = -1;
   for(int i = 0; i < ArraySize(g_openTrades); i++)
      if(g_openTrades[i].positionId == closedPosId) { idx = i; break; }
   if(idx < 0)
      return; // not one of ours (or already handled)

   // V6: a PARTIAL close (the +2R runner-split) leaves the position OPEN with a
   // reduced volume. Detect it — if the position still exists after this out-deal
   // it was the partial: bank its realized P&L into the trade record and return,
   // WITHOUT booking the outcome or removing the trade. The final close (position
   // gone) folds that partial P&L into the trade's total below.
   if(PositionSelectByTicket((ulong)closedPosId))
   {
      g_openTrades[idx].partialProfit += grossProfit;
      g_openTrades[idx].partialComm   += commission;
      g_openTrades[idx].partialSwap   += swap;
      if(g_openTrades[idx].partialTime == 0) g_openTrades[idx].partialTime = exitTime;
      Dbg(StringFormat("%s PARTIAL booked posId=%d partGross=%.2f (position still open, %.2f lots remain)",
                       g_openTrades[idx].isSell ? "SELL" : "BUY", closedPosId, grossProfit,
                       PositionGetDouble(POSITION_VOLUME)));
      return;
   }

   SOpenTrade t = g_openTrades[idx];
   // Fold any earlier partial-close realized P&L into this final close so the
   // journal's NetProfit / RR_Realized reflect the WHOLE trade, not just the runner.
   grossProfit += t.partialProfit;
   commission  += t.partialComm;
   swap        += t.partialSwap;
   double netProfit = grossProfit + commission + swap;

   // V4: outcome is decided by the EXIT PRICE, not the sign of net profit.
   //   TP   -> a full take-profit: books the episode win + the daily/weekly win-stops.
   //   LOCK -> stopped at the target-% profit lock: a real profit, but NOT a full TP.
   //           By default it does NOT arm the stop-after-win rule (toggle to include),
   //           so the EA keeps taking new valid setups under the SAME weekly bias.
   //   BE   -> breakeven: NEITHER win nor loss. Books nothing.
   //   LOSS -> hit the original stop. (Losses never stopped the direction.)
   string outcome = ClassifyOutcome(t, exitPrice);
   // A LOCK exit activates the weekly-bias win-stop only if explicitly opted in.
   bool   winStop = (outcome == "TP") || (outcome == "LOCK" && InpTargetLockCountsAsWin);

   // First win of THIS trade's weekly-bias episode? Tracked on a win-stop event
   // (a full TP, or a lock exit when the toggle counts it) so the "first winning
   // trade" is identifiable. The episode is the trade's own weekly-bias candle,
   // so each week is an independent instance and the restriction resets per bias.
   bool firstWin = false;
   if(winStop)
   {
      if(!HasWinEpisode(t.engine, t.isSell, t.episode))
      {
         firstWin = true;
         AddWinEpisode(t.engine, t.isSell, t.episode);
      }
      // daily win-stop — booked to THIS trade's own engine only
      if(t.isSell) g_sell[t.engine].doneToday = true; else g_buy[t.engine].doneToday = true;
   }

   Dbg(StringFormat("%s CLOSE posId=%d net=%.2f outcome=%s%s%s%s episode=%s (openTrades left=%d)",
                    t.isSell ? "SELL" : "BUY", closedPosId, netProfit, outcome,
                    t.tgtLockArmed ? " [LOCK-armed]" : "", t.beArmed ? " [BE-armed]" : "",
                    firstWin ? " [FIRST-WIN]" : "",
                    TimeToString(GetNairobiTime(t.episode), TIME_DATE),
                    ArraySize(g_openTrades) - 1));

   if(InpEnableTradeLog)
      QueuePendingLog(t, exitTime, exitPrice, exitReason, grossProfit, commission, swap, firstWin, outcome);

   ArrayRemove(g_openTrades, idx, 1);
}

//======================================================================
// On-chart info panel — a compact live readout of the Bias state, each
// side's LUCC/LDCC setup progress, the daily trade counters and the risk/
// TP configuration. Purely informational; it never influences trading.
//======================================================================
#define PANEL_PREFIX "LUCC_LDCC_Panel_"
#define PANEL_ROWS   12

int PanelRowY(int row)
{
   return InpPanelY + 8 + row * (InpPanelFontSize + 8);
}

void PanelEnsureBackground()
{
   string name = PANEL_PREFIX + "BG";
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, InpPanelY);
      ObjectSetInteger(0, name, OBJPROP_XSIZE, 360);
      ObjectSetInteger(0, name, OBJPROP_YSIZE, PANEL_ROWS * (InpPanelFontSize + 8) + 12);
      ObjectSetInteger(0, name, OBJPROP_BGCOLOR, InpPanelBackColor);
      ObjectSetInteger(0, name, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, name, OBJPROP_COLOR, C'60,60,70');
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }
}

void PanelSet(int row, string text, color clr)
{
   string name = PANEL_PREFIX + "R" + (string)row;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, InpPanelX + 10);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, PanelRowY(row));
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, InpPanelFontSize);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
   }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
}

string SideStateText(int eng, bool isSell, const SSignalState &st)
{
   string tag = isSell ? "LUCC" : "LDCC";
   int openN = OpenTradeCount(eng, isSell);
   string openTag = (openN > 0) ? StringFormat(" [%d open]", openN) : "";
   if(st.refTime == 0) return "scanning - no " + tag + openTag;
   if(st.refTime == st.expiredRefTime) return "pending EXPIRED - awaiting a new " + tag + openTag;
   if(st.ccTime  == 0) return tag + " @ " + TimeToString(GetNairobiTime(st.refTime), TIME_DATE|TIME_MINUTES) + " (awaiting CC)" + openTag;
   double lvl = isSell ? st.refLow : st.refHigh;
   return "CC set - awaiting retest @ " + DoubleToString(lvl, _Digits) + openTag;
}

void UpdatePanel()
{
   if(!InpShowPanel)
      return;

   PanelEnsureBackground();

   // Panel shows Engine 1 (1W->1D) live state; Engine 2 (2W->2D) runs in parallel
   // and is captured in the logs (Engine column). Cosmetic only — skipped in optimization.
   g_curEng = ENG_1W1D;

   PanelSet(0, "LUCC / LDCC dual-engine EA (V7: 1W-1D + 2W-2D)", clrDeepSkyBlue);

   MqlDateTime nd; TimeToStruct(GetNairobiTime(TimeCurrent()), nd);
   PanelSet(1, StringFormat("Nairobi %02d:%02d   |   24/5 - no time filter", nd.hour, nd.min), clrLime);

   color dirClr = g_bias[g_curEng].dir == "BUY"  ? clrLime :
                  g_bias[g_curEng].dir == "SELL" ? clrRed  :
                  g_bias[g_curEng].dir == "BOTH" ? clrOrange : clrSilver;
   PanelSet(2, "1W Bias: " + g_bias[g_curEng].dir, dirClr);

   string buyStat  = !g_bias[g_curEng].buyPresent  ? "-" : (g_bias[g_curEng].buyInvalid  ? "INVALIDATED" : "ACTIVE");
   color  buyClr   = !g_bias[g_curEng].buyPresent  ? clrSilver : (g_bias[g_curEng].buyInvalid  ? clrOrangeRed : clrLime);
   string sellStat = !g_bias[g_curEng].sellPresent ? "-" : (g_bias[g_curEng].sellInvalid ? "INVALIDATED" : "ACTIVE");
   color  sellClr  = !g_bias[g_curEng].sellPresent ? clrSilver : (g_bias[g_curEng].sellInvalid ? clrOrangeRed : clrRed);
   PanelSet(3, StringFormat("Buy  bias: %-10s [%s]", g_bias[g_curEng].buyText,  buyStat),  buyClr);
   PanelSet(4, StringFormat("Sell bias: %-10s [%s]", g_bias[g_curEng].sellText, sellStat), sellClr);

   PanelSet(5, InpUseBiasFilter ? "Bias gate: ENFORCED" : "Bias gate: OFF (all entries)",
            InpUseBiasFilter ? clrGold : clrSilver);

   PanelSet(6, "SELL (LUCC): " + SideStateText(ENG_1W1D, true, g_sell[ENG_1W1D]),
            HasOpenTrade(ENG_1W1D, true) ? clrRed : clrGainsboro);
   bool sellWinLock = InpStopAfterFirstWin && HasWinEpisode(ENG_1W1D, true, g_bias[g_curEng].c1Time);
   PanelSet(7, StringFormat("   trades today %d/2%s   bias %s%s",
            g_sell[ENG_1W1D].tradesToday, g_sell[ENG_1W1D].doneToday ? " (done)" : "",
            SellBiasAllowed() ? "OK" : "blocked", sellWinLock ? "  [WK-WIN-LOCK]" : ""),
            sellWinLock ? clrGold : (SellBiasAllowed() ? clrGainsboro : clrGray));

   PanelSet(8, "BUY (LDCC): " + SideStateText(ENG_1W1D, false, g_buy[ENG_1W1D]),
            HasOpenTrade(ENG_1W1D, false) ? clrLime : clrGainsboro);
   bool buyWinLock = InpStopAfterFirstWin && HasWinEpisode(ENG_1W1D, false, g_bias[g_curEng].c1Time);
   PanelSet(9, StringFormat("   trades today %d/2%s   bias %s%s",
            g_buy[ENG_1W1D].tradesToday, g_buy[ENG_1W1D].doneToday ? " (done)" : "",
            BuyBiasAllowed() ? "OK" : "blocked", buyWinLock ? "  [WK-WIN-LOCK]" : ""),
            buyWinLock ? clrGold : (BuyBiasAllowed() ? clrGainsboro : clrGray));

   PanelSet(10, StringFormat("TP 1:%.1f | SLx%.2f | BE %s@%.2fR | Lock %s %.0f%%->%.0f%%",
            InpTakeProfitRMultiple, InpStopLossMultiplier,
            InpUseBreakeven ? "ON" : "OFF", InpBreakevenTriggerR,
            InpUseTargetLock ? "ON" : "OFF", InpTargetLockTriggerPct, InpTargetLockSLPct), clrGainsboro);

   PanelSet(11, StringFormat("Risk %.2f%% of %.2f = %.2f",
            InpRiskPercent, g_riskBalance, g_riskBalance * InpRiskPercent / 100.0), clrGainsboro);

   // Without this the panel text does not reliably repaint between ticks in the
   // Strategy Tester visualization, so it can look frozen (e.g. Session stuck
   // on one value) even though the underlying state is updating every tick.
   ChartRedraw();
}

void DestroyPanel()
{
   ObjectsDeleteAll(0, PANEL_PREFIX);
}

//======================================================================
// Event handlers
//======================================================================
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   // Resolve the broker->Nairobi offset FIRST so every logged timestamp is in
   // Africa/Nairobi. (Auto-detect may defer until the first tick if TimeGMT()
   // isn't ready yet; the manual input is used as the fallback until then.)
   g_brokerStdOffsetHours = InpBrokerGmtOffsetHours;
   g_brokerOffsetResolved = false;
   ResolveBrokerOffset();

   // H1 ATR(14) handle — logged as volatility context on every entry.
   g_atrHandle = iATR(_Symbol, PERIOD_H1, 14);
   if(g_atrHandle == INVALID_HANDLE)
      PrintFormat("LUCC/LDCC EA: could not create H1 ATR handle, error=%d (ATR will log as 0).", GetLastError());

   g_lastBarTime  = 0;
   g_lastResetDay = 0;
   g_prevMid      = 0.0;
   g_havePrevMid  = false;

   // V7: initialise BOTH engines' bias state.
   for(int e = 0; e < NUM_ENGINES; e++)
   {
      g_bias[e].c1Time      = 0;
      g_bias[e].buyInvalid  = false;
      g_bias[e].sellInvalid = false;
      g_bias[e].dir         = "NONE";
      g_bias[e].buyText     = "-";
      g_bias[e].sellText    = "-";
      g_bias[e].buyPresent  = false;
      g_bias[e].sellPresent = false;
   }

   // Freeze the risk-sizing reference balance once, here, so it can never
   // drift with wins/losses (no compounding). InpFixedRiskBalance = 0 means
   // "use whatever the account balance is right now, at EA start."
   g_riskBalance = (InpFixedRiskBalance > 0) ? InpFixedRiskBalance : AccountInfoDouble(ACCOUNT_BALANCE);

   if(InpEnableTradeLog)
   {
      g_logHandle = FileOpen(InpTradeLogFileName, FileFlagsCsv(), ',');
      if(g_logHandle == INVALID_HANDLE)
         PrintFormat("LUCC/LDCC EA: could not open trade log '%s', error=%d", InpTradeLogFileName, GetLastError());
      else
      {
         WriteTradeLogHeader();
         Print("LUCC/LDCC EA: TRADE LOG -> ", FullFilePath(InpTradeLogFileName));
         Print("LUCC/LDCC EA: WEEKLY STATS -> ", FullFilePath(InpWeeklyStatsFileName), "  (written at end of run)");
      }

      if(InpEnablePathLog)
      {
         g_pathHandle = FileOpen(InpPathLogFileName, FileFlagsCsv(), ',');
         if(g_pathHandle == INVALID_HANDLE)
            PrintFormat("LUCC/LDCC EA: could not open path log '%s', error=%d", InpPathLogFileName, GetLastError());
         else
         {
            WritePathHeader();
            Print("LUCC/LDCC EA: PATH LOG -> ", FullFilePath(InpPathLogFileName));
         }
      }

      if(InpLogMissedSetups || InpLogSkippedSetups)
      {
         g_missedHandle = FileOpen(InpMissedLogFileName, FileFlagsCsv(), ',');
         if(g_missedHandle == INVALID_HANDLE)
            PrintFormat("LUCC/LDCC EA: could not open missed-setup log '%s', error=%d", InpMissedLogFileName, GetLastError());
         else
         {
            WriteMissedHeader();
            Print("LUCC/LDCC EA: MISSED/SKIPPED-SETUP (opportunity-cost) LOG -> ", FullFilePath(InpMissedLogFileName));
         }
      }
   }

   // One-shot config snapshot so the current filter setup is always visible at
   // the top of the Experts log — the first thing to check when diagnosing.
   MqlDateTime nd; TimeToStruct(GetNairobiTime(TimeCurrent()), nd);
   Dbg(StringFormat("INIT %s digits=%d point=%.5f pip=%.5f | serverNow=%s NairobiNow=%02d:%02d | 24/5 no time filter",
                    _Symbol, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS),
                    SymbolInfoDouble(_Symbol, SYMBOL_POINT), PipSize(),
                    TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), nd.hour, nd.min));
   Dbg(StringFormat("INIT filters: SessionGate=NONE(24/5)  BiasFilter=%s  BarCloseRetest=%s  Lookback=%d | H1bars=%d W1bars=%d riskBal=%.2f",
                    InpUseBiasFilter ? "ON" : "OFF", InpUseBarCloseRetest ? "ON" : "OFF", LOOKBACK,
                    iBars(_Symbol, PERIOD_H1), iBars(_Symbol, PERIOD_W1), g_riskBalance));
   Dbg(StringFormat("INIT V4 breakeven: %s  trigger=%.2fR  lock=%.2fR  (SL moves to entry once floating profit hits the trigger; a BE stop = neither win nor loss)",
                    InpUseBreakeven ? "ON" : "OFF", InpBreakevenTriggerR, InpBreakevenLockR));
   if(InpUseBreakeven && InpBreakevenLockR >= InpBreakevenTriggerR)
      PrintFormat("LUCC/LDCC EA V4 WARNING: InpBreakevenLockR (%.2f) >= InpBreakevenTriggerR (%.2f) — the lock sits at/above the arm level, so the broker min-stop guard may block the SL move. Set lock < trigger.",
                  InpBreakevenLockR, InpBreakevenTriggerR);
   Dbg(StringFormat("INIT V4 target-lock: %s  trigger=%.1f%% of target  ->  SL to %.1f%% of target  (universal, any RR; lock exit counts as TP-win for the weekly-bias stop: %s)",
                    InpUseTargetLock ? "ON" : "OFF", InpTargetLockTriggerPct, InpTargetLockSLPct,
                    InpTargetLockCountsAsWin ? "YES" : "NO"));
   if(InpUseTargetLock && InpTargetLockSLPct >= InpTargetLockTriggerPct)
      PrintFormat("LUCC/LDCC EA V4 WARNING: InpTargetLockSLPct (%.1f) >= InpTargetLockTriggerPct (%.1f) — the profit lock sits at/above the trigger, so it can never arm. Set SL%% < trigger%%.",
                  InpTargetLockSLPct, InpTargetLockTriggerPct);
   Dbg(StringFormat("INIT V5 target-fixation: %s  target=WeeklyC1(BC/DC->DailyC1 once C1 traded through)  RR-bands: <%.2f -> limit@%.2fR, %.2f..%.2f as-is, >%.2f -> cap%.2fR | Daily-confirm=MANDATORY, BC/DC exempt from invalidation",
                    InpUseWeeklyTargetFixation ? "ON" : "OFF", InpMinTargetRR, InpMinTargetRR,
                    InpMinTargetRR, InpMaxTargetRR, InpMaxTargetRR, InpMaxTargetRR));
   if(InpUseWeeklyTargetFixation && InpMinTargetRR >= InpMaxTargetRR)
      PrintFormat("LUCC/LDCC EA V5 WARNING: InpMinTargetRR (%.2f) >= InpMaxTargetRR (%.2f) — the 2.5R..4R acceptance band is empty. Set MinRR < MaxRR.",
                  InpMinTargetRR, InpMaxTargetRR);
   PrintFormat("LUCC/LDCC EA: TIMEZONE %s | broker std offset=UTC%+.0f (DST=%s) | server %s = Nairobi %s  (all logged times = Africa/Nairobi)",
               InpAutoDetectBrokerOffset ? "auto-detected" : "MANUAL", g_brokerStdOffsetHours,
               InpBrokerUsesDst ? "EU" : "none",
               TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES),
               TimeToString(GetNairobiTime(TimeCurrent()), TIME_DATE | TIME_MINUTES));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Funnel summary — the definitive "why no trades" readout. If refs>0 but
   // entries==0, the reject tally below shows exactly which gate stopped them.
   PrintFormat("LUCC/LDCC EA FUNNEL: refs=%d CCs=%d retestTouches=%d ENTRIES=%d skippedAfterWin=%d pendingExpired=%d dailyBEmoves=%d (StopAfterWinRule=%s, ExpirePendingDaily=%s, DailyConfirm=%s, DailyBE=%s)",
               g_cntRef, g_cntCc, g_cntTouch, g_cntEntries, g_skippedAfterWin, g_expiredPending, g_beDailyMoved,
               InpStopAfterFirstWin ? "ON" : "OFF", InpExpirePendingDaily ? "ON" : "OFF",
               InpUseDailyConfirmation ? "ON" : "OFF", InpMoveToBEOnDailyBreak ? "ON" : "OFF");
   PrintFormat("LUCC/LDCC EA V5 LIMITS: placed=%d filled=%d expired=%d (TargetFixation=%s, MinRR=%.2f, MaxRR=%.2f)",
               g_cntLimitsPlaced, g_cntLimitsFilled, g_cntLimitsExpired,
               InpUseWeeklyTargetFixation ? "ON" : "OFF", InpMinTargetRR, InpMaxTargetRR);
   PrintFormat("LUCC/LDCC EA REJECTS: posOpen=%d doneToday=%d maxTrades=%d bias=%d dailyConfirm=%d slInvalid=%d minStop=%d lots=%d orderFail=%d",
               g_rejPosOpen, g_rejDoneToday, g_rejMaxTrades, g_rejBias, g_rejDailyConf,
               g_rejSlInvalid, g_rejMinStop, g_rejLots, g_rejOrderFail);

   // Any setup still armed (CC formed, no RC entry) when the run ends is also a
   // missed setup — capture it before flushing so its opportunity cost is logged.
   if(InpLogMissedSetups || InpLogSkippedSetups)
   {
      for(int e = 0; e < NUM_ENGINES; e++)
      {
         g_curEng = e;
         RebuildSyntheticFor(e);
         if(g_sell[e].refTime != 0 && g_sell[e].ccTime != 0 && g_sell[e].rcTime == 0)
            CaptureMissedSetup(true,  g_sell[e], "RunEnded");
         if(g_buy[e].refTime != 0 && g_buy[e].ccTime != 0 && g_buy[e].rcTime == 0)
            CaptureMissedSetup(false, g_buy[e],  "RunEnded");
      }
      ProcessMissedFinalize(true);   // force-write all queued missed/skipped setups (partial windows included)
      PrintFormat("LUCC/LDCC EA OPP-COST: captured=%d wouldWin(hypoTP)=%d (armed CC that never became a real entry)",
                  g_missedCaptured, g_missedWouldWin);
   }

   // Flush whatever excursion data was gathered for trades whose tracking
   // window hadn't finished yet (e.g. the backtest/EA ended first) rather
   // than silently dropping those rows.
   for(int i = ArraySize(g_pending) - 1; i >= 0; i--)
   {
      if(InpEnableTradeLog)
         FinalizePendingLog(g_pending[i], false);
   }
   ArrayFree(g_pending);
   ArrayFree(g_missed);
   ArrayFree(g_pendingEntries);
   ArrayFree(g_openTrades);
   ArrayFree(g_winEpisodes);

   // Weekly summary CSV — written after all trades (incl. the just-flushed
   // pending ones) have been folded into the weekly aggregator.
   if(InpEnableTradeLog)
      WriteWeeklyStats();

   DestroyPanel();

   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }

   if(g_logHandle != INVALID_HANDLE)
   {
      FileClose(g_logHandle);
      g_logHandle = INVALID_HANDLE;
   }

   if(g_pathHandle != INVALID_HANDLE)
   {
      FileClose(g_pathHandle);
      g_pathHandle = INVALID_HANDLE;
   }

   if(g_missedHandle != INVALID_HANDLE)
   {
      FileClose(g_missedHandle);
      g_missedHandle = INVALID_HANDLE;
   }
}

void OnTick()
{
   ResolveBrokerOffset();   // finalizes the broker->Nairobi offset once TimeGMT() is available
   CheckDailyReset();

   // Closed-bar part: reference-candle (re)selection and CC detection.
   datetime curBarTime = iTime(_Symbol, ENTRY_TF, 0);
   if(curBarTime != g_lastBarTime)
   {
      g_lastBarTime = curBarTime;
      ProcessNewBar();
   }

   // Per-trade path log — append the just-closed path-TF bar for every tracked
   // trade (self-guards to once per path bar).
   WritePathBars();

   // Tick-by-tick part: RC detection/execution, plus MFE/MAE tracking on
   // whichever direction currently has an open position.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

   // V7: pending-limit invalidation (engine-agnostic — each pending carries its
   // own engine context, set inside these loops). Run before the per-engine retest
   // so a cancelled limit frees its episode immediately.
   ExpireLimitsOnDailyBreak(bid, ask);  // V6: kill an unfilled Case-1 limit once Daily-C1 is traded through
   UpdatePendingLimitStale(bid, ask);   // V6: kill an unfilled Case-1 limit that ran > InpMaxAwayR away first

   // V7: run BOTH engines independently. Each refreshes its own higher-TF candles,
   // its own bias, and hunts its own retest entries — no shared setup state.
   for(int eng = 0; eng < NUM_ENGINES; eng++)
   {
      g_curEng = eng;
      RebuildSyntheticFor(eng);      // engine 1 builds its synthetic 2W/2D candles (engine 0 no-op)
      ComputeBias(bid, ask);         // this engine's bias (direction + invalidation latches)
      MonitorRetest(true,  g_sell[eng], bid, ask, mid);
      MonitorRetest(false, g_buy[eng],  bid, ask, mid);
   }

   // Trade management below is engine-agnostic: it iterates every open trade / queued
   // record and acts on that record's OWN frozen parameters, so both engines' trades
   // are managed identically and independently.
   UpdateOpenExcursions(bid, ask);   // MFE/MAE + time-in-profit/DD + maxDD for every open trade
   UpdateBreakeven(bid, ask);        // V6: move SL to breakeven once the +1.2R trigger is reached
   UpdatePartialClose(bid, ask);     // V6: take 50% off at +2R (the remainder runs to the target)
   UpdateDailyBreakeven(bid, ask);   // move SL to BE when price trades beyond Daily Candle-1 (opt-in)
   UpdateTargetLock(bid, ask);       // V6 stage 3: at 82% of target, lock the runner's SL at 50% of target
   if(InpEnableTradeLog)
      UpdatePendingExcursions(bid, ask);
   if(InpLogMissedSetups || InpLogSkippedSetups)
      ProcessMissedFinalize(false);   // write missed/skipped setups whose CC-forward window is complete

   // Info panel — skip entirely during optimization (no chart, and the
   // object churn would only slow the agents down).
   if(InpShowPanel && !(bool)MQLInfoInteger(MQL_OPTIMIZATION))
      UpdatePanel();

   g_prevMid     = mid;
   g_havePrevMid = true;
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                         const MqlTradeRequest &request,
                         const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber)
      return;

   ENUM_DEAL_ENTRY entryType = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   // V5: a position OPEN. If it came from one of our Case-1 pending limits,
   // finalise that snapshot into the live open-trade list. (Market opens are
   // already built synchronously in TryOpen and match no pending ticket.)
   if(entryType == DEAL_ENTRY_IN)
   {
      HandleFill(trans.deal);
      return;
   }
   if(entryType != DEAL_ENTRY_OUT && entryType != DEAL_ENTRY_OUT_BY)
      return;

   long     posId       = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   datetime exitTime      = (datetime)HistoryDealGetInteger(trans.deal, DEAL_TIME);
   double   exitPrice      = HistoryDealGetDouble(trans.deal, DEAL_PRICE);
   string   exitReason      = HistoryDealGetString(trans.deal, DEAL_COMMENT);
   double   grossProfit      = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   double   commission        = HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);
   double   swap               = HistoryDealGetDouble(trans.deal, DEAL_SWAP);

   HandleClose(posId, exitTime, exitPrice, exitReason, grossProfit, commission, swap);
}
//+------------------------------------------------------------------+
