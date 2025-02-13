#property copyright "Copyright © Jan Derluyn"
#property version   "1.0"
#property description "Developer's WhatsApp +380731961358"

#include <Symbol.mqh>

 
input double RenkoBoxSize = 100;
input bool ShowWicks = false;
      bool EmulateOnLineChart = true;
input string OutputSymbolName = "";
input bool Reset = false;
      bool CloseTimeMode = false;
      bool DropTicksOutsideBars = true;
      datetime StartFrom = iTime(_Symbol,PERIOD_D1,5);
      datetime StopAt = 0;
      int LogLevel = 0;
      bool SkipOverflows = false;
double SetPoint = 0, TrPoint = 0, Ball = 0, swc = 1;
#define  Inf 9999999999
double HH = 0, LL = Inf;
double Mx = 0, Mn = Inf;
 
datetime MyTimer = -1;
bool _StopAll, _JustCreated, _FirstRun;
string _SymbolName;

const long DAY_LONG = 60 * 60 * 24;

 

#define TTSD(x) TimeToString((datetime)(x), TIME_DATE)
#define TTSM(x) TimeToString((datetime)(x), TIME_DATE|TIME_MINUTES)
#define TTSS(x) TimeToString((datetime)(x), TIME_DATE|TIME_MINUTES|TIME_SECONDS)

#define DefineBroker(NAME,TYPE) \
class NAME##Broker \
{ \
  public: \
    TYPE operator[](int b) \
    { \
      return i##NAME(_Symbol, _Period, b); \
    } \
}; \
NAME##Broker NAME;

DefineBroker(Time, datetime);
DefineBroker(Open, double);
DefineBroker(High, double);
DefineBroker(Low, double);
DefineBroker(Close, double);
DefineBroker(Volume, long);


#define TICK_FLAG_DATAFEED_NO_BID 128

string TickFlags(const uint flags)
{
  uint temp = flags;
  string result = "";
  string s[] = {"B", "A", "L", "V", "+", "-", "!"};
  uint   f[] = {TICK_FLAG_BID, TICK_FLAG_ASK, TICK_FLAG_LAST, TICK_FLAG_VOLUME, TICK_FLAG_BUY, TICK_FLAG_SELL, TICK_FLAG_DATAFEED_NO_BID};
  for(int i = 0; i < ArraySize(s); i++)
  {
    if((temp & f[i]) != 0)
    {
      result += s[i];
      temp &= ~f[i];
    }
  }
  if(temp != 0)
  {
    result += "(" + (string)temp + ") " + (string)flags;
  }
  return result;
}


 
class Renko
{
  private:
    double prevLow;
    double dnWick;
    double prevHigh;
    double upWick;
    double prevOpen;
    double prevClose;
    ulong curVolume;
    ulong curRealVolume;
    datetime prevTime;
    int sendSpread;
    double curHigh, curLow;
    
    static double boxPoints;

    int recordCount;
    int overflowCount;
    int badTickCount;
    
    datetime firstQuoteTime;
    datetime lastQuoteTime;
    MqlRates ending[3];
    
  protected:
    bool incrementTime(const datetime time)
    {
      if(time - prevTime >= 60) // new M1 bar/box
      {
        prevTime = (datetime)((long)time / 60 * 60);
      }
      else
      {
        if(!SkipOverflows) prevTime += 60;
        overflowCount++;
        if(LogLevel > 1) Print((SkipOverflows ? "skpvrflw " : "overflow "), TTSS(prevTime), " ", TTSS(time));
        return true;
      }
      return false;
    }

    void doWriteStruct(const datetime dtTime, const double dOpen, const double dHigh, const double dLow, const double dClose, const double dVol, const double dRealVol, const int spread)
    {
      MqlRates rate[1];
      rate[0].time = dtTime;
      rate[0].open = dOpen;
      rate[0].high = dHigh;
      rate[0].low = dLow;
      rate[0].close = dClose;
      rate[0].tick_volume = (long)dVol;
      rate[0].spread = spread;
      rate[0].real_volume = (long)dRealVol;
    
      if(rate[0].tick_volume < 4) rate[0].tick_volume = 4; // open, close, high, low
      
      if(CustomRatesUpdate(_SymbolName, rate) == 0)
      {
        Alert("Error on writing custom record: ", GetLastError());
        ArrayPrint(rate);
        _StopAll = true;
      }
      recordCount++;
    }
    
