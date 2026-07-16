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
input double InpRiskPercent          = 1.0;     // Risk per trade (% of account balance)
input long   InpMagicNumber          = 20260716; // Magic number
input int    InpSlippagePoints       = 20;       // Max slippage (points)

input group "Trading Session (Nairobi / EAT, UTC+3, no DST)"
input double InpBrokerGmtOffsetHours = 2.0;   // Broker's STANDARD (winter) GMT offset, hours
input bool   InpBrokerUsesDst        = true;  // Broker shifts its clock for EU-style DST
input int    InpSummerStartMonth     = 4;     // First month of the wider session (inclusive)
input int    InpSummerEndMonth       = 10;    // Last month of the wider session (inclusive)
input int    InpSummerStartHour      = 4;     // Session start, Nairobi time, summer months
input int    InpSummerEndHour        = 18;    // Session end,   Nairobi time, summer months
input int    InpWinterStartHour      = 5;     // Session start, Nairobi time, winter months
input int    InpWinterEndHour        = 19;    // Session end,   Nairobi time, winter months

input group "Trade Journal"
input bool   InpEnableTradeLog       = true;                          // Write a per-trade CSV log
input string InpTradeLogFileName     = "LUCC_LDCC_TradeLog.csv";      // File name (MQL5/Files)
input bool   InpEnableExcursionTracking = true;  // Keep watching price past the actual exit for true MFE/MAE
input int    InpExcursionTrackingHours  = 120;   // Hours from ENTRY to keep tracking (uncapped by SL/TP)

//======================================================================
// Constants (indicator logic parameters — preserved exactly, not
// exposed as inputs, so optimization can never alter the signal rules)
//======================================================================
#define LOOKBACK 24   // rolling window: only the latest 24 closed candles are ever searched

//======================================================================
// Per-direction signal + trade-management state
// (one instance for SELL/LUCC, one for BUY/LDCC — fully independent,
// exactly as in the indicator and as required by the daily trade rules)
//======================================================================
struct SSignalState
{
   // --- indicator state (mirrors luccBarIndex/luccHigh/luccLow, ccBar*, rcBar*) ---
   datetime refTime;    // bar time of the active LUCC / LDCC candle (0 = none)
   double   refHigh;
   double   refLow;
   datetime ccTime;     // bar time of the Confirmation Candle (0 = none yet)
   datetime rcTime;      // bar time of the Retest Candle (0 = none yet)
   double   slLevel;    // the indicator's "Stop Loss Level" for this cycle

   // --- trade-management state ---
   bool     positionOpen;
   long     positionId;
   int      tradesToday;
   bool     doneToday;   // true once a trade in this direction has won today

   // --- trade journal state (filled in TryOpen, consumed in HandlePositionClosed) ---
   datetime entryTime;
   double   entryPrice;      // actual fill price (CTrade::ResultPrice)
   double   slPrice;
   double   tpPrice;
   double   riskAmount;      // $ risked on this trade (balance * risk% at entry)
   double   lots;
   int      tradeSeqToday;   // 1st or 2nd trade of the day for this direction
   double   balanceBeforeEntry;
   double   mfePrice;        // best price reached while the position was open
   double   maePrice;        // worst price reached while the position was open
};

SSignalState g_sell;   // SELL side, driven by the Bullish LUCC
SSignalState g_buy;    // BUY side,  driven by the Bearish LDCC

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
   double   mfePrice;   // continues updating past the actual exit, until trackUntil
   double   maePrice;
   datetime trackUntil;
};

SPendingLog g_pending[];

CTrade   g_trade;
datetime g_lastBarTime  = 0;
datetime g_lastResetDay = 0;
double   g_prevMid      = 0.0;   // previous tick's mid price, for level-crossing detection
bool     g_havePrevMid  = false;
int      g_logHandle    = INVALID_HANDLE;

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
//| CONTAINED range-containment filter. Returns -1 if none found.    |
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
   }

   // Confirmation Candle
   if(st.refTime != 0 && st.ccTime == 0)
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
   if(st.ccTime == 0 || st.rcTime != 0)
      return;

   double level    = isSell ? st.refLow : st.refHigh;
   bool   straddle = (bid <= level && ask >= level);
   bool   crossed  = g_havePrevMid && ((g_prevMid - level) * (mid - level) < 0);

   if(straddle || crossed)
   {
      st.rcTime = iTime(_Symbol, PERIOD_H1, 0); // the currently-forming bar is the RC
      TryOpen(isSell, st);
   }
}

