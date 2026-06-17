//+------------------------------------------------------------------+
//|                 M1BreakoutEA_MicroAccount.mq5                   |
//+------------------------------------------------------------------+
#property strict

#include <Trade/Trade.mqh>

CTrade trade;

//-------------------- INPUTS --------------------
input long MagicNumber = 101001;

input double RiskPercent = 0.25;

input int EntryBufferPips = 1;
input int TrailingPips = 5;
input int BreakEvenPips = 3;

input int MaxSpreadPips = 1;
input int CooldownMinutes = 15;

input int StartHour = 8;
input int EndHour = 18;

input double DailyLossPercent = 2.0;

//-------------------- GLOBALS --------------------
datetime LastBarTime = 0;
datetime LastExitTime = 0;

double DayStartBalance = 0;
int DayOfYearStored = - 1;

//-------------------- UTIL --------------------
double Pip()
{
    return(_Digits == 3 || _Digits == 5) ? _Point * 10 : _Point;
}

//-------------------- SESSION --------------------
bool SessionAllowed()
{
    MqlDateTime t;
    TimeToStruct(TimeCurrent(), t);
    return(t.hour >= StartHour && t.hour < EndHour);
}

//-------------------- SPREAD --------------------
bool SpreadOkay()
{
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    return((ask - bid) / Pip()) <= MaxSpreadPips;
}

//-------------------- DAILY RESET --------------------
void UpdateDay()
{
    MqlDateTime t;
    TimeToStruct(TimeCurrent(), t);

    if(DayOfYearStored != t.day_of_year)
    {
        DayOfYearStored = t.day_of_year;
        DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    }
}

//-------------------- DRAWDOWN --------------------
bool DailyLossExceeded()
{
    if(DayStartBalance <= 0) return false;

    double eq = AccountInfoDouble(ACCOUNT_EQUITY);
    double dd = (DayStartBalance - eq) / DayStartBalance * 100.0;

    return dd >= DailyLossPercent;
}

//-------------------- POSITION CHECK --------------------
bool HasPosition()
{
    if(!PositionSelect(_Symbol)) return false;
    return PositionGetInteger(POSITION_MAGIC) == MagicNumber;
}

//-------------------- PENDING CHECK --------------------
bool HasPending()
{
    for(int i = OrdersTotal() - 1;i >= 0;i--)
    {
        ulong ticket = OrderGetTicket(i);
        if(!OrderSelect(ticket)) continue;

        if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
        if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

        ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

        if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP)
        return true;
    }
    return false;
}

//-------------------- CLOSE TRACK --------------------
void TrackClose()
{
    static bool had = false;
    bool now = HasPosition();

    if(had && !now)
    LastExitTime = TimeCurrent();

    had = now;
}

//-------------------- COOLDOWN --------------------
bool Cooldown()
{
    return(LastExitTime > 0 &&
    TimeCurrent() < LastExitTime + CooldownMinutes * 60);
}

//-------------------- LOT SIZE (SAFE MICRO) --------------------
double Lot(double entry, double sl)
{
    double bal = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskMoney = bal * RiskPercent / 100.0;

    double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double dist = MathAbs(entry - sl);

    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(dist <= 0 || riskMoney <= 0) return minLot;

    double lot = riskMoney / ((dist / _Point) * tickValue);

    lot = MathFloor(lot / step) * step;

    return MathMax(minLot, lot);
}

//-------------------- PLACE ORDERS --------------------
void PlaceOrders()
{
    double h = iHigh(_Symbol, PERIOD_M1, 1);
    double l = iLow(_Symbol, PERIOD_M1, 1);

    double buffer = EntryBufferPips * Pip();

    double buy = h + buffer;
    double sell = l - buffer;

    if((buy - sell) < (SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point))
    return;

    double lot = Lot(buy, sell);

    trade.SetExpertMagicNumber(MagicNumber);

    trade.BuyStop(lot, buy, _Symbol, sell, 0, ORDER_TIME_GTC, 0, "BUY");
    trade.SellStop(lot, sell, _Symbol, buy, 0, ORDER_TIME_GTC, 0, "SELL");

    LastBarTime = iTime(_Symbol, PERIOD_M1, 0);
}

//-------------------- TRAILING --------------------
void Trail()
{
    if(!PositionSelect(_Symbol)) return;

    double open = PositionGetDouble(POSITION_PRICE_OPEN);
    double sl = PositionGetDouble(POSITION_SL);

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    double trail = TrailingPips * Pip();

    ENUM_POSITION_TYPE type =    (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    if(type == POSITION_TYPE_BUY)
    {
        double newSL = bid - trail;
        if(newSL > sl)
        trade.PositionModify(_Symbol, newSL, 0);
    }
    else
    {
        double newSL = ask + trail;
        if(sl == 0 || newSL < sl)
        trade.PositionModify(_Symbol, newSL, 0);
    }
}

//-------------------- INIT --------------------
int OnInit()
{
    trade.SetExpertMagicNumber(MagicNumber);

    DayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);

    MqlDateTime t;
    TimeToStruct(TimeCurrent(), t);
    DayOfYearStored = t.day_of_year;

    return INIT_SUCCEEDED;
}

//-------------------- MAIN --------------------
void OnTick()
{
    UpdateDay();
    TrackClose();

    Trail();

    if(!SessionAllowed()) return;
    if(!SpreadOkay()) return;
    if(DailyLossExceeded()) return;
    if(Cooldown()) return;

    datetime bar = iTime(_Symbol, PERIOD_M1, 0);

    if(bar == LastBarTime) return;

    if(HasPosition())
    return;

    if(HasPending())
    return;

    PlaceOrders();
}