    bool compareDoubles(const double number1, const double number2)
    {
      if(MathAbs(number1 - number2)<(2*_Point)) return(true);
      else return(false);
    }
  
  public:
    void reset()
    {
      prevLow = dnWick = prevHigh = upWick = prevOpen = prevClose = 0;
      curVolume = curRealVolume = 0;
      prevTime = 0;
      sendSpread = 0;
      curHigh = curLow = 0;
      
      recordCount = 0;
      overflowCount = 0;
      badTickCount = 0;
      
      firstQuoteTime = 0;
      lastQuoteTime = 0;
    }
    
    int getBoxCount() const
    {
      return recordCount;
    }
    
    int getOverflowCount() const
    {
      return overflowCount;
    }
    
    int getBadTickCount() const
    {
      return badTickCount;
    }
    
    datetime checkEnding()
    {
      int b = Bars(_SymbolName, PERIOD_M1);
      Print("Found ", b, " boxes");

      MqlRates firstBar[1];// = {0};
      
      if(CopyRates(_SymbolName, PERIOD_M1, b - 1, 1, firstBar) > 0)
      {
        Print("First box in renko ", _SymbolName, ": ", firstBar[0].time);
        firstQuoteTime = firstBar[0].time;
      }
    
      int n = CopyRates(_SymbolName, PERIOD_M1, 0, 3, ending);
      if(n == 3)
      {
        lastQuoteTime = ending[2].time; // ending[2] is incomplete box
        // if CloseTimeMode is on, box is completed, but we need to process underlying bar anew anyway
        
        // search for first lastQuoteTime
        datetime rawBarTime[1];
        // find symbol/period bar which contains incomplete renko
        if(CopyTime(_Symbol, PERIOD_CURRENT, lastQuoteTime, 1, rawBarTime) == 1)
        {
          Print("Last box: ", lastQuoteTime, " -> maps to bar ", rawBarTime[0]);
          lastQuoteTime = rawBarTime[0];
        }
        else
        {
          Print("CopyTime failed, ", lastQuoteTime, " ", GetLastError());
          return (datetime)(TimeCurrent() + DAY_LONG * 365); // day in future means timeout
        }
        ArrayPrint(ending);

        if(CustomTicksDelete(_SymbolName, (long)lastQuoteTime * 1000, LONG_MAX) == -1)
        {
          Print("CustomTicksDelete failed:", GetLastError());
          lastQuoteTime = 0;
        }
        
        // NB. MT5 bug is suspected: sometimes renko rates are deleted for bars
        // earlier than lastQuoteTime, so that renko quotes have a gap at continuation mark
        if(CustomRatesDelete(_SymbolName, lastQuoteTime, LONG_MAX) == -1)
        {
          Print("CustomRatesDelete failed:", GetLastError());
          lastQuoteTime = 0;
        }

        n = CopyRates(_SymbolName, PERIOD_M1, 0, 3, ending);
        if(n == 3)
        {
          ArrayPrint(ending);
        }

      }
      else
      {
        Print("CopyRates returned: ", n, ", code: ", GetLastError()); // will reset custom symbol
      }
      return lastQuoteTime;
    }
    
    void doReset()
    {
      Print("Resetting range ", firstQuoteTime, " - ", lastQuoteTime);
      ResetLastError();
      int deleted = CustomRatesDelete(_SymbolName, 0, LONG_MAX);
      int err = GetLastError();
      if(err != ERR_SUCCESS)
      {
        Alert("CustomRatesDelete at ", lastQuoteTime, " failed, ", err, ", please, restart the expert!");
        _StopAll = true;
        return;
      }
      else
      {
        Print("Rates deleted: ", deleted);
      }
      
      ResetLastError();
      deleted = CustomTicksDelete(_SymbolName, 0, LONG_MAX);
      if(deleted == -1)
      {
        Print("CustomTicksDelete failed ", GetLastError());
      }
      else
      {
        Print("Ticks deleted: ", deleted);
      }
    
      lastQuoteTime = 0;
    }
    
