//+------------------------------------------------------------------+
//|                    LUCC_LDCC_Confirmation_Retest_EA.mq5          |
//|                                                                    |
//| Expert Advisor port of "LUCC / LDCC Confirmation & Retest         |
//| Indicator" (Pine v6). The signal-detection logic below is a       |
//| line-for-line mirror of the indicator: same LUCC/LDCC candidate   |
//| search, same PROTECTED / NOT-CONTAINED filters, same Confirmation |
//| Candle (CC) and Retest Candle (RC) rules, evaluated only on fully |
//| closed H1 bars (never the forming bar) so it cannot repaint.      |
//|                                                                    |
//| Offset convention: BarX(0) = the bar that JUST closed (equivalent |
//| to offset 0 / "close[0]" at the instant barstate.isconfirmed was  |
//| true in the indicator). BarX(i) = i bars before that. In MQL5     |
//| shift terms this is always (i + 1), because shift 0 is the        |
//| still-forming live bar, which this EA never reads.                |
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
};

SSignalState g_sell;   // SELL side, driven by the Bullish LUCC
SSignalState g_buy;    // BUY side,  driven by the Bearish LDCC

CTrade   g_trade;
datetime g_lastBarTime  = 0;
datetime g_lastResetDay = 0;

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
//| Runs the full state machine for one direction on the just-closed |
//| bar: (re)selection/invalidation of the reference candle, then    |
//| the Confirmation Candle check, then the Retest Candle check —    |
//| in that order, exactly as the indicator evaluates them.          |
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

   // Retest Candle — strictly after the CC bar, identical touch formula
   // for both sides (high >= level and low <= level).
   if(st.ccTime != 0 && st.rcTime == 0 && BarTime(0) > st.ccTime)
   {
      double level = isSell ? st.refLow : st.refHigh;
      if(BarHigh(0) >= level && BarLow(0) <= level)
      {
         st.rcTime = BarTime(0);
         TryOpen(isSell, st);
      }
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
//| lots = (balance * risk%) / (SL distance expressed in money/lot)   |
//+------------------------------------------------------------------+
double CalcLotSize(double slDistance)
{
   if(slDistance <= 0)
      return 0.0;

   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskAmount = balance * InpRiskPercent / 100.0;

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

   double lots = CalcLotSize(dist);
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
//| A direction's open position just closed — record win/loss.       |
//| "Win" = closed net profit (profit + swap + commission) > 0.       |
//+------------------------------------------------------------------+
void HandlePositionClosed(SSignalState &st, long closedPosId, double profit)
{
   if(!st.positionOpen || st.positionId != closedPosId)
      return;

   st.positionOpen = false;
   st.positionId   = 0;
   if(profit > 0)
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
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
}

void OnTick()
{
   CheckDailyReset();

   datetime curBarTime = iTime(_Symbol, PERIOD_H1, 0);
   if(curBarTime != g_lastBarTime)
   {
      g_lastBarTime = curBarTime;
      ProcessNewBar();
   }
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

   long   posId  = (long)HistoryDealGetInteger(trans.deal, DEAL_POSITION_ID);
   double profit = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                 + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                 + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   HandlePositionClosed(g_sell, posId, profit);
   HandlePositionClosed(g_buy,  posId, profit);
}
//+------------------------------------------------------------------+
