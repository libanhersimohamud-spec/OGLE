//+------------------------------------------------------------------+
//|                    LUCC_LDCC_Confirmation_Retest_EA.mq5          |
//|                                                                    |
//| Expert Advisor port of "LUCC / LDCC Confirmation & Retest         |
//| Indicator" (Pine v6).                                              |
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

input group "1W Bias Filter"
input bool   InpUseBiasFilter        = true;  // Gate entries on the Weekly (1W) directional bias

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

input group "Setup Invalidation (Daily used ONLY here — not for bias/entry)"
input bool   InpUseDailySetupInvalidation = true; // Before the entry triggers, invalidate the current 1H
                                               // setup if the DAILY candle trades beyond Daily Candle-1:
                                               // BUY setup dies if Daily > Daily-C1 High; SELL setup dies
                                               // if Daily < Daily-C1 Low (touch, no close needed). The
                                               // setup is discarded and never reused; the Weekly Bias and
                                               // the 120-candle lookback are NOT affected.

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
   int      tradesToday;
   bool     doneToday;   // true once a trade in this direction has won today
};

SSignalState g_sell;   // SELL side, driven by the Bullish LUCC
SSignalState g_buy;    // BUY side,  driven by the Bearish LDCC

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
};
SOpenTrade g_openTrades[];

// Weekly-bias episodes (per side) in which a WIN has already been booked.
// Enforces "only one winning trade per weekly-bias instance"; because an
// episode IS a weekly candle, each new week is automatically a fresh,
// independent instance and the restriction resets with no lingering state.
datetime g_sellWinEpisodes[];
datetime g_buyWinEpisodes[];

bool HasOpenTradeForEpisode(bool isSell, datetime episode)
{
   for(int i = 0; i < ArraySize(g_openTrades); i++)
      if(g_openTrades[i].isSell == isSell && g_openTrades[i].episode == episode)
         return true;
   return false;
}
bool HasOpenTrade(bool isSell)
{
   for(int i = 0; i < ArraySize(g_openTrades); i++)
      if(g_openTrades[i].isSell == isSell)
         return true;
   return false;
}
int OpenTradeCount(bool isSell)
{
   int c = 0;
   for(int i = 0; i < ArraySize(g_openTrades); i++)
      if(g_openTrades[i].isSell == isSell)
         c++;
   return c;
}
bool HasWinEpisode(bool isSell, datetime episode)
{
   if(episode == 0)
      return false;
   if(isSell)
   { for(int i = 0; i < ArraySize(g_sellWinEpisodes); i++) if(g_sellWinEpisodes[i] == episode) return true; }
   else
   { for(int i = 0; i < ArraySize(g_buyWinEpisodes); i++) if(g_buyWinEpisodes[i] == episode) return true; }
   return false;
}
void AddWinEpisode(bool isSell, datetime episode)
{
   if(HasWinEpisode(isSell, episode))
      return;
   if(isSell)
   { int n = ArraySize(g_sellWinEpisodes); ArrayResize(g_sellWinEpisodes, n + 1); g_sellWinEpisodes[n] = episode; }
   else
   { int n = ArraySize(g_buyWinEpisodes);  ArrayResize(g_buyWinEpisodes, n + 1);  g_buyWinEpisodes[n] = episode; }
}

//======================================================================
// A trade that has already closed, still being watched so its MFE/MAE
// aren't capped by the actual SL/TP — see the "Trade Journal — excursion
// tracking" section below for why this exists.
//======================================================================
struct SPendingLog
{
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
};

SPendingLog g_pending[];