    void continueFrom(const datetime time)
    {
      // if this is a continuation, adjust it so that it points to a bar for latest renkobox
      if(time > 0)
      {
        const int idx = 2;
        // update all variables according to latest renkobox
        if(ending[idx].open < ending[idx].close) // up
        {
          prevLow = ending[idx].open;
          prevHigh = prevLow + boxPoints;
          prevOpen = prevLow;
          prevClose = prevHigh;
          curHigh = prevHigh;
          curLow = prevLow;
        }
        else                                 // down
        {
          prevHigh = ending[idx].open;
          prevLow = prevHigh - boxPoints;
          prevOpen = prevHigh;
          prevClose = prevLow;
          curHigh = prevHigh;
          curLow = prevLow;
        }
        
        dnWick = ending[2].low;
        upWick = ending[2].high;
        curVolume = ending[2].tick_volume;
        curRealVolume = ending[2].real_volume;

        prevTime = time;
        
        // find base symbol/period bar where latest existing renko box maps
        const int i = iBarShift(_Symbol, PERIOD_CURRENT, time);
        Print("Restarted from ", Time[i], " [", i, "] ", prevTime);
        Print(upWick, " ", dnWick, " ", High[i], " ", Low[i], " ", Close[i + 1]);
      }
    }
    
    bool isBadTick(const MqlTick &t)
    {
      MqlRates r[1];
      if(CopyRates(_Symbol, _Period, (t.time / PeriodSeconds() * PeriodSeconds()), 1, r) == 1)
      {
        const double price = MathMax(t.bid, t.last);
        if(price < r[0].low)
        {
          if(LogLevel > 2)
          {
            Print("Bad tick ", t.time, "'", (t.time_msc % 1000), " below low: ", DoubleToString(price, _Digits));
            ArrayPrint(r);
          }
          badTickCount++;
          return true;
        }
        if(price > r[0].high)
        {
          if(LogLevel > 2)
          {
            Print("Bad tick ", t.time, "'", (t.time_msc % 1000), " above high: ", DoubleToString(price, _Digits));
            ArrayPrint(r);
          }
          badTickCount++;
          return true;
        }
      }
      return false;
    }
    
