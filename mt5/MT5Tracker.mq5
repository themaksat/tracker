#property strict
#property version   "1.00"
#property description "MT5 -> PostgreSQL Tracker bridge through your own Node.js API"

input string ApiUrl       = "https://tracker-76gq.onrender.com/api/mt5/ingest";
input string TrackerToken = "mt5t_7c40ed733fd7664eb88b2c0a19a2f83e87895d87d98315e8627c89fc1a0e2f88";
input int    SyncSeconds  = 15;
input int    HistoryDays  = 30;

datetime lastSync = 0;

string EscapeJson(string s)
{
   StringReplace(s,"\\","\\\\");
   StringReplace(s,"\"","\\\"");
   StringReplace(s,"\r","");
   StringReplace(s,"\n","\\n");
   return s;
}

string IsoTime(datetime t)
{
   if(t<=0) return "";
   MqlDateTime dt;
   TimeToStruct(t,dt);
   return StringFormat("%04d-%02d-%02dT%02d:%02d:%02dZ",
      dt.year,dt.mon,dt.day,dt.hour,dt.min,dt.sec);
}

string DealReasonToString(long reason)
{
   switch((ENUM_DEAL_REASON)reason)
   {
      case DEAL_REASON_SL: return "SL";
      case DEAL_REASON_TP: return "TP";
      case DEAL_REASON_SO: return "STOP_OUT";
      case DEAL_REASON_EXPERT: return "EA";
      case DEAL_REASON_CLIENT: return "MANUAL";
      case DEAL_REASON_MOBILE: return "MOBILE";
      case DEAL_REASON_WEB: return "WEB";
      default: return "OTHER";
   }
}

string SideToString(long type)
{
   if(type==DEAL_TYPE_SELL) return "SELL";
   return "BUY";
}

double FindPositionEntryPrice(ulong position_id)
{
   datetime from=TimeCurrent()-(HistoryDays*86400);
   if(!HistorySelect(from,TimeCurrent())) return 0;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if((ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID)!=position_id) continue;

      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT)
         return HistoryDealGetDouble(ticket,DEAL_PRICE);
   }
   return 0;
}

datetime FindPositionOpenTime(ulong position_id)
{
   datetime from=TimeCurrent()-(HistoryDays*86400);
   if(!HistorySelect(from,TimeCurrent())) return 0;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong ticket=HistoryDealGetTicket(i);
      if(ticket==0) continue;
      if((ulong)HistoryDealGetInteger(ticket,DEAL_POSITION_ID)!=position_id) continue;

      long entry=HistoryDealGetInteger(ticket,DEAL_ENTRY);
      if(entry==DEAL_ENTRY_IN || entry==DEAL_ENTRY_INOUT)
         return (datetime)HistoryDealGetInteger(ticket,DEAL_TIME);
   }
   return 0;
}

void FindPositionSLTP(ulong position_id,double &sl,double &tp)
{
   sl=0; tp=0;
   if(HistorySelectByPosition(position_id))
   {
      int orders=HistoryOrdersTotal();
      for(int i=orders-1;i>=0;i--)
      {
         ulong ord=HistoryOrderGetTicket(i);
         if(ord==0) continue;

         double osl=HistoryOrderGetDouble(ord,ORDER_SL);
         double otp=HistoryOrderGetDouble(ord,ORDER_TP);

         if(osl>0 && sl==0) sl=osl;
         if(otp>0 && tp==0) tp=otp;

         if(sl>0 && tp>0) break;
      }
   }
}

double CalculateRR(string side,double entry,double sl,double tp)
{
   if(entry<=0 || sl<=0 || tp<=0) return 0;
   double risk=MathAbs(entry-sl);
   double reward=MathAbs(tp-entry);
   if(risk<=0) return 0;
   return reward/risk;
}