//+------------------------------------------------------------------+
//| Tracks Maximum Favorable/Adverse Excursion while a position is    |
//| open — the best and worst price the market reached before the    |
//| trade closed. Logged in R-multiples alongside the realized R so  |
//| you can see, e.g., "lost trades that were briefly +0.6R" (a       |
//| trailing-stop candidate) vs. "losses that went straight to -1R".  |
//+------------------------------------------------------------------+
void UpdateExcursion(bool isSell, SSignalState &st, double bid, double ask)
{
   if(!st.positionOpen)
      return;

   if(isSell)
   {
      st.mfePrice = MathMin(st.mfePrice, bid); // lower price = more favorable for a sell
      st.maePrice = MathMax(st.maePrice, ask); // higher price = more adverse for a sell
   }
   else
   {
      st.mfePrice = MathMax(st.mfePrice, ask);
      st.maePrice = MathMin(st.maePrice, bid);
   }
}

//+------------------------------------------------------------------+
//| Nairobi (EAT, UTC+3, no DST) session handling                    |
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

// Whether the broker is currently observing EU-style DST (last Sunday of
// March 01:00 UTC to last Sunday of October 01:00 UTC), evaluated against
// an approximate UTC time derived from the broker's standard offset.
bool IsBrokerDstActive(datetime serverTime)
{
   if(!InpBrokerUsesDst)
      return false;

   datetime approxUtc = serverTime - (long)(InpBrokerGmtOffsetHours * 3600);
   MqlDateTime dt;
   TimeToStruct(approxUtc, dt);

   datetime dstStart = LastSundayOfMonth(dt.year, 3)  + 3600;
   datetime dstEnd    = LastSundayOfMonth(dt.year, 10) + 3600;
   return (approxUtc >= dstStart && approxUtc < dstEnd);
}

// Converts broker server time to true Nairobi time (EAT, fixed UTC+3),
// automatically compensating for whatever GMT offset / DST the broker's
// own server clock uses, so the trading session always lands on the
// intended real-world Nairobi hours regardless of broker timezone.
datetime GetNairobiTime(datetime serverTime)
{
   double offsetHours = InpBrokerGmtOffsetHours;
   if(IsBrokerDstActive(serverTime))
      offsetHours += 1.0;

   datetime utcTime = serverTime - (long)(offsetHours * 3600);
   return utcTime + 3 * 3600; // Nairobi = UTC+3, year-round
}