    void onTick(const MqlTick &t)
    {
      const bool interactive = ((datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME) == t.time)
                            || ((TerminalInfoInteger(TERMINAL_KEYSTATE_CAPSLOCK) & 1) != 0);
      
      const double Bid = t.bid;
      const double Ask = t.ask;
      
      if(!interactive && DropTicksOutsideBars)
      {
        if(isBadTick(t)) return;
      }
      
      static bool once = false;
      static bool exchange = false;
      if(!once) // experimental stuff for symbols from exchanges (empirical tweaks)
      {
        if(t.bid == 0 && t.ask == 0
        && ((t.flags & TICK_FLAG_BID) != 0)
        && ((t.flags & TICK_FLAG_ASK) != 0))
        {
          Print("Control ticks detected ", t.time, "'", (t.time_msc % 1000));
          exchange = true;
          once = true;
        }
      }

      if((t.flags & TICK_FLAG_VOLUME) != 0)
      {
        curRealVolume += t.volume;
      }
      
      if(!exchange)
      {
        if((Bid == 0 || Bid > Ask)) return;

        if((t.flags & TICK_FLAG_BID) == 0
        /* || (t.flags & TICK_FLAG_ASK) != 0*/) return;
      }
      else
      {
        if(t.last == 0) return;
      }
      
      double price = exchange ? t.last : Bid;

      datetime time = t.time;
      
      if(prevTime == 0) // first call
      {
        prevLow = NormalizeDouble(MathFloor(price / boxPoints) * boxPoints, _Digits);
        prevHigh = prevLow + boxPoints;
        prevOpen = prevLow;
        prevClose = prevHigh;
        
        dnWick = prevLow;
        upWick = prevHigh;
        
        curVolume = 1;
        
        sendSpread = 0;
        
        prevTime = (datetime)((long)time / 60 * 60); // drop seconds
        
        SetPoint = prevLow;
        TrPoint  = prevLow;
        
         HH = prevLow;
         LL = dnWick;
         
      }
      else
      {
        upWick = MathMax(upWick, price);
        dnWick = MathMin(dnWick, price);
      
        curVolume++;
        
        sendSpread = (int)MathMax(sendSpread, (Ask - Bid) / _Point);
        
        
        double dSendLow, dSendHigh;
        
         
         HH = MathMax(HH,price);
         LL = MathMin(LL,price);
          
        //-------------------------------------------------------------------------	   				
        // up box
        if( price > (MathMax(prevClose,prevOpen) + (0.666*boxPoints))  )
        while(price > (MathMax(prevClose,prevOpen) + (0.666*boxPoints)) )
        {
          prevHigh = prevHigh + (0.666*boxPoints);
          prevLow  = prevLow  + (0.666*boxPoints);
          prevOpen = prevLow;
          prevClose = prevHigh;
          
          if(ShowWicks && dnWick < prevLow && dnWick > prevLow - 2 * boxPoints)
          {
            dSendLow = dnWick;
          }
          else
          {
            dSendLow = prevLow;
          }
          
          dSendHigh = prevHigh;
          
          if(CloseTimeMode) incrementTime(time);
          
          if(interactive)
          {
            Comment("JBar (", RenkoBoxSize, "pt): ", _SymbolName, "\nBox UP @ ",
              TTSS(prevTime), " ", DoubleToString(prevOpen, _Digits), "-", DoubleToString(prevClose, _Digits));
          }
          doWriteStruct(prevTime, prevOpen, dSendHigh, dSendLow, prevClose, curVolume, curRealVolume, sendSpread);
          updateChartWindow(prevClose, prevClose + Ask - Bid);
          if(LogLevel > 3)
          {
            Print(t.time, "'", StringFormat("%03d", t.time_msc % 1000), " ", DoubleToString(price, _Digits), " ", DoubleToString(Ask, _Digits), " ", TickFlags(t.flags));
            Print("Box UP @ ",
              TTSS(prevTime), " ", DoubleToString(prevOpen, _Digits), "-", DoubleToString(prevClose, _Digits));
          }
      
          if(!CloseTimeMode) incrementTime(time);
      
          curHigh = prevHigh;
          curLow = prevHigh;
          curVolume = 0;
          curRealVolume = 0;
          sendSpread = 0;
      
          upWick = 0;
          dnWick = EMPTY_VALUE;
         
        }
        //-------------------------------------------------------------------------	   				
        // down box
        else if(price < (MathMin(prevClose,prevOpen) - (0.666*boxPoints)) )
        while(price < (MathMax(prevClose,prevOpen) - (0.666*boxPoints)) )
        {
          prevHigh = prevHigh - (0.666*boxPoints);;
          prevLow = prevLow - (0.666*boxPoints);;
          prevOpen = prevHigh;
          prevClose = prevLow;
      
          dSendLow = prevLow;

          if(ShowWicks && upWick > prevHigh && upWick < prevHigh + 2 * boxPoints)
          {
            dSendHigh = upWick;
          }
          else
          {
            dSendHigh = prevHigh;
          }
          
          if(CloseTimeMode) incrementTime(time);
          
          if(interactive)
          {
            Comment("JBar (", RenkoBoxSize, "pt): ", _SymbolName, "\nBox DOWN @ ",
              TTSS(prevTime), " ", DoubleToString(prevOpen, _Digits), "-", DoubleToString(prevClose, _Digits));
          }
          doWriteStruct(prevTime, prevOpen, dSendHigh, dSendLow, prevClose, curVolume, curRealVolume, sendSpread);
          updateChartWindow(prevClose, prevClose + Ask - Bid);
          if(LogLevel > 3)
          {
            Print(t.time, "'", StringFormat("%03d", t.time_msc % 1000), " ", DoubleToString(price, _Digits), " ", DoubleToString(Ask, _Digits), " ", TickFlags(t.flags));
            Print("Box DOWN @ ",
              TTSS(prevTime), " ", DoubleToString(prevOpen, _Digits), "-", DoubleToString(prevClose, _Digits));
          }
      
          if(!CloseTimeMode) incrementTime(time);
      
          curHigh = prevLow;
          curLow = prevLow;
          curVolume = 0;
          curRealVolume = 0;
          sendSpread = 0;
      
          upWick = 0;
          dnWick = EMPTY_VALUE;
        }
        
        //-------------------------------------------------------------------------	   				
        // no box - high/low not hit				
        else if(!CloseTimeMode && interactive)
        {
          if(price > curHigh) curHigh = price;
          if(price < curLow) curLow = price;
          
          double CurOpen, CurClose;
      
          if(prevHigh <= price) CurOpen = prevHigh;
          else if(prevLow >= price) CurOpen = prevLow;
          else CurOpen = price;
      
          CurClose = price;
      
          doWriteStruct(prevTime, CurOpen, curHigh, curLow, CurClose, curVolume, curRealVolume, sendSpread);
          updateChartWindow(CurClose, CurClose + Ask - Bid);
        }
      }
    }
    
