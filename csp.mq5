//+------------------------------------------------------------------+
//|                                  XAUUSD_StructureTrend_EA.mq5     |
//|                                                                    |
//|  Strategy:                                                        |
//|   - H1 trend filter: EMA50 vs EMA200                              |
//|   - M15 structure: Break of Structure (BoS) detection             |
//|   - Entry: pullback into last Order Block after BoS, w/ trend     |
//|   - SL: ATR-buffered beyond OB/swing point                        |
//|   - Sizing: 1% account risk (configurable), ATR/SL distance based |
//|   - Management: ATR-based trailing stop, no fixed TP              |
//|   - Filters: session window + high-impact news time blackout      |
//|                                                                    |
//|  Built for: Exness / Vantage XAUUSD (auto-detects attached symbol)|
//+------------------------------------------------------------------+
#property copyright "Custom EA"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
CTrade trade;

//================== INPUTS ==================

input group "=== Risk Management ==="
input double   RiskPercent          = 1.5;      // Risk % of account equity per trade
input double   ATR_SL_Multiplier    = 1.5;      // ATR multiplier for SL buffer beyond structure point
input double   ATR_Trail_Multiplier = 2.0;      // ATR multiplier for trailing stop distance
input double   ATR_Trail_Step_Mult  = 0.5;      // ATR multiplier - minimum step before trail moves (reduces over-trading the trail)
input double   MaxSpreadPoints      = 350;       // Max allowed spread (in points) to allow new entries

input group "=== Trend Filter (H1) ==="
input int      EMA_Fast_Period      = 50;
input int      EMA_Slow_Period      = 200;
input ENUM_TIMEFRAMES TrendTF       = PERIOD_H1;

input group "=== Structure Detection (M15) ==="
input ENUM_TIMEFRAMES StructureTF   = PERIOD_M15;
input int      SwingLookback        = 10;       // Bars left/right to confirm a swing high/low
input int      MaxBarsSinceBOS      = 12;       // Max bars since BoS to still look for OB pullback entry
input int      ATR_Period           = 14;

input group "=== Order Block Entry ==="
input double   OB_ZoneBufferATR     = 0.25;     // Extra ATR buffer added around OB zone for entry tolerance

input group "=== Session Filter (Broker Server Time) ==="
input bool     UseSessionFilter     = true;
input int      SessionStartHour     = 7;        // London open approx (server time - adjust per broker)
input int      SessionEndHour       = 21;       // Avoid dead Asian session
input bool     UseNewsBlackout      = true;
input int      NewsBlackoutMinsBefore = 30;     // Minutes before a flagged news time to stop new entries
input int      NewsBlackoutMinsAfter  = 30;      // Minutes after

input group "=== Manual News Times (server time, format HH:MM, comma separated) ==="
input string   NewsTimesToday       = "";       // e.g. "13:30,18:00" - set daily for NFP/CPI/FOMC manually, or leave blank

input group "=== Trade Management ==="
input int      MagicNumber          = 778899;
input int      MaxOpenTrades        = 1;
input double   MinLot               = 0.01;
input double   MaxLot               = 5.0;

//================== GLOBALS ==================
int    emaFastHandle, emaSlowHandle, atrHandleStruct, atrHandleTrail;
string sym;
datetime lastBarTime = 0;

// Structure tracking
double lastSwingHigh = 0, lastSwingLow = 0;
datetime lastSwingHighTime = 0, lastSwingLowTime = 0;
bool   bosUpActive = false, bosDownActive = false;
datetime bosUpTime = 0, bosDownTime = 0;
double obZoneTop = 0, obZoneBottom = 0; // last order block zone after BoS