// Session window widens/shifts seasonally per spec: 04:00-18:00 Nairobi
// during the summer months, 05:00-19:00 the rest of the year.
bool IsWithinSession()
{
   datetime nairobiNow = GetNairobiTime(TimeCurrent());
   MqlDateTime dt;
   TimeToStruct(nairobiNow, dt);

   bool isSummer = (dt.mon >= InpSummerStartMonth && dt.mon <= InpSummerEndMonth);
   int  startMin  = (isSummer ? InpSummerStartHour : InpWinterStartHour) * 60;
   int  endMin    = (isSummer ? InpSummerEndHour   : InpWinterEndHour)   * 60;
   int  nowMin    = dt.hour * 60 + dt.min;

   return (nowMin >= startMin && nowMin < endMin);
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
      g_lastResetDay = today;
      g_sell.tradesToday = 0; g_sell.doneToday = false;
      g_buy.tradesToday  = 0; g_buy.doneToday  = false;
   }
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
//| Attempts to open one trade for a just-confirmed Retest Candle.    |
//| Entry logic, SL/TP, risk sizing, daily rules and session filter   |
//| all live here — none of it touches the signal-detection state     |
//| machine above.                                                    |
//+------------------------------------------------------------------+
void TryOpen(bool isSell, SSignalState &st)
{
   // One open position per direction at a time (mirrors "one position
   // per signal" and lets the daily win/loss rules track a single
   // outcome before deciding whether a second same-day trade is allowed).
   if(st.positionOpen)
      return;
   if(st.doneToday)
      return;
   if(st.tradesToday >= 2)
      return;
   if(!IsWithinSession())
      return;

   double entry = isSell ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                          : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double sl = st.slLevel;

   // Sanity guard: the indicator's SL level is a high (sell) / low (buy)
   // spanning the reference-to-CC range, so it must sit on the correct
   // side of the current market price for a valid stop.
   if(isSell && sl <= entry) return;
   if(!isSell && sl >= entry) return;

   double dist = MathAbs(entry - sl);
   double tp   = isSell ? entry - dist : entry + dist; // fixed 1:1 R:R

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   entry = NormalizeDouble(entry, digits);
   sl    = NormalizeDouble(sl, digits);
   tp    = NormalizeDouble(tp, digits);

   double point         = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double minStopPoints = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist        = minStopPoints * point;
   if(minDist > 0 && (MathAbs(entry - sl) < minDist || MathAbs(entry - tp) < minDist))
   {
      PrintFormat("LUCC/LDCC EA: skipped %s entry, SL/TP closer than broker's minimum stop distance.",
                  isSell ? "sell" : "buy");
      return;
   }

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;
   double lots = CalcLotSize(dist, riskAmount);
   if(lots <= 0)
      return;

   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);

   bool ok = isSell
      ? g_trade.Sell(lots, _Symbol, entry, sl, tp, "LUCC-RC Sell")
      : g_trade.Buy(lots, _Symbol, entry, sl, tp, "LDCC-RC Buy");

   if(ok)
   {
      st.positionOpen  = true;
      st.tradesToday++;
      ulong dealTicket = g_trade.ResultDeal();
      if(HistoryDealSelect(dealTicket))
         st.positionId = (long)HistoryDealGetInteger(dealTicket, DEAL_POSITION_ID);

      // Trade journal: snapshot everything the position was opened with, so
      // the eventual close event can log a complete, self-contained record.
      double fillPrice      = g_trade.ResultPrice();
      st.entryTime          = TimeCurrent();
      st.entryPrice         = (fillPrice > 0) ? fillPrice : entry;
      st.slPrice             = sl;
      st.tpPrice              = tp;
      st.riskAmount           = riskAmount;
      st.lots                 = lots;
      st.tradeSeqToday        = st.tradesToday;
      st.balanceBeforeEntry   = balance;
      st.mfePrice             = st.entryPrice;
      st.maePrice             = st.entryPrice;
   }
   else
   {
      PrintFormat("LUCC/LDCC EA: %s order failed, retcode=%d",
                  isSell ? "sell" : "buy", g_trade.ResultRetcode());
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
   UpdateDirection(true,  g_sell);
   UpdateDirection(false, g_buy);
}

//+------------------------------------------------------------------+
//| Trade journal — one CSV row per closed trade.                     |
//|                                                                    |
//| R_Realized is what the trade actually made under the current      |
//| fixed 1:1 TP, so by construction it will basically always read    |
//| ~+1 or ~-1 — it does NOT tell you whether a bigger target would   |
//| have worked. MFE_R / MAE_R exist for that: they are NOT capped at |
//| the actual exit. Once a trade closes it moves to a "pending"      |
//| queue (see SPendingLog) where UpdatePendingExcursions() keeps     |
//| extending mfePrice/maePrice for InpExcursionTrackingHours from    |
//| ENTRY, same as if the trade had no stop or target at all, before  |
//| the row is finally written. That's the number to look at when     |
//| deciding what R:R target the next version should use.             |
//+------------------------------------------------------------------+
string CsvEscape(string s)
{
   StringReplace(s, ",", ";");
   return s;
}

