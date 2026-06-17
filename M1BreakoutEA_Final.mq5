//+------------------------------------------------------------------+
//|                                          M1BreakoutEA_Final.mq5  |
//|                     Previous Candle Breakout + OCO + Trailing    |
//|                     Micro-account safe edition                   |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//-------------------------------------------------------------------
// Inputs
//-------------------------------------------------------------------
input long   MagicNumber      = 101001;

input double RiskPercent      = 0.25;
input int    EntryBufferPips  = 1;
input int    TrailingPips     = 5;
input int    BreakEvenPips    = 3;
input int    MaxSpreadPips    = 1;
input int    CooldownMinutes  = 15;
input int    StartHour        = 8;
input int    EndHour          = 18;
input double DailyLossPercent = 2.0;

//-------------------------------------------------------------------
// Globals
//-------------------------------------------------------------------
datetime LastBarTime      = 0;
datetime LastTradeBar     = 0;
datetime LastExitTime     = 0;

double DayStartBalance    = 0.0;
int    DayOfYearStored    = -1;

//-------------------------------------------------------------------
// Helpers
//-------------------------------------------------------------------
double Pip()
{
   if(_Digits == 3 || _Digits == 5)
      return _Point * 10.0;
   return _Point;
}

//-------------------------------------------------------------------
bool SpreadOkay()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spreadPips = (ask - bid) / Pip();
   return spreadPips <= MaxSpreadPips;
}

//-------------------------------------------------------------------
bool SessionAllowed()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   return (t.hour >= StartHour && t.hour < EndHour);
}

//-------------------------------------------------------------------
void UpdateDayStartBalance()
{
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   if(DayOfYearStored != t.day_of_year)
   {
      DayOfYearStored = t.day_of_year;
      DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   }
}

//-------------------------------------------------------------------
bool DailyLossExceeded()
{
   if(DayStartBalance <= 0.0)
      return false;
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = ((DayStartBalance - currentBalance) / DayStartBalance) * 100.0;
   return dd >= DailyLossPercent;
}

//-------------------------------------------------------------------
bool CooldownActive()
{
   if(LastExitTime == 0)
      return false;
   return TimeCurrent() < LastExitTime + (CooldownMinutes * 60);
}

//-------------------------------------------------------------------
bool HasOpenPosition()
{
   if(!PositionSelect(_Symbol))
      return false;
   long magic = PositionGetInteger(POSITION_MAGIC);
   return magic == MagicNumber;
}

//-------------------------------------------------------------------
bool HasPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))          continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol)    continue;
      if(OrderGetInteger(ORDER_MAGIC)  != MagicNumber) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
         return true;
   }
   return false;
}

//-------------------------------------------------------------------
void DeleteAllPending()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))          continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol)    continue;
      if(OrderGetInteger(ORDER_MAGIC)  != MagicNumber) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
         trade.OrderDelete(ticket);
   }
}

//-------------------------------------------------------------------
void DeleteOppositePending()
{
   if(!PositionSelect(_Symbol))
      return;

   ENUM_POSITION_TYPE posType =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(!OrderSelect(ticket))          continue;
      if(OrderGetString(ORDER_SYMBOL)  != _Symbol)    continue;
      if(OrderGetInteger(ORDER_MAGIC)  != MagicNumber) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(posType == POSITION_TYPE_BUY  && type == ORDER_TYPE_SELL_STOP)
         trade.OrderDelete(ticket);
      if(posType == POSITION_TYPE_SELL && type == ORDER_TYPE_BUY_STOP)
         trade.OrderDelete(ticket);
   }
}

//-------------------------------------------------------------------
double CalculateLotSize(double entry, double stoploss)
{
   double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney  = balance * RiskPercent / 100.0;
   double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double stopDist   = MathAbs(entry - stoploss);
   double minLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot     = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step       = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(stopDist <= 0.0)
      return minLot;

   double lot = riskMoney / ((stopDist / _Point) * tickValue);
   lot = MathFloor(lot / step) * step;

   // Hard cap to minLot on very small accounts
   if(balance <= 10.0 && lot > minLot)
      lot = minLot;

   lot = MathMax(minLot, lot);
   lot = MathMin(maxLot, lot);

   return NormalizeDouble(lot, 2);
}