//+------------------------------------------------------------------+
int OnInit()
  {
   sym = Symbol(); // auto-detect attached symbol - works for XAUUSD, XAUUSDm, GOLD, etc.

   emaFastHandle  = iMA(sym, TrendTF, EMA_Fast_Period, 0, MODE_EMA, PRICE_CLOSE);
   emaSlowHandle  = iMA(sym, TrendTF, EMA_Slow_Period, 0, MODE_EMA, PRICE_CLOSE);
   atrHandleStruct= iATR(sym, StructureTF, ATR_Period);
   atrHandleTrail = iATR(sym, StructureTF, ATR_Period);

   if(emaFastHandle==INVALID_HANDLE || emaSlowHandle==INVALID_HANDLE || atrHandleStruct==INVALID_HANDLE)
     {
      Print("ERROR: Failed to create indicator handles. Check symbol/timeframe availability.");
      return(INIT_FAILED);
     }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(50);

   Print("EA initialized on symbol: ", sym, " | Digits: ", (int)SymbolInfoInteger(sym, SYMBOL_DIGITS),
         " | Point: ", SymbolInfoDouble(sym, SYMBOL_POINT));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   IndicatorRelease(emaFastHandle);
   IndicatorRelease(emaSlowHandle);
   IndicatorRelease(atrHandleStruct);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // Manage existing positions every tick (trailing stop)
   ManageOpenPositions();

   // Only evaluate new entries on a new M15 bar close
   datetime curBarTime = iTime(sym, StructureTF, 0);
   if(curBarTime == lastBarTime)
      return;
   lastBarTime = curBarTime;

   UpdateStructure();

   if(CountOpenPositions() >= MaxOpenTrades)
      return;

   if(!PassesFilters())
      return;

   int trendBias = GetTrendBias(); // 1 = up, -1 = down, 0 = none
   if(trendBias == 0)
      return;

   CheckForEntry(trendBias);
  }

//+------------------------------------------------------------------+
//| Determine H1 trend bias via EMA50 vs EMA200                       |
//+------------------------------------------------------------------+
int GetTrendBias()
  {
   double emaFast[], emaSlow[];
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   if(CopyBuffer(emaFastHandle, 0, 0, 3, emaFast) < 3) return 0;
   if(CopyBuffer(emaSlowHandle, 0, 0, 3, emaSlow) < 3) return 0;

   if(emaFast[0] > emaSlow[0] && emaFast[1] > emaSlow[1])
      return 1;
   if(emaFast[0] < emaSlow[0] && emaFast[1] < emaSlow[1])
      return -1;

   return 0;
  }

//+------------------------------------------------------------------+
//| Update swing points and detect Break of Structure on M15          |
//+------------------------------------------------------------------+
void UpdateStructure()
  {
   int bars = SwingLookback * 2 + 5;
   double high[], low[];
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);

   if(CopyHigh(sym, StructureTF, 0, bars, high) < bars) return;
   if(CopyLow(sym, StructureTF, 0, bars, low) < bars) return;

   // Check bar at index SwingLookback for swing high/low (confirmed swing, not repainting)
   int idx = SwingLookback;
   bool isSwingHigh = true, isSwingLow = true;

   for(int i = 1; i <= SwingLookback; i++)
     {
      if(high[idx] < high[idx-i] || high[idx] < high[idx+i]) isSwingHigh = false;
      if(low[idx]  > low[idx-i]  || low[idx]  > low[idx+i])  isSwingLow = false;
     }

   datetime swingTime = iTime(sym, StructureTF, idx);

   if(isSwingHigh && swingTime != lastSwingHighTime)
     {
      lastSwingHigh = high[idx];
      lastSwingHighTime = swingTime;
     }
   if(isSwingLow && swingTime != lastSwingLowTime)
     {
      lastSwingLow = low[idx];
      lastSwingLowTime = swingTime;
     }

   // Detect BoS: current close breaks last confirmed swing high/low
   double closePrice = iClose(sym, StructureTF, 1); // last fully closed bar

   if(lastSwingHigh > 0 && closePrice > lastSwingHigh && !bosUpActive)
     {
      bosUpActive = true;
      bosDownActive = false;
      bosUpTime = iTime(sym, StructureTF, 1);
      SetOrderBlockZone(true, 1);
      Print("BoS UP detected at ", closePrice, " broke swing high ", lastSwingHigh);
     }

   if(lastSwingLow > 0 && closePrice < lastSwingLow && !bosDownActive)
     {
      bosDownActive = true;
      bosUpActive = false;
      bosDownTime = iTime(sym, StructureTF, 1);
      SetOrderBlockZone(false, 1);
      Print("BoS DOWN detected at ", closePrice, " broke swing low ", lastSwingLow);
     }

   // Expire BoS state if too many bars have passed without a pullback entry
   if(bosUpActive && BarsSince(bosUpTime) > MaxBarsSinceBOS) bosUpActive = false;
   if(bosDownActive && BarsSince(bosDownTime) > MaxBarsSinceBOS) bosDownActive = false;
  }