void WriteTradeLogHeader()
{
   FileWrite(g_logHandle,
      "Direction", "PositionID",
      "RefCandleTime", "RefHigh", "RefLow",
      "CCTime", "RCTime_TouchTime",
      "EntryTime", "EntryPrice", "SL", "TP",
      "RiskPercent", "RiskAmount", "Lots", "TradeSeqToday",
      "NairobiDate", "NairobiWeekday", "NairobiHour",
      "ExitTime", "ExitPrice", "ExitReason",
      "GrossProfit", "Commission", "Swap", "NetProfit",
      "R_Realized", "MFE_R", "MAE_R",
      "ExcursionWindowHours", "ExcursionComplete",
      "HoldingMinutes", "BalanceBefore", "BalanceAfter");
}

// Queues a just-closed trade for extended tracking rather than writing it
// immediately, so MFE_R/MAE_R can keep growing past the real exit. mfePrice/
// maePrice carry over from st (already tracked live while the position was
// open by UpdateExcursion) so the series is continuous from entry onward.
void QueuePendingLog(bool isSell, const SSignalState &st, long posId,
                      datetime exitTime, double exitPrice, string exitReason,
                      double grossProfit, double commission, double swap)
{
   int n = ArraySize(g_pending);
   ArrayResize(g_pending, n + 1);

   g_pending[n].isSell             = isSell;
   g_pending[n].posId              = posId;
   g_pending[n].refTime            = st.refTime;
   g_pending[n].refHigh            = st.refHigh;
   g_pending[n].refLow             = st.refLow;
   g_pending[n].ccTime             = st.ccTime;
   g_pending[n].rcTime             = st.rcTime;
   g_pending[n].entryTime          = st.entryTime;
   g_pending[n].entryPrice         = st.entryPrice;
   g_pending[n].slPrice            = st.slPrice;
   g_pending[n].tpPrice            = st.tpPrice;
   g_pending[n].riskAmount         = st.riskAmount;
   g_pending[n].lots               = st.lots;
   g_pending[n].tradeSeqToday      = st.tradeSeqToday;
   g_pending[n].balanceBeforeEntry = st.balanceBeforeEntry;
   g_pending[n].exitTime           = exitTime;
   g_pending[n].exitPrice          = exitPrice;
   g_pending[n].exitReason         = exitReason;
   g_pending[n].grossProfit        = grossProfit;
   g_pending[n].commission         = commission;
   g_pending[n].swap               = swap;
   g_pending[n].mfePrice           = st.mfePrice;
   g_pending[n].maePrice           = st.maePrice;

   datetime windowEnd = st.entryTime + InpExcursionTrackingHours * 3600;
   g_pending[n].trackUntil = InpEnableExcursionTracking ? MathMax(exitTime, windowEnd) : exitTime;
}

