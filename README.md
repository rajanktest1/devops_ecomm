<<<<<<< HEAD
# 🛍️ ShopEmoji — Simple E-Commerce Web App

A full-stack e-commerce demo built on a **3-tier architecture**:

| Tier | Technology |
|------|-----------|
| Frontend | React 18 + Vite 6 + React Router 6 |
| Backend | Node.js + Express 4 |
| Database | MySQL 8 |

---

## Features

- **Home page** — responsive grid of 20 sample products with emoji product images
- **Product page** — description, price, stock status, quantity picker, add-to-cart, star-rated user reviews
- **Cart page** — item list with live quantity update (+/−), remove item, shipping calculation, and order total

---

## Project Structure

```
ecomm/
├── .gitignore
├── README.md
├── backend/
│   ├── .env.example          # ← copy to .env and fill in your credentials
│   ├── package.json
│   └── src/
│       ├── index.js          # Express server entry point
│       ├── db/
│       │   ├── schema.sql    # DDL — creates ecomm database + 3 tables
│       │   ├── connection.js # mysql2 connection pool
│       │   └── seed.js       # Inserts 20 products + 44 sample reviews
│       └── routes/
│           ├── products.js   # GET /api/products, GET /api/products/:id
│           └── cart.js       # GET / POST / PUT / DELETE /api/cart
└── frontend/
    ├── .env.example
    ├── index.html
    ├── vite.config.js        # /api proxy → localhost:5000
    ├── package.json
    └── src/
        ├── App.jsx
        ├── main.jsx
        ├── index.css
        ├── components/
        │   ├── Navbar.jsx
        │   └── ProductCard.jsx
        └── pages/
            ├── HomePage.jsx
            ├── ProductPage.jsx
            └── CartPage.jsx
```

---

## Prerequisites

| Tool | Version | Notes |
|------|---------|-------|
| Node.js | 18 + | https://nodejs.org |
| npm | 9 + | bundled with Node |
| MySQL Server | 8 + | see setup section below |

---

## Local Setup

### 1 — Clone the repository

```bash
git clone <your-repo-url>
cd ecomm
```

### 2 — Set up MySQL

You need a running MySQL 8 instance. Three options:

**Option A — MySQL Installer (Windows)**
Download from https://dev.mysql.com/downloads/installer/ and install **MySQL Server** + **MySQL Command Line Client**.

**Option B — Docker (no installer needed)**
```bash
docker run --name ecomm-mysql \
  -e MYSQL_ROOT_PASSWORD=yourpassword \
  -e MYSQL_DATABASE=ecomm \
  -p 3306:3306 \
  -d mysql:8
```

**Option C — MySQL Workbench**
Install Workbench alongside MySQL Server for a GUI experience.

### 3 — Create the database schema

**Via MySQL CLI:**
```bash
mysql -u root -p
# enter your password when prompted, then inside the MySQL shell:
source d:/devops_splitrepo/ecomm/backend/src/db/schema.sql
```

**Via MySQL Workbench:**
File → Open SQL Script → select `backend/src/db/schema.sql` → press Ctrl+Shift+Enter

**Via Docker:**
```bash
docker exec -i ecomm-mysql mysql -uroot -pyourpassword ecomm \
  < backend/src/db/schema.sql
```

### 4 — Configure backend environment variables

```bash
cd backend
cp .env.example .env     # Windows: Copy-Item .env.example .env
```

Edit `backend/.env`:
```
DB_HOST=localhost
DB_PORT=3306
DB_USER=root
DB_PASSWORD=your_mysql_password_here
DB_NAME=ecomm
PORT=5000
CORS_ORIGIN=http://localhost:5173
```

> ⚠️ **Never commit `.env` to git.** It is already in `.gitignore`.

### 5 — Install dependencies

```bash
# Backend
cd backend
npm install

# Frontend
cd ../frontend
npm install
```

### 6 — Seed the database

```bash
cd backend
npm run seed
# Expected output:
# 🌱  Seeding products…
#    ✔  Inserted 20 products
# 🌱  Seeding reviews…
#    ✔  Inserted 44 reviews
# ✅  Seed complete.
```

### 7 — Start the backend

```bash
cd backend
npm run dev     # starts nodemon on http://localhost:5000
```

Verify: open http://localhost:5000/api/products — should return a JSON array of 20 products.

### 8 — Start the frontend

Open a **second terminal**:

```bash
cd frontend
npm run dev     # starts Vite on http://localhost:5173
```

Browse **http://localhost:5173** 🎉

---

## API Reference

### Products

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/products` | List all 20 products |
| GET | `/api/products/:id` | Single product + its reviews |

### Cart

| Method | Endpoint | Body | Description |
|--------|----------|------|-------------|
| GET | `/api/cart` | — | All cart items (joined with product info) |
| POST | `/api/cart` | `{ product_id, quantity }` | Add item (upserts if already in cart) |
| PUT | `/api/cart/:id` | `{ quantity }` | Update item quantity |
| DELETE | `/api/cart/:id` | — | Remove item from cart |

### Health check

```
GET /health  →  { "status": "ok" }
```

---

## Database Schema

```
products        reviews              cart_items
---------       --------             ----------
id (PK)         id (PK)              id (PK)
name            product_id (FK)      product_id (FK, UNIQUE)
description     reviewer_name        quantity
price           rating (1–5)         added_at
emoji           comment
category        created_at
stock
created_at
```

---

## Security Notes

- All SQL queries use **parameterised statements** — protected against SQL injection
- Real credentials live only in `backend/.env`, which is excluded by `.gitignore`
- Vite dev server is bound to `localhost` only (`host: 'localhost'` in `vite.config.js`) — prevents the esbuild [GHSA-67mh-4wv8-2f99](https://github.com/advisories/GHSA-67mh-4wv8-2f99) CORS vulnerability
- CORS is locked to `CORS_ORIGIN` env var (default: `http://localhost:5173`)
- Input IDs are validated as positive integers before hitting the database

---

## Scripts Reference

| Directory | Command | Action |
|-----------|---------|--------|
| `backend` | `npm run dev` | Start backend with nodemon (auto-restart) |
| `backend` | `npm start` | Start backend (production-style, no nodemon) |
| `backend` | `npm run seed` | Re-seed the database (clears existing data first) |
| `frontend` | `npm run dev` | Start Vite dev server |
| `frontend` | `npm run build` | Build production bundle to `frontend/dist/` |
| `frontend` | `npm run preview` | Preview production build locally |

---

## Pushing to GitHub

```bash
# From the ecomm/ root
git add .
git commit -m "feat: initial e-commerce app"
git remote add origin https://github.com/<your-username>/<your-repo>.git
git push -u origin master
```

> Make sure `backend/.env` does **not** appear in `git status` before pushing.
> Run `git status` and verify only source files are listed.
=======
# devops_ecomm
devops Implementation of the webapp for practice
>>>>>>> 1c0231a5ffb280abe4333a64a502eaafacf5afd7