string BuildClosedTradesJson()
{
   datetime from=TimeCurrent()-(HistoryDays*86400);
   datetime to=TimeCurrent();

   if(!HistorySelect(from,to)) return "[]";

   string json="[";
   bool first=true;

   int total=HistoryDealsTotal();
   for(int i=0;i<total;i++)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(deal==0) continue;

      long entry=HistoryDealGetInteger(deal,DEAL_ENTRY);
      if(entry!=DEAL_ENTRY_OUT && entry!=DEAL_ENTRY_OUT_BY) continue;

      long dealType=HistoryDealGetInteger(deal,DEAL_TYPE);
      if(dealType!=DEAL_TYPE_BUY && dealType!=DEAL_TYPE_SELL) continue;

      ulong position_id=(ulong)HistoryDealGetInteger(deal,DEAL_POSITION_ID);
      string symbol=HistoryDealGetString(deal,DEAL_SYMBOL);
      double volume=HistoryDealGetDouble(deal,DEAL_VOLUME);
      double exitPrice=HistoryDealGetDouble(deal,DEAL_PRICE);
      double profit=HistoryDealGetDouble(deal,DEAL_PROFIT);
      double commission=HistoryDealGetDouble(deal,DEAL_COMMISSION);
      double swap=HistoryDealGetDouble(deal,DEAL_SWAP);
      long magic=HistoryDealGetInteger(deal,DEAL_MAGIC);
      long reason=HistoryDealGetInteger(deal,DEAL_REASON);
      datetime closeTime=(datetime)HistoryDealGetInteger(deal,DEAL_TIME);

      double entryPrice=FindPositionEntryPrice(position_id);
      datetime openTime=FindPositionOpenTime(position_id);

      double sl,tp;
      FindPositionSLTP(position_id,sl,tp);

      string side=SideToString(dealType);
      // Closing BUY deal usually closes a SELL position and vice versa.
      // Reverse side for closed position representation.
      side=(side=="BUY" ? "SELL" : "BUY");

      double rr=CalculateRR(side,entryPrice,sl,tp);

      string source=(reason==DEAL_REASON_EXPERT ? "EA" : "MANUAL");

      if(!first) json+=",";
      first=false;

      json+="{";
      json+="\"ticket\":"+IntegerToString((long)deal)+",";
      json+="\"position_id\":"+IntegerToString((long)position_id)+",";
      json+="\"open_time\":\""+IsoTime(openTime)+"\",";
      json+="\"close_time\":\""+IsoTime(closeTime)+"\",";
      json+="\"symbol\":\""+EscapeJson(symbol)+"\",";
      json+="\"side\":\""+side+"\",";
      json+="\"volume\":"+DoubleToString(volume,4)+",";
      json+="\"entry_price\":"+DoubleToString(entryPrice,8)+",";
      json+="\"exit_price\":"+DoubleToString(exitPrice,8)+",";
      json+="\"sl\":"+DoubleToString(sl,8)+",";
      json+="\"tp\":"+DoubleToString(tp,8)+",";
      json+="\"rr\":"+DoubleToString(rr,4)+",";
      json+="\"profit\":"+DoubleToString(profit,2)+",";
      json+="\"commission\":"+DoubleToString(commission,2)+",";
      json+="\"swap\":"+DoubleToString(swap,2)+",";
      json+="\"source\":\""+source+"\",";
      json+="\"strategy\":\"\",";
      json+="\"magic\":"+IntegerToString(magic)+",";
      json+="\"close_reason\":\""+DealReasonToString(reason)+"\"";
      json+="}";
   }

   json+="]";
   return json;
}

bool SendSnapshot()
{
   if(TrackerToken=="" || StringFind(TrackerToken,"PASTE_")==0)
   {
      Print("TrackerToken is not configured.");
      return false;
   }

   string broker=AccountInfoString(ACCOUNT_COMPANY);
   long login=AccountInfoInteger(ACCOUNT_LOGIN);
   string currency=AccountInfoString(ACCOUNT_CURRENCY);

   double balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
   double margin=AccountInfoDouble(ACCOUNT_MARGIN);
   double freeMargin=AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double floating=equity-balance;

   string json="{";
   json+="\"account\":{";
   json+="\"broker\":\""+EscapeJson(broker)+"\",";
   json+="\"login\":"+IntegerToString(login)+",";
   json+="\"currency\":\""+EscapeJson(currency)+"\"";
   json+="},";

   json+="\"snapshot\":{";
   json+="\"balance\":"+DoubleToString(balance,2)+",";
   json+="\"equity\":"+DoubleToString(equity,2)+",";
   json+="\"floating_pnl\":"+DoubleToString(floating,2)+",";
   json+="\"margin\":"+DoubleToString(margin,2)+",";
   json+="\"free_margin\":"+DoubleToString(freeMargin,2);
   json+="},";

   json+="\"trades\":"+BuildClosedTradesJson();
   json+="}";

   char data[];
   StringToCharArray(json,data,0,WHOLE_ARRAY,CP_UTF8);
   if(ArraySize(data)>0) ArrayResize(data,ArraySize(data)-1);

   char result[];
   string resultHeaders;

   string headers=
      "Content-Type: application/json\r\n"
      "X-Tracker-Token: "+TrackerToken+"\r\n";

   ResetLastError();
   int status=WebRequest(
      "POST",
      ApiUrl,
      headers,
      10000,
      data,
      result,
      resultHeaders
   );

   if(status==-1)
   {
      Print("WebRequest failed. Error=",GetLastError());
      Print("Add your API domain in MT5: Tools -> Options -> Expert Advisors -> Allow WebRequest.");
      return false;
   }

   string response=CharArrayToString(result,0,-1,CP_UTF8);

   if(status<200 || status>=300)
   {
      Print("Server returned HTTP ",status,": ",response);
      return false;
   }

   Print("MT5 Tracker sync OK. HTTP ",status);
   return true;
}

int OnInit()
{
   EventSetTimer(MathMax(5,SyncSeconds));
   SendSnapshot();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
}

void OnTimer()
{
   SendSnapshot();
}

void OnTradeTransaction(
   const MqlTradeTransaction &trans,
   const MqlTradeRequest &request,
   const MqlTradeResult &result)
{
   if(trans.type==TRADE_TRANSACTION_DEAL_ADD)
      SendSnapshot();
}