void FinalizePendingLog(const SPendingLog &p, bool windowComplete)
{
   if(g_logHandle == INVALID_HANDLE)
      return;

   double netProfit    = p.grossProfit + p.commission + p.swap;
   double riskDistance = MathAbs(p.entryPrice - p.slPrice);
   double rRealized    = (p.riskAmount > 0) ? netProfit / p.riskAmount : 0.0;
   double mfeR          = (riskDistance > 0) ? MathAbs(p.entryPrice - p.mfePrice) / riskDistance : 0.0;
   double maeR           = (riskDistance > 0) ? MathAbs(p.entryPrice - p.maePrice) / riskDistance : 0.0;
   double holdingMinutes  = (double)(p.exitTime - p.entryTime) / 60.0;
   double balanceAfter    = p.balanceBeforeEntry + netProfit;

   datetime nairobiEntry = GetNairobiTime(p.entryTime);
   MqlDateTime dt;
   TimeToStruct(nairobiEntry, dt);
   string weekdayNames[7] = {"Sun","Mon","Tue","Wed","Thu","Fri","Sat"};
   string nairobiDate = StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day);

   FileWrite(g_logHandle,
      p.isSell ? "SELL" : "BUY", (string)p.posId,
      TimeToString(p.refTime, TIME_DATE|TIME_MINUTES), DoubleToString(p.refHigh, _Digits), DoubleToString(p.refLow, _Digits),
      TimeToString(p.ccTime, TIME_DATE|TIME_MINUTES), TimeToString(p.rcTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS),
      TimeToString(p.entryTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS), DoubleToString(p.entryPrice, _Digits),
      DoubleToString(p.slPrice, _Digits), DoubleToString(p.tpPrice, _Digits),
      DoubleToString(InpRiskPercent, 2), DoubleToString(p.riskAmount, 2), DoubleToString(p.lots, 2), (string)p.tradeSeqToday,
      nairobiDate, weekdayNames[dt.day_of_week], (string)dt.hour,
      TimeToString(p.exitTime, TIME_DATE|TIME_MINUTES|TIME_SECONDS), DoubleToString(p.exitPrice, _Digits), CsvEscape(p.exitReason),
      DoubleToString(p.grossProfit, 2), DoubleToString(p.commission, 2), DoubleToString(p.swap, 2), DoubleToString(netProfit, 2),
      DoubleToString(rRealized, 3), DoubleToString(mfeR, 3), DoubleToString(maeR, 3),
      (string)InpExcursionTrackingHours, windowComplete ? "true" : "false",
      DoubleToString(holdingMinutes, 1), DoubleToString(p.balanceBeforeEntry, 2), DoubleToString(balanceAfter, 2));
   FileFlush(g_logHandle);
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
//| A direction's open position just closed — record win/loss and     |
//| queue the trade for the trade-journal write (see QueuePendingLog).|
//| "Win" = closed net profit (profit + swap + commission) > 0.       |
//+------------------------------------------------------------------+
void HandlePositionClosed(bool isSell, SSignalState &st, long closedPosId,
                           datetime exitTime, double exitPrice, string exitReason,
                           double grossProfit, double commission, double swap)
{
   if(!st.positionOpen || st.positionId != closedPosId)
      return;

   double netProfit = grossProfit + commission + swap;

   if(InpEnableTradeLog)
      QueuePendingLog(isSell, st, closedPosId, exitTime, exitPrice, exitReason, grossProfit, commission, swap);

   st.positionOpen = false;
   st.positionId   = 0;
   if(netProfit > 0)
      st.doneToday = true; // a win ends this direction's trading for the day
}

//======================================================================
// Event handlers
//======================================================================
int OnInit()
{
   g_trade.SetExpertMagicNumber(InpMagicNumber);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_lastBarTime  = 0;
   g_lastResetDay = 0;
   g_prevMid      = 0.0;
   g_havePrevMid  = false;

   if(InpEnableTradeLog)
   {
      g_logHandle = FileOpen(InpTradeLogFileName, FILE_WRITE | FILE_CSV | FILE_ANSI, ',');
      if(g_logHandle == INVALID_HANDLE)
         PrintFormat("LUCC/LDCC EA: could not open trade log '%s', error=%d", InpTradeLogFileName, GetLastError());
      else
         WriteTradeLogHeader();
   }
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   // Flush whatever excursion data was gathered for trades whose tracking
   // window hadn't finished yet (e.g. the backtest/EA ended first) rather
   // than silently dropping those rows.
   for(int i = ArraySize(g_pending) - 1; i >= 0; i--)
   {
      if(InpEnableTradeLog)
         FinalizePendingLog(g_pending[i], false);
   }
   ArrayFree(g_pending);

   if(g_logHandle != INVALID_HANDLE)
   {
      FileClose(g_logHandle);
      g_logHandle = INVALID_HANDLE;
   }
}

void OnTick()
{
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

   MonitorRetest(true,  g_sell, bid, ask, mid);
   MonitorRetest(false, g_buy,  bid, ask, mid);
   UpdateExcursion(true,  g_sell, bid, ask);
   UpdateExcursion(false, g_buy,  bid, ask);
   if(InpEnableTradeLog)
      UpdatePendingExcursions(bid, ask);

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

   HandlePositionClosed(true,  g_sell, posId, exitTime, exitPrice, exitReason, grossProfit, commission, swap);
   HandlePositionClosed(false, g_buy,  posId, exitTime, exitPrice, exitReason, grossProfit, commission, swap);
}
//+------------------------------------------------------------------+