    void updateChartWindow(const double bid = 0, const double ask = 0)
    {
      if(EmulateOnLineChart)
      {
        MqlTick tick[1];
        SymbolInfoTick(_Symbol, tick[0]);
        tick[0].time = prevTime;
        tick[0].time_msc = (long)(prevTime) * 1000;
        if(bid != 0 && ask != 0)
        {
          tick[0].bid = bid;
          tick[0].ask = ask;
        }
        
        ResetLastError();
        
        int added = CustomTicksAdd(_SymbolName, tick);
        if(added == -1)
        {
          _StopAll = true;
          Print("CustomTicksAdd failed: ", GetLastError(), " / Last time:", TTSS(prevTime), " ", (long)(prevTime) * 1000, " ", tick[0].time_msc);
          if(GetLastError() == ERR_CUSTOM_TICKS_WRONG_ORDER)
          {
            Alert("Base of ticks ", _SymbolName, " is damaged, please check and fix; expert is disabled");
            MqlTick ticks_array[];
            int n = CopyTicks(_SymbolName, ticks_array, COPY_TICKS_ALL, prevTime * 1000, 100);
            Print("Last CopyTicks ", n);
            ArrayPrint(ticks_array);
          }
        }
      }
    }
    
    static void setBoxPoints(const double boxpts)
    {
      boxPoints = boxpts;
    }
};

double Renko::boxPoints = NormalizeDouble(RenkoBoxSize * _Point, _Digits);


class TickProvider
{
  public:
    virtual bool hasNext() = 0;
    virtual void getTick(MqlTick &t) = 0;

    bool read(Renko &r)
    {
      while(hasNext() && !IsStopped())
      {
        MqlTick t;
        getTick(t);
        r.onTick(t);
      }
      
      return IsStopped();
    }
};

class CurrentTickProvider : public TickProvider
{
  private:
    bool ready;
    
  public:
    bool hasNext() override
    {
      ready = !ready;
      return ready;
    }
    
    void getTick(MqlTick &t) override
    {
      SymbolInfoTick(_Symbol, t);
    }
};

class HistoryTickProvider : public TickProvider
{
  private:
    datetime start;
    datetime stop;
    ulong length;     // in seconds
    MqlTick array[];
    int size;
    int cursor;
    
    int numberOfDays;
    int daysCount;
    
  protected:
    void fillArray()
    {
      cursor = 0;
      do
      {
        size = CopyTicksRange(_Symbol, array, COPY_TICKS_ALL, start * 1000, MathMin(start + length, stop) * 1000);
        if(LogLevel > 0) Print("Processing ", TTSM(start), " ", size, " ", DoubleToString(daysCount * 100.0 / (numberOfDays + 1), 0), "%");
        Comment("Processing: ", DoubleToString(daysCount * 100.0 / (numberOfDays + 1), 0), "% ", TTSM(start));
        if(size == -1)
        {
          Print("CopyTicksRange failed: ", GetLastError());
        }
        else
        {
          if(size > 0 && array[0].time_msc < start * 1000) // MT5 bug is suspected: older than requested data returned
          {
            start = stop;
            size = 0;
          }
          else
          {
            start = (datetime)MathMin(start + length, stop);
            if(size > 0) daysCount++;
          }
        }
      }
      while(size == 0 && start < stop);
    }
  