CTrade   g_trade;
datetime g_lastBarTime  = 0;
datetime g_lastResetDay = 0;
double   g_prevMid      = 0.0;   // previous tick's mid price, for level-crossing detection
bool     g_havePrevMid  = false;
int      g_logHandle    = INVALID_HANDLE;
int      g_logCols      = 0;                // column count from the header — row-width sanity guard
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
long g_rejSlInvalid  = 0;
long g_rejMinStop    = 0;
long g_rejLots       = 0;
long g_rejOrderFail  = 0;
long g_skippedAfterWin = 0;   // setups skipped by the stop-after-first-win-per-weekly-bias rule
long g_expiredPending  = 0;   // armed retest setups discarded at a day boundary (pending-expiration rule)
long g_invalidDaily    = 0;   // setups invalidated by the Daily setup-invalidation rule
long g_invalidWeekly   = 0;   // setups discarded because the Weekly bias was invalidated

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
double BarOpen(int off)  { return iOpen(_Symbol, PERIOD_H1, off + 1); }
double BarClose(int off) { return iClose(_Symbol, PERIOD_H1, off + 1); }
double BarHigh(int off)  { return iHigh(_Symbol, PERIOD_H1, off + 1); }
double BarLow(int off)   { return iLow(_Symbol, PERIOD_H1, off + 1); }
datetime BarTime(int off){ return iTime(_Symbol, PERIOD_H1, off + 1); }

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
   int totalBars = iBars(_Symbol, PERIOD_H1);
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
      st.refTime = newRefTime;
      st.refHigh = newRefHigh;
      st.refLow  = newRefLow;
      st.ccTime  = 0;
      st.rcTime  = 0;
      st.slLevel = 0;
      st.lastAttemptBar = 0;
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

         // Stop Loss Level — highest high (sell) / lowest low (buy) from the
         // reference candle through the CC, inclusive. Same span the
         // indicator draws its orange dashed line across.
         int refShift    = iBarShift(_Symbol, PERIOD_H1, st.refTime, true);
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
   if(InpUseBarCloseRetest && st.refTime != 0 && st.ccTime != 0 && st.rcTime == 0
      && BarTime(0) > st.ccTime && st.lastAttemptBar != BarTime(0))
   {
      double level    = isSell ? st.refLow : st.refHigh;
      bool   brackets = (BarLow(0) <= level && BarHigh(0) >= level);
      if(brackets)
      {
         st.lastAttemptBar = BarTime(0);
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

   double level    = isSell ? st.refLow : st.refHigh;
   bool   straddle = (bid <= level && ask >= level);
   bool   crossed  = g_havePrevMid && ((g_prevMid - level) * (mid - level) < 0);
   if(!(straddle || crossed))
      return;

   // Throttle to one entry attempt per H1 bar per side, so a sustained
   // straddle doesn't spam TryOpen (and the Experts log) every tick.
   datetime curBar = iTime(_Symbol, PERIOD_H1, 0);
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
   for(int i = 0; i < ArraySize(g_openTrades); i++)
   {
      if(g_openTrades[i].isSell)
      {
         g_openTrades[i].mfePrice = MathMin(g_openTrades[i].mfePrice, bid); // lower = favorable for a sell
         g_openTrades[i].maePrice = MathMax(g_openTrades[i].maePrice, ask); // higher = adverse for a sell
      }
      else
      {
         g_openTrades[i].mfePrice = MathMax(g_openTrades[i].mfePrice, ask);
         g_openTrades[i].maePrice = MathMin(g_openTrades[i].maePrice, bid);
      }
   }
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
   datetime approxUtc = serverTime - (long)(g_brokerStdOffsetHours * 3600);
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

   datetime utcTime = serverTime - (long)(offsetHours * 3600);
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
   st.expiredRefTime = st.refTime;
   st.ccTime         = 0;
   st.slLevel        = 0;
   st.lastAttemptBar = 0;
   g_expiredPending++;
   Dbg(StringFormat("%s PENDING EXPIRED at new day: untriggered retest on ref @ %s discarded; awaiting a new setup",
                    isSell ? "SELL" : "BUY", TimeToString(GetNairobiTime(st.expiredRefTime), TIME_DATE | TIME_MINUTES)));
}

// Discards the CURRENT active, UN-triggered 1H entry setup for one side (any
// stage: LUCC/LDCC found, CC formed, or awaiting RC). The reference is stamped
// expired so it can't re-arm — the EA waits for a genuinely NEW reference. Does
// NOT touch open trades (rcTime != 0) or the Weekly bias or the 120 lookback.
// No-op if there is no active untriggered setup, or it was already discarded.
void DiscardSetup(bool isSell, SSignalState &st, string reason)
{
   if(st.refTime == 0 || st.rcTime != 0 || st.refTime == st.expiredRefTime)
      return;
   st.expiredRefTime = st.refTime;
   st.ccTime         = 0;
   st.slLevel        = 0;
   st.lastAttemptBar = 0;
   Dbg(StringFormat("%s SETUP INVALIDATED (%s): ref @ %s discarded; never reused; awaiting a new setup",
                    isSell ? "SELL" : "BUY", reason,
                    TimeToString(GetNairobiTime(st.expiredRefTime), TIME_DATE | TIME_MINUTES)));
}

// Applies both invalidation rules every tick, BEFORE the retest is checked, so
// an invalidated setup can never open a trade.
//   Rule 2 (Weekly-bias): when the weekly bias for a side is invalidated
//           (ComputeBias already latches this per Weekly Candle-1), discard
//           that side's active setup. The bias gate keeps that side blocked for
//           the rest of the week; the bias resets on a new weekly candle.
//   Rule 1 (Daily): the DAILY timeframe is used ONLY here — if the Daily candle
//           trades beyond Daily Candle-1 (BUY: above C1 High; SELL: below C1
//           Low), discard that side's active setup. Touch-based (no close). The
//           Weekly bias is untouched, so a NEW 1H setup aligned with the same
//           weekly bias may arm afterwards.
void ApplyInvalidations(double bid, double ask)
{
   // Rule 2 — Weekly bias invalidation discards the active 1H setup.
   if(InpUseBiasFilter)
   {
      if(g_bias.buyInvalid  && g_buy.refTime  != 0 && g_buy.rcTime  == 0 && g_buy.refTime  != g_buy.expiredRefTime)
      { DiscardSetup(false, g_buy,  "Weekly BUY bias invalidated");  g_invalidWeekly++; }
      if(g_bias.sellInvalid && g_sell.refTime != 0 && g_sell.rcTime == 0 && g_sell.refTime != g_sell.expiredRefTime)
      { DiscardSetup(true,  g_sell, "Weekly SELL bias invalidated"); g_invalidWeekly++; }
   }

   // Rule 1 — Daily setup invalidation (Daily used ONLY here).
   if(InpUseDailySetupInvalidation && iBars(_Symbol, PERIOD_D1) >= 2)
   {
      double dC1High = iHigh(_Symbol, PERIOD_D1, 1);
      double dC1Low  = iLow(_Symbol, PERIOD_D1, 1);
      double dHiNow  = MathMax(iHigh(_Symbol, PERIOD_D1, 0), ask); // this Daily candle's high incl. live tick
      double dLoNow  = MathMin(iLow(_Symbol, PERIOD_D1, 0), bid);  // this Daily candle's low  incl. live tick
      if(g_buy.refTime  != 0 && g_buy.rcTime  == 0 && g_buy.refTime  != g_buy.expiredRefTime  && dHiNow > dC1High)
      { DiscardSetup(false, g_buy,  "Daily traded above Daily-C1 High"); g_invalidDaily++; }
      if(g_sell.refTime != 0 && g_sell.rcTime == 0 && g_sell.refTime != g_sell.expiredRefTime && dLoNow < dC1Low)
      { DiscardSetup(true,  g_sell, "Daily traded below Daily-C1 Low");  g_invalidDaily++; }
   }
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
      // Once-a-day progress heartbeat so the funnel is visible DURING the run,
      // not only at the end — refs/CCs/touches/entries so far, plus the live
      // Weekly-bias state that is currently gating entries.
      if(g_lastResetDay != 0)
         Dbg(StringFormat("DAY %04d.%02d.%02d | funnel refs=%d CCs=%d touches=%d entries=%d | bias dir=%s buy=[%s]%s sell=[%s]%s",
                          dt.year, dt.mon, dt.day, g_cntRef, g_cntCc, g_cntTouch, g_cntEntries, g_bias.dir,
                          g_bias.buyText,  g_bias.buyInvalid  ? " INVALID" : "",
                          g_bias.sellText, g_bias.sellInvalid ? " INVALID" : ""));

      // Expire any armed-but-untriggered pending retest — a clean slate each day.
      ExpirePendingIfArmed(true,  g_sell);
      ExpirePendingIfArmed(false, g_buy);

      g_lastResetDay = today;
      g_sell.tradesToday = 0; g_sell.doneToday = false;
      g_buy.tradesToday  = 0; g_buy.doneToday  = false;
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
double WOpen(int s)  { return iOpen(_Symbol, PERIOD_W1, s); }
double WHigh(int s)  { return iHigh(_Symbol, PERIOD_W1, s); }
double WLow(int s)   { return iLow(_Symbol, PERIOD_W1, s); }
double WClose(int s) { return iClose(_Symbol, PERIOD_W1, s); }

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
SBiasState g_bias;

// Recompute the Weekly bias every tick: pattern presence/direction (read
// LIVE, exactly like the reference), plus the price-based invalidation
// latches. Must be called before the retest gate each tick.
void ComputeBias(double bid, double ask)
{
   // A new weekly candle clears both invalidation latches — an invalidation
   // can never carry across weeks, exactly like the indicator resetting its
   // bias invalidation once per new higher-timeframe candle.
   datetime c1 = iTime(_Symbol, PERIOD_W1, 1);
   if(c1 != g_bias.c1Time)
   {
      g_bias.c1Time      = c1;
      g_bias.buyInvalid  = false;
      g_bias.sellInvalid = false;
   }

   // The DS / N-DS patterns reach back to shift 3, so we need candles 0..3
   // before any bias can be evaluated; until then there is no bias.
   if(iBars(_Symbol, PERIOD_W1) < 4)
   {
      g_bias.buyText     = "-"; g_bias.sellText    = "-";
      g_bias.buyPresent  = false; g_bias.sellPresent = false;
      g_bias.dir         = "NONE";
      return;
   }

   g_bias.buyText     = Bias_BuyText();
   g_bias.sellText    = Bias_SellText();
   g_bias.buyPresent  = (g_bias.buyText  != "-");
   g_bias.sellPresent = (g_bias.sellText != "-");
   g_bias.dir =
       (g_bias.buyPresent && !g_bias.sellPresent) ? "BUY"  :
       (g_bias.sellPresent && !g_bias.buyPresent) ? "SELL" :
       (g_bias.buyPresent &&  g_bias.sellPresent) ? "BOTH" : "NONE";

   // Invalidation — price-based and latched for the rest of the Weekly candle.
   // Reference = candle 1 (last closed weekly). BUY dies once this week's price
   // trades above candle-1 high; SELL dies once it trades below candle-1 low.
   // The two latches are INDEPENDENT so that under BOTH, one side breaking
   // never silences the other (buy and sell run independently, per spec).
   double c1High   = WHigh(1);
   double c1Low    = WLow(1);
   double weekHigh = MathMax(WHigh(0), ask); // running high so far this week, incl. the live tick
   double weekLow  = MathMin(WLow(0),  bid); // running low  so far this week, incl. the live tick
   if(weekHigh > c1High) g_bias.buyInvalid  = true;
   if(weekLow  < c1Low)  g_bias.sellInvalid = true;
}

// A direction is tradeable only if a Weekly pattern of that side is present
// AND that side hasn't been invalidated. With the filter switched off the
// gate is transparent (always allowed).
bool BuyBiasAllowed()  { return !InpUseBiasFilter || (g_bias.buyPresent  && !g_bias.buyInvalid); }
bool SellBiasAllowed() { return !InpUseBiasFilter || (g_bias.sellPresent && !g_bias.sellInvalid); }

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
   if(HasOpenTradeForEpisode(isSell, g_bias.c1Time))
   { g_rejPosOpen++; Dbg(side + " retest REJECT: a trade for the current weekly-bias episode is already open"); return false; }
   if(st.doneToday)
   { g_rejDoneToday++; Dbg(side + " retest REJECT: this side already booked a win today (doneToday)"); return false; }
   if(st.tradesToday >= 2)
   { g_rejMaxTrades++; Dbg(side + " retest REJECT: daily 2-trade limit reached"); return false; }
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
      Dbg(StringFormat("%s retest REJECT: bias gate (dir=%s buy=[%s]%s sell=[%s]%s)", side, g_bias.dir,
                       g_bias.buyText,  g_bias.buyInvalid  ? " INVALID" : "",
                       g_bias.sellText, g_bias.sellInvalid ? " INVALID" : ""));
      return false;
   }

   // Stop-after-first-win rule: once this side booked a WIN in the CURRENT
   // weekly-bias episode, skip further setups in this direction FOR THAT
   // EPISODE ONLY. Because episodes are per weekly candle, a new week is a
   // fresh instance with no restriction. Losses do not trigger this. Toggle
   // off for the "unlimited trades per weekly bias" dataset.
   if(InpStopAfterFirstWin && HasWinEpisode(isSell, g_bias.c1Time))
   {
      g_skippedAfterWin++;
      RecordWeeklySkip(TimeCurrent());
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

   // Proportional SL buffer — the FINAL stop distance is the original
   // structural SL range (entry -> structural stop) multiplied by
   // InpStopLossMultiplier (e.g. x1.3), so the buffer scales with the setup
   // size instead of a fixed pip pad. Risk stays constant (CalcLotSize sizes
   // off this final distance, so lots shrink), and the fixed-RR TP is measured
   // from the final stop — a true monetary 1:InpTakeProfitRMultiple.
   double origRange  = MathAbs(entry - structuralSl);
   double finalRange = origRange * InpStopLossMultiplier;
   double sl  = isSell ? entry + finalRange : entry - finalRange;

   double dist   = finalRange;
   double tpDist = dist * InpTakeProfitRMultiple;
   double tp     = isSell ? entry - tpDist : entry + tpDist;

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

      // Build the open-trade record — a full, self-contained snapshot frozen
      // at entry. Pushed onto g_openTrades so it can coexist with other open
      // trades (including same-direction ones from other weekly biases).
      SOpenTrade ot;
      ot.isSell          = isSell;
      ot.positionId      = posId;
      ot.episode         = g_bias.c1Time;   // this trade's weekly-bias identity
      ot.refTime         = st.refTime;  ot.refHigh = st.refHigh;  ot.refLow = st.refLow;
      ot.ccTime          = st.ccTime;   ot.rcTime  = st.rcTime;
      ot.entryTime       = TimeCurrent();
      ot.entryPrice      = (fillPrice > 0) ? fillPrice : entry;
      ot.slPrice         = sl;   ot.tpPrice = tp;
      ot.structuralSl    = structuralSl;   ot.requestedEntry = entry;
      ot.riskAmount      = riskAmount;   ot.lots = lots;   ot.tradeSeqToday = st.tradesToday;
      ot.balanceBeforeEntry = balance;   ot.equityBefore = AccountInfoDouble(ACCOUNT_EQUITY);
      ot.bidAtEntry      = bidAtEntry;   ot.askAtEntry = askAtEntry;
      ot.spreadPoints    = spreadPoints; ot.atrH1AtEntry = atrH1AtEntry;
      ot.biasDir         = g_bias.dir;   ot.biasBuyText = g_bias.buyText;   ot.biasSellText = g_bias.sellText;
      ot.sideBiasText    = isSell ? g_bias.sellText : g_bias.buyText;
      ot.biasCandleTime  = g_bias.c1Time;
      ot.weekO = WOpen(1); ot.weekH = WHigh(1); ot.weekL = WLow(1); ot.weekC = WClose(1);
      ot.dayO  = iOpen(_Symbol, PERIOD_D1, 1); ot.dayH = iHigh(_Symbol, PERIOD_D1, 1);
      ot.dayL  = iLow(_Symbol, PERIOD_D1, 1);  ot.dayC = iClose(_Symbol, PERIOD_D1, 1);
      ot.mfePrice = ot.entryPrice; ot.maePrice = ot.entryPrice;

      int oi = ArraySize(g_openTrades);
      ArrayResize(g_openTrades, oi + 1);
      g_openTrades[oi] = ot;

      g_cntEntries++;
      Dbg(StringFormat("%s ENTRY OK: fill=%.5f sl=%.5f tp=%.5f lots=%.2f risk=%.2f episode=%s bias[%s] (openTrades=%d)",
                       side, ot.entryPrice, sl, tp, lots, riskAmount,
                       TimeToString(GetNairobiTime(ot.episode), TIME_DATE), ot.sideBiasText, ArraySize(g_openTrades)));
      return true;
   }

   g_rejOrderFail++;
   PrintFormat("LUCC/LDCC EA: %s order failed, retcode=%d (%s)",
               side, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   return false;
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
   UpdateDirection(true,  g_sell);
   UpdateDirection(false, g_buy);
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
      "FirstWinOfBias", "StopAfterWinRule"
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
                      bool firstWinOfBias)
{
   int n = ArraySize(g_pending);
   ArrayResize(g_pending, n + 1);

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

int WeekBucketIndex(datetime weekStart)
{
   for(int i = 0; i < ArraySize(g_weeks); i++)
      if(g_weeks[i].weekStart == weekStart)
         return i;
   int idx = ArraySize(g_weeks);
   ArrayResize(g_weeks, idx + 1);
   g_weeks[idx].weekStart = weekStart;
   g_weeks[idx].trades = 0; g_weeks[idx].wins = 0; g_weeks[idx].losses = 0; g_weeks[idx].breakeven = 0;
   g_weeks[idx].totalR = 0; g_weeks[idx].curWin = 0; g_weeks[idx].curLoss = 0;
   g_weeks[idx].maxWin = 0; g_weeks[idx].maxLoss = 0; g_weeks[idx].setupsSkipped = 0;
   return idx;
}

// A setup was skipped by the stop-after-first-win rule — tally it into the
// week it occurred in, so the weekly CSV shows skip pressure per week.
void RecordWeeklySkip(datetime whenServerTime)
{
   int idx = WeekBucketIndex(WeekStartOf(whenServerTime));
   g_weeks[idx].setupsSkipped++;
}

void UpdateWeeklyStats(datetime entryTime, double rRealized, double netProfit)
{
   int idx = WeekBucketIndex(WeekStartOf(entryTime));
   g_weeks[idx].trades++;
   g_weeks[idx].totalR += rRealized;
   if(netProfit > 0)
   {
      g_weeks[idx].wins++; g_weeks[idx].curWin++; g_weeks[idx].curLoss = 0;
      if(g_weeks[idx].curWin > g_weeks[idx].maxWin) g_weeks[idx].maxWin = g_weeks[idx].curWin;
   }
   else if(netProfit < 0)
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
   FileWrite(h, "WeekStart,Trades,Wins,Losses,Breakeven,WinRatePct,TotalR,AvgR,MaxConsecWins,MaxConsecLosses,SetupsSkippedAfterWin,StopAfterWinRule");
   for(int i = 0; i < n; i++)
   {
      double winRate = (g_weeks[i].trades > 0) ? 100.0 * g_weeks[i].wins / g_weeks[i].trades : 0.0;
      double avgR    = (g_weeks[i].trades > 0) ? g_weeks[i].totalR / g_weeks[i].trades : 0.0;
      FileWrite(h, StringFormat("%s,%d,%d,%d,%d,%.1f,%.3f,%.3f,%d,%d,%d,%s",
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
   double spreadPips     = (pip > 0) ? (p.askAtEntry - p.bidAtEntry) / pip : 0.0;
   double profitPips     = (pip > 0) ? (p.isSell ? (p.entryPrice - p.exitPrice) : (p.exitPrice - p.entryPrice)) / pip : 0.0;

   // Derived exit classification, independent of the broker's deal comment.
   string exitType;
   double exitTol = MathMax(2 * point, riskDistance * 0.10);
   if(MathAbs(p.exitPrice - p.slPrice) <= exitTol)      exitType = "SL";
   else if(MathAbs(p.exitPrice - p.tpPrice) <= exitTol) exitType = "TP";
   else                                                 exitType = "OTHER";

   string entryPattern   = p.isSell ? "LUCC" : "LDCC";
   string sideCombo      = ComboKey(p.sideBiasText);
   int    biasCount      = PatternCount(p.sideBiasText);
   string patternSeq     = "WK[" + sideCombo + "]>" + entryPattern + ">CC>RC";
   // Every gate that had to pass for this trade to exist (all true by
   // construction — recorded so a future filter change is auditable).
   string filtersPassed  = "position_free;not_done_today;under_2_today;no_session_gate;bias_allowed;sl_valid;min_stop_ok";

   // --- v2 additions: timing, result, and context ---
   double   holdingHours  = holdingMinutes / 60.0;
   int      barsRefToCC   = (p.refTime > 0 && p.ccTime > 0) ? (int)MathRound((double)(p.ccTime - p.refTime) / 3600.0) : 0;
   int      barsCcToRc    = (p.ccTime > 0 && p.rcTime > 0)  ? (int)MathRound((double)(p.rcTime - p.ccTime) / 3600.0) : 0;
   int      barsRcToEntry = (p.rcTime > 0) ? (int)MathRound((double)(p.entryTime - p.rcTime) / 3600.0) : 0;
   // "IMMEDIATE" = retest on the first bar after the CC; "WAITED" = it took longer.
   string   triggerTiming = (barsCcToRc <= 1) ? "IMMEDIATE" : "WAITED";
   int      entryShift    = iBarShift(_Symbol, PERIOD_H1, p.entryTime, false);
   datetime entryCandle   = (entryShift < 0) ? p.entryTime : iTime(_Symbol, PERIOD_H1, entryShift);
   string   result        = (netProfit > 0) ? "WIN" : (netProfit < 0) ? "LOSS" : "BE";

   datetime nairobiEntry = GetNairobiTime(p.entryTime);
   datetime utcEntry     = GetUtcTime(p.entryTime);
   MqlDateTime dt, du;
   TimeToStruct(nairobiEntry, dt);
   TimeToStruct(utcEntry, du);
   string weekdayNames[7] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   string nairobiDate = StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day);

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
      DoubleToString(InpTakeProfitRMultiple, 2), DoubleToString(rRealized, 3), DoubleToString(slDistPips, 2), DoubleToString(tpDistPips, 2),
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
      p.firstWinOfBias ? "true" : "false", InpStopAfterFirstWin ? "ON" : "OFF"
   };

   if(g_logCols > 0 && ArraySize(v) != g_logCols)
      PrintFormat("LUCC/LDCC EA: trade-log column mismatch (header=%d, row=%d) — check FinalizePendingLog.",
                  g_logCols, ArraySize(v));

   WriteCsvRow(v);
   UpdateWeeklyStats(p.entryTime, rRealized, netProfit);
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

   SOpenTrade t = g_openTrades[idx];
   double netProfit = grossProfit + commission + swap;

   // First win of THIS trade's weekly-bias episode? Tracked ALWAYS (even when
   // the toggle is off) so the "first winning trade" is identifiable in every
   // dataset. The episode is the trade's own weekly-bias candle, so each week
   // is independent and the restriction resets per weekly bias automatically.
   bool firstWin = false;
   if(netProfit > 0)
   {
      if(!HasWinEpisode(t.isSell, t.episode))
      {
         firstWin = true;
         AddWinEpisode(t.isSell, t.episode);
      }
      if(t.isSell) g_sell.doneToday = true; else g_buy.doneToday = true; // daily win-stop (unchanged)
   }

   Dbg(StringFormat("%s CLOSE posId=%d net=%.2f %s%s episode=%s (openTrades left=%d)",
                    t.isSell ? "SELL" : "BUY", closedPosId, netProfit,
                    netProfit > 0 ? "WIN" : (netProfit < 0 ? "LOSS" : "BE"),
                    firstWin ? " [FIRST-WIN]" : "", TimeToString(GetNairobiTime(t.episode), TIME_DATE),
                    ArraySize(g_openTrades) - 1));

   if(InpEnableTradeLog)
      QueuePendingLog(t, exitTime, exitPrice, exitReason, grossProfit, commission, swap, firstWin);

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

string SideStateText(bool isSell, const SSignalState &st)
{
   string tag = isSell ? "LUCC" : "LDCC";
   int openN = OpenTradeCount(isSell);
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

   PanelSet(0, "LUCC / LDCC  +  1W Bias EA  (V3)", clrDeepSkyBlue);

   MqlDateTime nd; TimeToStruct(GetNairobiTime(TimeCurrent()), nd);
   PanelSet(1, StringFormat("Nairobi %02d:%02d   |   24/5 - no time filter", nd.hour, nd.min), clrLime);

   color dirClr = g_bias.dir == "BUY"  ? clrLime :
                  g_bias.dir == "SELL" ? clrRed  :
                  g_bias.dir == "BOTH" ? clrOrange : clrSilver;
   PanelSet(2, "1W Bias: " + g_bias.dir, dirClr);

   string buyStat  = !g_bias.buyPresent  ? "-" : (g_bias.buyInvalid  ? "INVALIDATED" : "ACTIVE");
   color  buyClr   = !g_bias.buyPresent  ? clrSilver : (g_bias.buyInvalid  ? clrOrangeRed : clrLime);
   string sellStat = !g_bias.sellPresent ? "-" : (g_bias.sellInvalid ? "INVALIDATED" : "ACTIVE");
   color  sellClr  = !g_bias.sellPresent ? clrSilver : (g_bias.sellInvalid ? clrOrangeRed : clrRed);
   PanelSet(3, StringFormat("Buy  bias: %-10s [%s]", g_bias.buyText,  buyStat),  buyClr);
   PanelSet(4, StringFormat("Sell bias: %-10s [%s]", g_bias.sellText, sellStat), sellClr);

   PanelSet(5, InpUseBiasFilter ? "Bias gate: ENFORCED" : "Bias gate: OFF (all entries)",
            InpUseBiasFilter ? clrGold : clrSilver);

   PanelSet(6, "SELL (LUCC): " + SideStateText(true, g_sell),
            HasOpenTrade(true) ? clrRed : clrGainsboro);
   bool sellWinLock = InpStopAfterFirstWin && HasWinEpisode(true, g_bias.c1Time);
   PanelSet(7, StringFormat("   trades today %d/2%s   bias %s%s",
            g_sell.tradesToday, g_sell.doneToday ? " (done)" : "",
            SellBiasAllowed() ? "OK" : "blocked", sellWinLock ? "  [WK-WIN-LOCK]" : ""),
            sellWinLock ? clrGold : (SellBiasAllowed() ? clrGainsboro : clrGray));

   PanelSet(8, "BUY (LDCC): " + SideStateText(false, g_buy),
            HasOpenTrade(false) ? clrLime : clrGainsboro);
   bool buyWinLock = InpStopAfterFirstWin && HasWinEpisode(false, g_bias.c1Time);
   PanelSet(9, StringFormat("   trades today %d/2%s   bias %s%s",
            g_buy.tradesToday, g_buy.doneToday ? " (done)" : "",
            BuyBiasAllowed() ? "OK" : "blocked", buyWinLock ? "  [WK-WIN-LOCK]" : ""),
            buyWinLock ? clrGold : (BuyBiasAllowed() ? clrGainsboro : clrGray));

   PanelSet(10, StringFormat("TP 1:%.1f  |  SL x%.2f (range buffer)",
            InpTakeProfitRMultiple, InpStopLossMultiplier), clrGainsboro);

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

   g_bias.c1Time      = 0;
   g_bias.buyInvalid  = false;
   g_bias.sellInvalid = false;
   g_bias.dir         = "NONE";
   g_bias.buyText     = "-";
   g_bias.sellText    = "-";
   g_bias.buyPresent  = false;
   g_bias.sellPresent = false;

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
   PrintFormat("LUCC/LDCC EA FUNNEL: refs=%d CCs=%d retestTouches=%d ENTRIES=%d skippedAfterWin=%d pendingExpired=%d invalidDaily=%d invalidWeekly=%d",
               g_cntRef, g_cntCc, g_cntTouch, g_cntEntries, g_skippedAfterWin, g_expiredPending,
               g_invalidDaily, g_invalidWeekly);
   PrintFormat("LUCC/LDCC EA RULES: StopAfterWinRule=%s ExpirePendingDaily=%s DailySetupInvalidation=%s BiasFilter=%s",
               InpStopAfterFirstWin ? "ON" : "OFF", InpExpirePendingDaily ? "ON" : "OFF",
               InpUseDailySetupInvalidation ? "ON" : "OFF", InpUseBiasFilter ? "ON" : "OFF");
   PrintFormat("LUCC/LDCC EA REJECTS: posOpen=%d doneToday=%d maxTrades=%d bias=%d slInvalid=%d minStop=%d lots=%d orderFail=%d",
               g_rejPosOpen, g_rejDoneToday, g_rejMaxTrades, g_rejBias,
               g_rejSlInvalid, g_rejMinStop, g_rejLots, g_rejOrderFail);

   // Flush whatever excursion data was gathered for trades whose tracking
   // window hadn't finished yet (e.g. the backtest/EA ended first) rather
   // than silently dropping those rows.
   for(int i = ArraySize(g_pending) - 1; i >= 0; i--)
   {
      if(InpEnableTradeLog)
         FinalizePendingLog(g_pending[i], false);
   }
   ArrayFree(g_pending);
   ArrayFree(g_openTrades);
   ArrayFree(g_sellWinEpisodes);
   ArrayFree(g_buyWinEpisodes);

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
}

void OnTick()
{
   ResolveBrokerOffset();   // finalizes the broker->Nairobi offset once TimeGMT() is available
   CheckDailyReset();

   // Closed-bar part: reference-candle (re)selection and CC detection.
   datetime curBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(curBarTime != g_lastBarTime)
   {
      g_lastBarTime = curBarTime;
      ProcessNewBar();
   }

   // Tick-by-tick part: RC detection/execution, plus MFE/MAE tracking on
   // whichever direction currently has an open position.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double mid = (bid + ask) / 2.0;

   // Refresh the Weekly bias (direction + invalidation latches) before the
   // retest gate reads it this tick.
   ComputeBias(bid, ask);

   // Rule 1 (Daily) + Rule 2 (Weekly-bias) setup invalidation — discard any
   // invalidated setup BEFORE the retest can trigger it this tick.
   ApplyInvalidations(bid, ask);

   MonitorRetest(true,  g_sell, bid, ask, mid);
   MonitorRetest(false, g_buy,  bid, ask, mid);
   UpdateOpenExcursions(bid, ask);   // MFE/MAE for every currently-open trade
   if(InpEnableTradeLog)
      UpdatePendingExcursions(bid, ask);

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
