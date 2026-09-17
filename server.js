require("dotenv").config();

const express = require("express");
const cors = require("cors");
const bcrypt = require("bcryptjs");
const jwt = require("jsonwebtoken");
const crypto = require("crypto");
const { Pool } = require("pg");

const path = require("path");
const app = express();

if (!process.env.DATABASE_URL || !process.env.JWT_SECRET) {
  console.error("Missing DATABASE_URL or JWT_SECRET in .env");
  process.exit(1);
}

const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  ssl: process.env.NODE_ENV === "production" ? { rejectUnauthorized: false } : false
});

const allowedOrigins = (process.env.FRONTEND_ORIGIN || "")
  .split(",")
  .map(v => v.trim())
  .filter(Boolean);

app.use(cors({
  origin(origin, cb) {
    if (!origin) return cb(null, true);
    if (
      allowedOrigins.length === 0 ||
      allowedOrigins.includes(origin) ||
      origin.endsWith(".github.io") ||
      origin.endsWith(".trycloudflare.com") ||
      origin.includes("localhost") ||
      origin.includes("127.0.0.1")
    ) {
      return cb(null, true);
    }
    return cb(new Error("CORS blocked for origin: " + origin));
  }
}));

app.use(express.json({ limit: "2mb" }));
app.use(express.static(path.join(__dirname, "public")));


function signUser(user) {
  return jwt.sign(
    { userId: user.id, email: user.email },
    process.env.JWT_SECRET,
    { expiresIn: "7d" }
  );
}

function requireAuth(req, res, next) {
  const header = req.headers.authorization || "";
  const token = header.startsWith("Bearer ") ? header.slice(7) : null;
  if (!token) return res.status(401).json({ error: "Missing token" });

  try {
    req.user = jwt.verify(token, process.env.JWT_SECRET);
    next();
  } catch {
    return res.status(401).json({ error: "Invalid or expired token" });
  }
}

function hashTrackerToken(token) {
  return crypto.createHash("sha256").update(token).digest("hex");
}

function newTrackerToken() {
  return "mt5t_" + crypto.randomBytes(32).toString("hex");
}

app.get("/api/health", async (req, res) => {
  try {
    const r = await pool.query("SELECT NOW() AS now");
    res.json({ ok: true, dbTime: r.rows[0].now });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

app.post("/api/auth/register", async (req, res) => {
  try {
    const email = String(req.body.email || "").trim().toLowerCase();
    const password = String(req.body.password || "");

    if (!email || password.length < 8) {
      return res.status(400).json({ error: "Email and password of at least 8 characters are required." });
    }

    const passwordHash = await bcrypt.hash(password, 12);

    const result = await pool.query(
      `INSERT INTO users(email, password_hash)
       VALUES($1,$2)
       RETURNING id,email,created_at`,
      [email, passwordHash]
    );

    const user = result.rows[0];
    res.json({ token: signUser(user), user });

  } catch (e) {
    if (e.code === "23505") {
      return res.status(409).json({ error: "Email already registered." });
    }
    console.error(e);
    res.status(500).json({ error: "Registration failed." });
  }
});

app.post("/api/auth/login", async (req, res) => {
  try {
    const email = String(req.body.email || "").trim().toLowerCase();
    const password = String(req.body.password || "");

    const result = await pool.query(
      "SELECT id,email,password_hash FROM users WHERE email=$1",
      [email]
    );

    if (!result.rows.length) {
      return res.status(401).json({ error: "Invalid email or password." });
    }

    const user = result.rows[0];
    const ok = await bcrypt.compare(password, user.password_hash);

    if (!ok) {
      return res.status(401).json({ error: "Invalid email or password." });
    }

    res.json({
      token: signUser(user),
      user: { id: user.id, email: user.email }
    });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "Login failed." });
  }
});

app.get("/api/accounts", requireAuth, async (req, res) => {
  try {
    const result = await pool.query(
      `SELECT id,name,broker,mt5_login,currency,created_at
       FROM trading_accounts
       WHERE user_id=$1
       ORDER BY created_at DESC`,
      [req.user.userId]
    );
    res.json(result.rows);
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "Could not load accounts." });
  }
});

app.post("/api/accounts", requireAuth, async (req, res) => {
  try {
    const name = String(req.body.name || "My MT5").trim();
    const token = newTrackerToken();
    const tokenHash = hashTrackerToken(token);

    const result = await pool.query(
      `INSERT INTO trading_accounts(user_id,name,tracker_token_hash)
       VALUES($1,$2,$3)
       RETURNING id,name,broker,mt5_login,currency,created_at`,
      [req.user.userId, name, tokenHash]
    );

    res.json({
      account: result.rows[0],
      trackerToken: token
    });
  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "Could not create account." });
  }
});