//-------------------------------------------------------------------
void ManageTrailing()
{
   if(!PositionSelect(_Symbol))
      return;

   ENUM_POSITION_TYPE type =
      (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl        = PositionGetDouble(POSITION_SL);
   double tp        = PositionGetDouble(POSITION_TP);
   double trail     = TrailingPips  * Pip();
   double beTrigger = BreakEvenPips * Pip();
   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask       = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(type == POSITION_TYPE_BUY)
   {
      double profit = bid - openPrice;

      // Move to break-even
      if(profit >= beTrigger && (sl < openPrice || sl == 0))
         trade.PositionModify(_Symbol, openPrice, tp);

      // Trail
      double newSL = bid - trail;
      if(newSL > sl && profit > trail)
         trade.PositionModify(_Symbol, NormalizeDouble(newSL, _Digits), tp);
   }

   if(type == POSITION_TYPE_SELL)
   {
      double profit = openPrice - ask;

      // Move to break-even
      if(profit >= beTrigger && (sl > openPrice || sl == 0))
         trade.PositionModify(_Symbol, openPrice, tp);

      // Trail
      double newSL = ask + trail;
      if((sl == 0 || newSL < sl) && profit > trail)
         trade.PositionModify(_Symbol, NormalizeDouble(newSL, _Digits), tp);
   }
}

//-------------------------------------------------------------------
void PlaceBreakoutOrders()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance < 5.0)
      return;

   double prevHigh = iHigh(_Symbol, PERIOD_M1, 1);
   double prevLow  = iLow (_Symbol, PERIOD_M1, 1);

   // Skip tiny-range candles
   double rangePips = (prevHigh - prevLow) / Pip();
   if(rangePips < 3.0)
      return;

   double buffer    = EntryBufferPips * Pip();
   double buyPrice  = NormalizeDouble(prevHigh + buffer, _Digits);
   double sellPrice = NormalizeDouble(prevLow  - buffer, _Digits);

   int    stopLevel    = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDistance  = stopLevel * _Point;

   if((buyPrice - sellPrice) < minDistance)
      return;

   double lot = CalculateLotSize(buyPrice, sellPrice);

   trade.SetExpertMagicNumber(MagicNumber);
   trade.BuyStop (lot, buyPrice,  _Symbol, sellPrice, 0, ORDER_TIME_GTC, 0, "BUY_STOP");
   trade.SellStop(lot, sellPrice, _Symbol, buyPrice,  0, ORDER_TIME_GTC, 0, "SELL_STOP");

   LastTradeBar = iTime(_Symbol, PERIOD_M1, 1);
}

//-------------------------------------------------------------------
void CheckForClosedPosition()
{
   static bool hadPosition = false;
   bool hasPosition = HasOpenPosition();

   if(hadPosition && !hasPosition)
      LastExitTime = TimeCurrent();

   hadPosition = hasPosition;
}

//-------------------------------------------------------------------
int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   DayOfYearStored = t.day_of_year;

   return(INIT_SUCCEEDED);
}

//-------------------------------------------------------------------
void OnTick()
{
   UpdateDayStartBalance();
   CheckForClosedPosition();
   ManageTrailing();

   if(HasOpenPosition())
   {
      DeleteOppositePending();
      return;
   }

   if(DailyLossExceeded()) return;
   if(CooldownActive())    return;
   if(!SessionAllowed())   return;
   if(!SpreadOkay())       return;

   datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
   if(currentBar == LastBarTime)
      return;
   LastBarTime = currentBar;

   if(HasPendingOrders())
      return;

   if(LastTradeBar == iTime(_Symbol, PERIOD_M1, 1))
      return;

   PlaceBreakoutOrders();
}
