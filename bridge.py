import os
import sys
import time
import json
import urllib.request
from datetime import datetime, timedelta, timezone
import MetaTrader5 as mt5

TRACKER_TOKEN = 'mt5t_7c40ed733fd7664eb88b2c0a19a2f83e87895d87d98315e8627c89fc1a0e2f88'
CONFIG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'accounts_config.json')
TARGET_URLS = [
    'https://tracker-76gq.onrender.com/api/mt5/ingest'
]


def sync_once():
    if not mt5.initialize():
        print('[Bridge] MT5 initialize failed')
        return False

    acc = mt5.account_info()
    if not acc:
        print('[Bridge] Failed to get account info')
        mt5.shutdown()
        return False

    acc_dict = acc._asdict()
    login = acc_dict.get('login', 0)
    company = acc_dict.get('company', 'Unknown')
    currency = acc_dict.get('currency', 'USD')
    balance = acc_dict.get('balance', 0.0)
    equity = acc_dict.get('equity', 0.0)
    profit = acc_dict.get('profit', 0.0)
    margin = acc_dict.get('margin', 0.0)
    margin_free = acc_dict.get('margin_free', 0.0)

    # Fetch last 30 days deals
    from_date = datetime.now(timezone.utc) - timedelta(days=30)
    deals = mt5.history_deals_get(from_date, datetime.now(timezone.utc)) or []

    pos_entries = {}
    for d in deals:
        dd = d._asdict()
        pid = dd.get('position_id')
        entry = dd.get('entry')
        if pid and entry in (0, 2):
            pos_entries[pid] = dd

    trades_payload = []
    for d in deals:
        dd = d._asdict()
        dtype = dd.get('type')
        entry = dd.get('entry')
        if dtype not in (0, 1):
            continue
        if entry == 1:
            pid = dd.get('position_id', 0)
            in_deal = pos_entries.get(pid, {})
            entry_price = in_deal.get('price', 0.0)
            open_time_dt = datetime.fromtimestamp(in_deal.get('time', dd.get('time')), timezone.utc)
            close_time_dt = datetime.fromtimestamp(dd.get('time'), timezone.utc)

            side = 'BUY' if dtype == 1 else 'SELL'
            reason = dd.get('reason', 0)
            reason_map = {0: 'CLIENT', 1: 'MOBILE', 2: 'WEB', 3: 'EXPERT', 4: 'SL', 5: 'TP', 6: 'SO'}
            close_reason = reason_map.get(reason, 'MANUAL')

            trades_payload.append({
                'ticket': dd.get('ticket'),
                'position_id': pid,
                'open_time': open_time_dt.strftime('%Y-%m-%dT%H:%M:%SZ'),
                'close_time': close_time_dt.strftime('%Y-%m-%dT%H:%M:%SZ'),
                'symbol': dd.get('symbol', ''),
                'side': side,
                'volume': float(dd.get('volume', 0)),
                'entry_price': float(entry_price),
                'exit_price': float(dd.get('price', 0)),
                'sl': 0.0,
                'tp': 0.0,
                'rr': 0.0,
                'profit': float(dd.get('profit', 0)),
                'commission': float(dd.get('commission', 0)),
                'swap': float(dd.get('swap', 0)),
                'source': 'EA' if reason == 3 else 'MANUAL',
                'strategy': '',
                'magic': dd.get('magic', 0),
                'close_reason': close_reason
            })

    mt5.shutdown()

    payload = {
        'account': {
            'broker': company,
            'login': login,
            'currency': currency
        },
        'snapshot': {
            'balance': balance,
            'equity': equity,
            'floating_pnl': profit,
            'margin': margin,
            'free_margin': margin_free
        },
        'trades': trades_payload[-150:]
    }

    data_bytes = json.dumps(payload).encode('utf-8')

    token_to_use = TRACKER_TOKEN
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, 'r', encoding='utf-8') as f:
                cfg = json.load(f)
                token_to_use = cfg.get('accounts', {}).get(str(login)) or cfg.get('default_token') or TRACKER_TOKEN
        except Exception as ce:
            print(f'[Bridge] Error reading {CONFIG_PATH}: {ce}')

    for url in TARGET_URLS:
        req = urllib.request.Request(
            url,
            data=data_bytes,
            headers={
                'Content-Type': 'application/json',
                'x-tracker-token': token_to_use
            }
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = resp.read().decode('utf-8')
                print(f'[Bridge] Successfully synced account {login} to {url}: {body}')
        except Exception as e:
            print(f'[Bridge] Error posting to {url}: {e}')


    try:
        with open("bridge.log", "w") as f:
            f.write(f"Last sync: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')} - OK (Synced {len(trades_payload[-150:])} trades)\n")
    except Exception:
        pass

    return True

if __name__ == '__main__':
    print('[Bridge] Starting MT5 auto-sync bridge daemon...', flush=True)
    while True:
        try:
            sync_once()
        except Exception as ex:
            print(f'[Bridge] Loop error: {ex}', flush=True)
        time.sleep(10)
