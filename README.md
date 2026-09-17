# MT5 Tracker — Plain PostgreSQL Version

This version uses **no Supabase**.

Architecture:

```
MT5 terminal
   ↓ HTTPS
Node.js / Express API
   ↓
PostgreSQL
   ↑
GitHub Pages dashboard
```

## 1. Create PostgreSQL database

Example locally:

```bash
createdb mt5tracker
psql mt5tracker < schema.sql
```

Or run `schema.sql` in any PostgreSQL host.

## 2. Configure backend

Copy:

```bash
cp .env.example .env
```

Edit `.env`:

```env
PORT=3000
DATABASE_URL=postgresql://USER:PASSWORD@HOST:5432/mt5tracker
JWT_SECRET=put-a-long-random-secret-here
FRONTEND_ORIGIN=https://YOUR-GITHUB-USERNAME.github.io
NODE_ENV=production
```

Install and run:

```bash
npm install
npm start
```

The backend can run on your VPS, Railway, Render, Fly.io, or any host that supports Node.js.

GitHub Pages cannot run the Node.js API because GitHub Pages is static hosting only.

## 3. Configure frontend

Open:

`public/index.html`

Change:

```js
const API_BASE = "https://YOUR-API-DOMAIN.com";
```

to your real backend URL.

Then upload `public/index.html` to GitHub Pages.

## 4. Register in dashboard

Open the website.

Create your email/password account.

Click:

`+ Connect MT5`

The dashboard generates a tracker token such as:

```text
mt5t_...
```

Copy it immediately. It is only displayed once.

## 5. Configure MT5 EA

Open:

`mt5/MT5Tracker.mq5`

Compile it in MetaEditor.

Attach it to any chart.

Set:

```text
ApiUrl=https://YOUR-API-DOMAIN.com/api/mt5/ingest
TrackerToken=mt5t_...
```

In MT5 go to:

Tools → Options → Expert Advisors

Enable:

`Allow WebRequest for listed URL`

Add your API origin, for example:

```text
https://tracker-api.example.com
```

## 6. What happens automatically

The EA sends:

- MT5 broker name
- MT5 account number
- account currency
- balance
- equity
- floating P&L
- margin
- free margin
- closed trades
- ticket
- symbol
- buy/sell
- lots
- entry/exit
- SL/TP
- RR when available
- profit
- commission
- swap
- magic number
- close reason (SL/TP/etc.)

The dashboard reads only data belonging to the logged-in website user.

## Security

The web dashboard never stores your MT5 broker password.

Your website login password is hashed using bcrypt.

The browser receives a JWT after login.

The MT5 tracker token is stored in PostgreSQL only as a SHA-256 hash.

Do not expose `.env` publicly.

Use HTTPS in production.

## Important

For live tracking, MT5 must be running. For 24/7 tracking, run MT5 on a Windows VPS.

