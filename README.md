# CPI Web Scraper

A hybrid web scraper for collecting Consumer Price Index (CPI) data from Mexican retailers.

## Supported Retailers

| Retailer | Method | Strategy |
|----------|--------|----------|
| Walmart | Playwright (Browser) | 5 proxies → direct fallback |
| Bodega Aurrera | Playwright (Browser) | 5 proxies → direct fallback |
| Chedraui | HTTPX (API) | Direct first → proxy fallback |
| Soriana | HTTPX (HTML) | Direct first → proxy fallback |
| La Comer | HTTPX (API) | Direct first → proxy fallback |

## Performance Analysis

### Timing Data (based on actual run)

| Metric | Value |
|--------|-------|
| **Proxy Harvester** | ~8-10 seconds |
| **Per Product (1 store)** | ~1.5 minutes |
| **Per Product (5 stores)** | ~7.5 minutes |

### Capacity Estimates

| Products | Stores | Estimated Time |
|----------|--------|----------------|
| 1 | 5 | ~7.5 min |
| 11 | 5 | ~16 min (observed) |
| 50 | 5 | ~75 min |
| 100 | 5 | ~150 min (2.5 hrs) |
| 100 | 2 | ~60 min |

### GitHub Actions Limits

| Runner Type | Max Job Duration |
|-------------|-----------------|
| **GitHub-hosted** | 6 hours (360 min) |
| Self-hosted | 5 days |

**Safe capacity**: ~240 products/run (all 5 stores) within 6-hour limit.

## Setup

```bash
pip install -r requirements.txt
playwright install chromium
playwright install-deps
```

## Usage

```bash
# Scrape all products
python main.py --all

# Scrape specific product
python main.py --product_id 1
```

## Environment Variables

| Variable | Description |
|----------|-------------|
| `SUPABASE_URL` | Supabase project URL |
| `SUPABASE_KEY` | Supabase service key |

## Workflows

- **Hybrid Scraper** (`scraper.yml`): Runs hourly, harvests proxies and scrapes all products
- **Proxy Harvester** (`proxy_harvester.yml`): Runs every 4 hours, refreshes proxy pool