  public:
    HistoryTickProvider(const datetime from, const long secs, const datetime to = 0): start(from), stop(to), length(secs), cursor(0), size(0)
    {
      if(stop == 0) stop = TimeCurrent();
      numberOfDays = (int)((stop - start) / DAY_LONG);
      daysCount = 0;
      fillArray();
    }

    bool hasNext() override
    {
      return cursor < size;
    }

    void getTick(MqlTick &t) override
    {
      if(cursor < size)
      {
        t = array[cursor++];
        if(cursor == size)
        {
          fillArray();
        }
      }
    }
};


Renko renko;
CurrentTickProvider online;


/*
 *
 *  E V E N T  H A N D L E R S
 * 
 */
 
int OnInit(void)
{
  if(MQLInfoInteger(MQL_TESTER))
  {
    Alert("This utility EA can not run in the tester.");
    _StopAll = true;
    return INIT_SUCCEEDED;
  }
  
  Renko::setBoxPoints(NormalizeDouble(RenkoBoxSize * _Point, _Digits));
  
  if(OutputSymbolName == "") _SymbolName = Symbol() + (MQLInfoInteger(MQL_DEBUG) ? "_D" : "_T") + (ShowWicks ? "_r" : "_b") + (string)RenkoBoxSize + (CloseTimeMode ? "c" : "");
  else _SymbolName = OutputSymbolName;
  
  Print("*");
  Print(EnumToString((ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE)));

  if(!SymbolSelect(_SymbolName, true))
  {
    Comment("Creating custom symbol ", _SymbolName, ", please wait...");
    Print("Creating custom symbol ", _SymbolName, ", please wait...");
    const SYMBOL Symb(_SymbolName);
    Symb.CloneProperties(_Symbol);
    if(!CustomSymbolSetString(_SymbolName, SYMBOL_BASIS, _Symbol))
    {
      Print("SYMBOL_BASIS failed: ", GetLastError());
    }
    if(!CustomSymbolSetString(_SymbolName, SYMBOL_DESCRIPTION, _Symbol))
    {
      Print("SYMBOL_DESCRIPTION failed: ", GetLastError());
    }
    _JustCreated = true;
    
    if(!SymbolSelect(_SymbolName, true))
    {
      Alert("Can't select symbol:", _SymbolName, " err:", GetLastError());
      return INIT_FAILED;
    }
  }
  else
  {
    Comment("Updating custom symbol ", _SymbolName, ", please wait...");
    Print("Updating custom symbol ", _SymbolName, ", please wait...");
    _JustCreated = false;
  }
  
  if(CloseTimeMode) Print("CloseTimeMode is ON");
  
  _FirstRun = true;
  _StopAll = false;
  renko.reset();
  EventSetTimer(1);
  
  return INIT_SUCCEEDED;
}

void OnTimer()
{
  EventKillTimer();
  OnTick();
}