//+------------------------------------------------------------------+
//| Identify the order block (last opposing candle before the break) |
//+------------------------------------------------------------------+
void SetOrderBlockZone(bool bullish, int bosBarShift)
  {
   // Scan backward from the BoS bar for the last opposite-colored candle = the OB
   for(int i = bosBarShift; i < bosBarShift + 15; i++)
     {
      double o = iOpen(sym, StructureTF, i);
      double c = iClose(sym, StructureTF, i);
      bool isBearCandle = c < o;
      bool isBullCandle = c > o;

      if(bullish && isBearCandle)
        {
         obZoneTop    = iHigh(sym, StructureTF, i);
         obZoneBottom = iLow(sym, StructureTF, i);
         return;
        }
      if(!bullish && isBullCandle)
        {
         obZoneTop    = iHigh(sym, StructureTF, i);
         obZoneBottom = iLow(sym, StructureTF, i);
         return;
        }
     }
  }

//+------------------------------------------------------------------+
int BarsSince(datetime t)
  {
   return iBarShift(sym, StructureTF, t, false);
  }

//+------------------------------------------------------------------+
//| Entry logic: price pulls back into OB zone after BoS, trend-aligned|
//+------------------------------------------------------------------+
void CheckForEntry(int trendBias)
  {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandleStruct, 0, 0, 2, atr) < 2) return;
   double atrVal = atr[0];
   double buffer = atrVal * OB_ZoneBufferATR;

   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);

   // LONG setup: trend up + BoS up active + price pulled back into OB zone
   if(trendBias == 1 && bosUpActive && obZoneTop > 0)
     {
      bool inZone = (ask <= obZoneTop + buffer && ask >= obZoneBottom - buffer);
      if(inZone)
        {
         double slPoint = obZoneBottom - (atrVal * ATR_SL_Multiplier);
         OpenTrade(ORDER_TYPE_BUY, slPoint, atrVal);
         bosUpActive = false; // consume the signal
        }
     }

   // SHORT setup: trend down + BoS down active + price pulled back into OB zone
   if(trendBias == -1 && bosDownActive && obZoneBottom > 0)
     {
      bool inZone = (bid >= obZoneBottom - buffer && bid <= obZoneTop + buffer);
      if(inZone)
        {
         double slPoint = obZoneTop + (atrVal * ATR_SL_Multiplier);
         OpenTrade(ORDER_TYPE_SELL, slPoint, atrVal);
         bosDownActive = false; // consume the signal
        }
     }
  }

//+------------------------------------------------------------------+
//| Calculate lot size based on % risk and SL distance                |
//+------------------------------------------------------------------+
double CalcLotSize(double entryPrice, double slPrice)
  {
   double riskAmount = AccountInfoDouble(ACCOUNT_EQUITY) * (RiskPercent / 100.0);
   double slDistance = MathAbs(entryPrice - slPrice);

   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);

   if(tickSize <= 0 || slDistance <= 0) return MinLot;

   double valuePerPriceUnit = tickValue / tickSize; // value of 1.0 price unit move for 1 lot
   double slValuePerLot = slDistance * valuePerPriceUnit;

   if(slValuePerLot <= 0) return MinLot;

   double lots = riskAmount / slValuePerLot;

   double lotStep = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double brokerMinLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double brokerMaxLot = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);

   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, MathMax(MinLot, brokerMinLot));
   lots = MathMin(lots, MathMin(MaxLot, brokerMaxLot));

   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double slPrice, double atrVal)
  {
   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(sym, SYMBOL_ASK) : SymbolInfoDouble(sym, SYMBOL_BID);
   double lots = CalcLotSize(price, slPrice);

   if(lots <= 0)
     {
      Print("Lot size calculation returned 0 - skipping trade.");
      return;
     }

   bool result;
   if(type == ORDER_TYPE_BUY)
      result = trade.Buy(lots, sym, price, slPrice, 0, "StructureTrend_BUY");
   else
      result = trade.Sell(lots, sym, price, slPrice, 0, "StructureTrend_SELL");

   if(!result)
      Print("Order failed: ", trade.ResultRetcodeDescription());
   else
      Print("Order opened: ", EnumToString(type), " lots=", lots, " SL=", slPrice);
  }

