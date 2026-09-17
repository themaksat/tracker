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


SYNC_TARGETS_URL = 'https://tracker-76gq.onrender.com/api/mt5/sync-targets'

last_secondary_sync = 0


def fetch_account_payload():
    acc = mt5.account_info()
    if not acc:
        return None

    acc_dict = acc._asdict()
    login = acc_dict.get('login', 0)
    company = acc_dict.get('company', 'Unknown')
    currency = acc_dict.get('currency', 'USD')
    balance = acc_dict.get('balance', 0.0)
    equity = acc_dict.get('equity', 0.0)
    profit = acc_dict.get('profit', 0.0)
    margin = acc_dict.get('margin', 0.0)
    margin_free = acc_dict.get('margin_free', 0.0)
    server = acc_dict.get('server', company)

    # Look back 90 days to capture all closed deals
    from_date = datetime.now(timezone.utc) - timedelta(days=90)
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
            entry_price = in_deal.get('price', dd.get('price', 0.0))
            open_time_dt = datetime.fromtimestamp(in_deal.get('time', dd.get('time')), timezone.utc)
            close_time_dt = datetime.fromtimestamp(dd.get('time'), timezone.utc)

            # In MT5 out deal, DEAL_TYPE_SELL (1) closes a BUY position; DEAL_TYPE_BUY (0) closes a SELL position
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

    # Sort by close time descending and send up to 1000 deals
    trades_payload.sort(key=lambda t: t.get('close_time', ''), reverse=True)

    return {
        'account': {
            'broker': company,
            'server': server,
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
        'trades': trades_payload[:1000]
    }


def send_payload(payload):
    login = payload.get('account', {}).get('login', 0)
    data_bytes = json.dumps(payload).encode('utf-8')

    token_to_use = TRACKER_TOKEN
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH, 'r', encoding='utf-8-sig') as f:
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
                trades_count = len(payload.get('trades', []))
                print(f'[Bridge] Successfully synced account {login} ({trades_count} deals) to {url}: {body}')
        except Exception as e:
            print(f'[Bridge] Error posting to {url}: {e}')


def get_sync_targets():
    try:
        req = urllib.request.Request(
            SYNC_TARGETS_URL,
            headers={'x-tracker-token': TRACKER_TOKEN}
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            return json.loads(resp.read().decode('utf-8'))
    except Exception as e:
        return []


def sync_once():
    global last_secondary_sync
    if not mt5.initialize():
        print('[Bridge] MT5 initialize failed')
        return False

    acc = mt5.account_info()
    if not acc:
        print('[Bridge] Failed to get account info')
        mt5.shutdown()
        return False

    primary_login = acc.login
    primary_server = acc._asdict().get('server', '')

    # 1. Sync currently active account in terminal
    payload = fetch_account_payload()
    if payload:
        send_payload(payload)
        trades_count = len(payload.get('trades', []))
        try:
            with open("bridge.log", "w") as f:
                f.write(f"Last sync: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M:%S UTC')} - OK (Synced {trades_count} trades for #{primary_login})\n")
        except Exception:
            pass

    # 2. Periodically check and sync secondary accounts (every 5 minutes)
    now = time.time()
    if now - last_secondary_sync > 300:
        last_secondary_sync = now
        targets = get_sync_targets()
        for t in targets:
            try:
                target_login = int(t.get('login') or 0)
                password = t.get('password')
                server = t.get('server')
                if target_login and target_login != primary_login and password and server:
                    print(f'[Bridge] Syncing secondary account #{target_login} ({server})...')
                    if mt5.login(target_login, password=password, server=server):
                        time.sleep(1)
                        sec_payload = fetch_account_payload()
                        if sec_payload:
                            send_payload(sec_payload)
            except Exception as te:
                print(f'[Bridge] Error syncing secondary account {t}: {te}')

        # Always switch back to user's primary active terminal
        if mt5.account_info() and mt5.account_info().login != primary_login:
            mt5.login(primary_login, server=primary_server)

    mt5.shutdown()
    return True


if __name__ == '__main__':
    print('[Bridge] Starting MT5 auto-sync bridge daemon...', flush=True)
    while True:
        try:
            sync_once()
        except Exception as ex:
            print(f'[Bridge] Loop error: {ex}', flush=True)
        time.sleep(10)