void OnTick(void)
{
  if(_StopAll) return;
  
  if(_FirstRun)
  {
    if(!TerminalInfoInteger(TERMINAL_CONNECTED))
    {
      Print("Waiting for connection...");
      return;
    }

    if(!SymbolIsSynchronized(_Symbol))
    {
      Print("Unsynchronized, skipping ticks...");
      return;
    }

    CustomSymbolSetInteger(_SymbolName, SYMBOL_TRADE_MODE, SYMBOL_TRADE_MODE_DISABLED);
    
    // find existing renko tail to supersede StartFrom
    const datetime trap = renko.checkEnding();
    if(trap > TimeCurrent())
    {
      Print("Symbol/Timeframe data not ready...");
      return;
    }
    if((trap == 0) || Reset) renko.doReset();
    else renko.continueFrom(trap);

    HistoryTickProvider htp((trap == 0 || Reset) ? StartFrom : trap, DAY_LONG, StopAt);
    
    const bool interrupted = htp.read(renko);
    _FirstRun = false;
    
    CustomSymbolSetInteger(_SymbolName, SYMBOL_TRADE_MODE, SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE));
    
    if(!interrupted)
    {
      if(_JustCreated)
      {
        long id = ChartOpen(_SymbolName, PERIOD_M1);
        if(id == 0)
        {
          Alert("Can't open new chart for " + _SymbolName + ", code: " + (string)GetLastError());
        }
        else
        {
          Sleep(1000);
          ChartSetSymbolPeriod(id, _SymbolName, PERIOD_M1);
          ChartSetInteger(id, CHART_MODE, CHART_CANDLES);
        }
      }
      
      Comment("JBar (" + (string)RenkoBoxSize + "pt): open ", _SymbolName, " / ", renko.getBoxCount(), " bars");
      if(renko.getOverflowCount() > 0) Print("Overflow occured ", renko.getOverflowCount(), " times!");
      if(renko.getBadTickCount() > 0) Print("Bad ticks skipped ", renko.getBadTickCount(), " times!");
      Print("History refresh done, ", renko.getBoxCount(), " boxes created");
    }
    else
    {
      Print("Interrupted. Custom symbol data is inconsistent - please, reset or delete");
    }
  }
  else if(StopAt == 0) // process online if not stopped explicitly
  {
    online.read(renko);
  }
  
  
  if(TimeCurrent()>=MyTimer){
     MyTimer = TimeCurrent() + 300;
     double Min_Size = Inf;
     double Max_Size = 0;
     
     for(int ii=3; ii<40; ii++){
       Min_Size = MathMin(Min_Size, MathAbs(iClose(_SymbolName,PERIOD_M1,ii)-iOpen(_SymbolName,PERIOD_M1,ii)));
       Max_Size = MathMax(Max_Size, MathAbs(iClose(_SymbolName,PERIOD_M1,ii)-iOpen(_SymbolName,PERIOD_M1,ii)));
     }
     Comment(Min_Size,"  ",Max_Size);
     if(Max_Size>(2*Min_Size)) {
        CustomRatesDelete(_SymbolName,iTime(_Symbol,PERIOD_D1,10),TimeCurrent());
        FunOnInit();
        }
  }
  
}

void OnDeinit(const int reason)
{
  Comment("");
}
////////////////////////
void FunOnInit(){
  Renko::setBoxPoints(NormalizeDouble(RenkoBoxSize * _Point, _Digits));
  
  if(OutputSymbolName == "") _SymbolName = Symbol() + (MQLInfoInteger(MQL_DEBUG) ? "_D" : "_T") + (ShowWicks ? "_r" : "_b") + (string)RenkoBoxSize + (CloseTimeMode ? "c" : "");
  else _SymbolName = OutputSymbolName;
  
  Print("*");
  Print(EnumToString((ENUM_SYMBOL_CALC_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE)));

  if(!SymbolSelect(_SymbolName, true))
  {
    Comment("Creating custom symbol ", _SymbolName, ", please wait...");
    Print("Creating custom symbol ", _SymbolName, ", please wait...");
    const SYMBOL Symb(_SymbolName);
    Symb.CloneProperties(_Symbol);
    if(!CustomSymbolSetString(_SymbolName, SYMBOL_BASIS, _Symbol))
    {
      Print("SYMBOL_BASIS failed: ", GetLastError());
    }
    if(!CustomSymbolSetString(_SymbolName, SYMBOL_DESCRIPTION, _Symbol))
    {
      Print("SYMBOL_DESCRIPTION failed: ", GetLastError());
    }
    _JustCreated = true;
    
    if(!SymbolSelect(_SymbolName, true))
    {
      Alert("Can't select symbol:", _SymbolName, " err:", GetLastError());
      return;
    }
  }
  else
  {
    Comment("Updating custom symbol ", _SymbolName, ", please wait...");
    Print("Updating custom symbol ", _SymbolName, ", please wait...");
    _JustCreated = false;
  }
  
  if(CloseTimeMode) Print("CloseTimeMode is ON");
  
  _FirstRun = true;
  _StopAll = false;
  renko.reset();
}
////////////////////////////////////