app.get("/api/accounts/:id/dashboard", requireAuth, async (req, res) => {
  try {
    const accountId = Number(req.params.id);

    const owner = await pool.query(
      `SELECT id,name,broker,mt5_login,currency
       FROM trading_accounts
       WHERE id=$1 AND user_id=$2`,
      [accountId, req.user.userId]
    );

    if (!owner.rows.length) {
      return res.status(404).json({ error: "Account not found." });
    }

    const snapshot = await pool.query(
      `SELECT balance,equity,floating_pnl,margin,free_margin,updated_at
       FROM account_snapshots
       WHERE account_id=$1
       ORDER BY updated_at DESC
       LIMIT 1`,
      [accountId]
    );

    const trades = await pool.query(
      `SELECT ticket,position_id,open_time,close_time,symbol,side,volume,
              entry_price,exit_price,sl,tp,rr,profit,commission,swap,
              source,strategy,magic,close_reason
       FROM trades
       WHERE account_id=$1
       ORDER BY close_time DESC NULLS LAST
       LIMIT 3000`,
      [accountId]
    );

    res.json({
      account: owner.rows[0],
      snapshot: snapshot.rows[0] || null,
      trades: trades.rows
    });

  } catch (e) {
    console.error(e);
    res.status(500).json({ error: "Could not load dashboard." });
  }
});

app.post("/api/mt5/ingest", async (req, res) => {
  const trackerToken = String(req.headers["x-tracker-token"] || "");
  if (!trackerToken) {
    return res.status(401).json({ error: "Missing tracker token." });
  }

  const tokenHash = hashTrackerToken(trackerToken);

  const client = await pool.connect();

  try {
    await client.query("BEGIN");

    const accResult = await client.query(
      `SELECT id FROM trading_accounts WHERE tracker_token_hash=$1`,
      [tokenHash]
    );

    if (!accResult.rows.length) {
      await client.query("ROLLBACK");
      return res.status(401).json({ error: "Invalid tracker token." });
    }

    const accountId = accResult.rows[0].id;
    const account = req.body.account || {};
    const snapshot = req.body.snapshot || {};
    const trades = Array.isArray(req.body.trades) ? req.body.trades : [];

    await client.query(
      `UPDATE trading_accounts
       SET broker=COALESCE(NULLIF($1,''),broker),
           mt5_login=COALESCE($2,mt5_login),
           currency=COALESCE(NULLIF($3,''),currency)
       WHERE id=$4`,
      [
        String(account.broker || ""),
        account.login ? Number(account.login) : null,
        String(account.currency || ""),
        accountId
      ].map(v => v === undefined ? null : v)
    );

    await client.query(
      `INSERT INTO account_snapshots
       (account_id,balance,equity,floating_pnl,margin,free_margin,updated_at)
       VALUES($1,$2,$3,$4,$5,$6,NOW())`,
      [
        accountId,
        Number(snapshot.balance || 0),
        Number(snapshot.equity || 0),
        Number(snapshot.floating_pnl || 0),
        Number(snapshot.margin || 0),
        Number(snapshot.free_margin || 0)
      ]
    );

    for (const t of trades) {
      await client.query(
        `INSERT INTO trades(
          account_id,ticket,position_id,open_time,close_time,symbol,side,volume,
          entry_price,exit_price,sl,tp,rr,profit,commission,swap,
          source,strategy,magic,close_reason
        )
        VALUES(
          $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20
        )
        ON CONFLICT(account_id,ticket) DO UPDATE SET
          position_id=EXCLUDED.position_id,
          open_time=EXCLUDED.open_time,
          close_time=EXCLUDED.close_time,
          symbol=EXCLUDED.symbol,
          side=EXCLUDED.side,
          volume=EXCLUDED.volume,
          entry_price=EXCLUDED.entry_price,
          exit_price=EXCLUDED.exit_price,
          sl=EXCLUDED.sl,
          tp=EXCLUDED.tp,
          rr=EXCLUDED.rr,
          profit=EXCLUDED.profit,
          commission=EXCLUDED.commission,
          swap=EXCLUDED.swap,
          source=EXCLUDED.source,
          strategy=EXCLUDED.strategy,
          magic=EXCLUDED.magic,
          close_reason=EXCLUDED.close_reason`,
        [
          accountId,
          Number(t.ticket || 0),
          t.position_id ? Number(t.position_id) : null,
          t.open_time || null,
          t.close_time || null,
          String(t.symbol || ""),
          String(t.side || "").toUpperCase() === "SELL" ? "SELL" : "BUY",
          Number(t.volume || 0),
          Number(t.entry_price || 0),
          Number(t.exit_price || 0),
          Number(t.sl || 0),
          Number(t.tp || 0),
          Number(t.rr || 0),
          Number(t.profit || 0),
          Number(t.commission || 0),
          Number(t.swap || 0),
          String(t.source || "MANUAL"),
          String(t.strategy || ""),
          Number(t.magic || 0),
          String(t.close_reason || "")
        ]
      );
    }

    await client.query("COMMIT");
    res.json({ ok: true, accountId, tradesReceived: trades.length });

  } catch (e) {
    await client.query("ROLLBACK");
    console.error(e);
    res.status(500).json({ error: "Ingest failed.", detail: e.message });
  } finally {
    client.release();
  }
});

const port = Number(process.env.PORT || 3000);

app.listen(port, () => {
  console.log(`MT5 tracker API listening on port ${port}`);
});