//+------------------------------------------------------------------+
//| Trail SL on open positions using ATR distance                     |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(atrHandleTrail, 0, 0, 2, atr) < 2) return;
   double atrVal = atr[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != sym) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      long type = PositionGetInteger(POSITION_TYPE);
      double curSL = PositionGetDouble(POSITION_SL);
      double curPrice = (type == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK);

      double trailDist = atrVal * ATR_Trail_Multiplier;
      double minStep    = atrVal * ATR_Trail_Step_Mult;

      if(type == POSITION_TYPE_BUY)
        {
         double newSL = curPrice - trailDist;
         if(newSL > curSL + minStep && newSL > PositionGetDouble(POSITION_PRICE_OPEN))
            trade.PositionModify(ticket, NormalizeDouble(newSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)), 0);
        }
      else if(type == POSITION_TYPE_SELL)
        {
         double newSL = curPrice + trailDist;
         if((curSL == 0 || newSL < curSL - minStep) && newSL < PositionGetDouble(POSITION_PRICE_OPEN))
            trade.PositionModify(ticket, NormalizeDouble(newSL, (int)SymbolInfoInteger(sym, SYMBOL_DIGITS)), 0);
        }
     }
  }

//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int count = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket <= 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) == sym && PositionGetInteger(POSITION_MAGIC) == MagicNumber)
         count++;
     }
   return count;
  }

//+------------------------------------------------------------------+
//| Spread + Session + News filters                                   |
//+------------------------------------------------------------------+
bool PassesFilters()
  {
   // Spread filter
   double spreadPoints = (double)SymbolInfoInteger(sym, SYMBOL_SPREAD);
   if(spreadPoints > MaxSpreadPoints)
     {
      return false;
     }

   // Session filter
   if(UseSessionFilter)
     {
      MqlDateTime t;
      TimeToStruct(TimeCurrent(), t);
      int hour = t.hour;
      if(SessionStartHour <= SessionEndHour)
        {
         if(hour < SessionStartHour || hour >= SessionEndHour) return false;
        }
      else // overnight wrap (not typical here but handled)
        {
         if(hour < SessionStartHour && hour >= SessionEndHour) return false;
        }
     }

   // News blackout filter (manual times entered daily by user)
   if(UseNewsBlackout && StringLen(NewsTimesToday) > 0)
     {
      if(IsInNewsBlackout()) return false;
     }

   return true;
  }
#import "cl"

#import

//+------------------------------------------------------------------+
bool IsInNewsBlackout()
  {
   string times[];
   int cnt = StringSplit(NewsTimesToday, ',', times);
   if(cnt <= 0) return false;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   for(int i = 0; i < cnt; i++)
     {
      string t = times[i];
      StringTrimLeft(t); StringTrimRight(t);
      string parts[];
      if(StringSplit(t, ':', parts) != 2) continue;

      int h = (int)StringToInteger(parts[0]);
      int m = (int)StringToInteger(parts[1]);

      MqlDateTime newsTime = now;
      newsTime.hour = h;
      newsTime.min  = m;
      newsTime.sec  = 0;
      datetime newsDT = StructToTime(newsTime);

      datetime windowStart = newsDT - NewsBlackoutMinsBefore * 60;
      datetime windowEnd   = newsDT + NewsBlackoutMinsAfter * 60;

      if(TimeCurrent() >= windowStart && TimeCurrent() <= windowEnd)
         return true;
     }
   return false;
  }
//+------------------------------------------------------------------+