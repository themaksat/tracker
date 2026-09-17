CREATE TABLE IF NOT EXISTS users (
    id BIGSERIAL PRIMARY KEY,
    email TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS trading_accounts (
    id BIGSERIAL PRIMARY KEY,
    user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    broker TEXT,
    mt5_login BIGINT,
    currency TEXT DEFAULT 'USD',
    tracker_token_hash TEXT UNIQUE NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_trading_accounts_user_id
ON trading_accounts(user_id);

ALTER TABLE trading_accounts ADD COLUMN IF NOT EXISTS server TEXT;
ALTER TABLE trading_accounts ADD COLUMN IF NOT EXISTS investor_password TEXT;


CREATE TABLE IF NOT EXISTS account_snapshots (
    id BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES trading_accounts(id) ON DELETE CASCADE,
    balance NUMERIC(18,2) NOT NULL DEFAULT 0,
    equity NUMERIC(18,2) NOT NULL DEFAULT 0,
    floating_pnl NUMERIC(18,2) NOT NULL DEFAULT 0,
    margin NUMERIC(18,2) NOT NULL DEFAULT 0,
    free_margin NUMERIC(18,2) NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_snapshots_account_time
ON account_snapshots(account_id, updated_at DESC);

CREATE TABLE IF NOT EXISTS trades (
    id BIGSERIAL PRIMARY KEY,
    account_id BIGINT NOT NULL REFERENCES trading_accounts(id) ON DELETE CASCADE,
    ticket BIGINT NOT NULL,
    position_id BIGINT,
    open_time TIMESTAMPTZ,
    close_time TIMESTAMPTZ,
    symbol TEXT NOT NULL,
    side TEXT NOT NULL CHECK (side IN ('BUY','SELL')),
    volume NUMERIC(12,4) NOT NULL DEFAULT 0,
    entry_price NUMERIC(20,8) NOT NULL DEFAULT 0,
    exit_price NUMERIC(20,8) NOT NULL DEFAULT 0,
    sl NUMERIC(20,8) NOT NULL DEFAULT 0,
    tp NUMERIC(20,8) NOT NULL DEFAULT 0,
    rr NUMERIC(10,4) NOT NULL DEFAULT 0,
    profit NUMERIC(18,2) NOT NULL DEFAULT 0,
    commission NUMERIC(18,2) NOT NULL DEFAULT 0,
    swap NUMERIC(18,2) NOT NULL DEFAULT 0,
    source TEXT NOT NULL DEFAULT 'MANUAL',
    strategy TEXT NOT NULL DEFAULT '',
    magic BIGINT NOT NULL DEFAULT 0,
    close_reason TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE(account_id, ticket)
);

CREATE INDEX IF NOT EXISTS idx_trades_account_close
ON trades(account_id, close_time DESC);
