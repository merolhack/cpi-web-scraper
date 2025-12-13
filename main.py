import os
import asyncio
import logging
import argparse
import json
from datetime import datetime
from typing import Optional, Dict, Any, List, Set

import httpx
from playwright.async_api import async_playwright, Page, Playwright, TimeoutError as PlaywrightTimeoutError
from supabase import create_client, Client
from bs4 import BeautifulSoup
from dotenv import load_dotenv

from proxy_client import ProxyRotator

# Load environment variables
load_dotenv()

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# --- Configuration ---
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY")

# Global Proxy Rotator Instance
rotator = ProxyRotator()

# --- Supabase Client ---
def get_supabase_client() -> Optional[Client]:
    if not SUPABASE_URL or not SUPABASE_KEY:
        logger.error("Supabase credentials missing.")
        return None
    
    # Log Project ID for debugging
    try:
        project_id = SUPABASE_URL.split("//")[1].split(".")[0]
        logger.info(f"Connecting to Supabase Project: {project_id}")
    except Exception:
        logger.warning("Could not parse Supabase Project ID.")

    return create_client(SUPABASE_URL, SUPABASE_KEY)

async def fetch_establishments(client: Client) -> List[Dict[str, Any]]:
    """
    Fetches all active establishments from the database.
    """
    try:
        response = client.table("cpi_establishments").select("*").execute()
        establishments = response.data
        logger.info(f"Fetched {len(establishments)} establishments from DB.")
        for est in establishments:
            logger.info(f"Establishment Found: ID={est.get('establishment_id')}, Name='{est.get('establishment_name')}'")
        return establishments
    except Exception as e:
        logger.error(f"Failed to fetch establishments: {e}")
        return []

async def fetch_products_to_scrape(client: Client, limit: int = 3) -> List[Dict[str, Any]]:
    """
    Fetches a batch of products that need scraping for the current month.
    Uses the RPC 'get_products_to_scrape'.
    """
    try:
        response = client.rpc("get_products_to_scrape", {"p_limit": limit}).execute()
        products = response.data
        logger.info(f"Fetched {len(products)} products to scrape (Limit: {limit}).")
        return products
    except Exception as e:
        logger.error(f"Failed to fetch products: {e}")
        return []

async def check_existing_price(client: Client, product_id: int, retailer_id: int) -> bool:
    """
    Checks if a price exists for the given product and retailer in the current month.
    """
    try:
        # Calculate start of current month
        now = datetime.now()
        start_of_month = datetime(now.year, now.month, 1).strftime("%Y-%m-%d")
        
        response = client.table("cpi_prices") \
            .select("price_id") \
            .eq("product_id", product_id) \
            .eq("establishment_id", retailer_id) \
            .gte("date", start_of_month) \
            .limit(1) \
            .execute()
            
        exists = len(response.data) > 0
        if exists:
            logger.info(f"Price already exists for Product {product_id} at Retailer {retailer_id} this month. Skipping.")
        return exists
    except Exception as e:
        logger.error(f"Failed to check existing price: {e}")
        return False # Assume false to retry if check fails, or True to be safe? False is better for data completeness.

async def persist_price(client: Client, product: Dict[str, Any], retailer_id: int, price: float):
    """
    Persists the price to Supabase via RPC `add_product_and_price`.
    """
    if not client:
        return

    payload = {
        "p_ean_code": product['ean_code'],
        "p_price_value": price,
        "p_product_name": product['product_name'],
        "p_price_date": datetime.now().strftime("%Y-%m-%d"),
        "p_establishment_id": retailer_id,
        "p_country_id": product['country_id'] or 1, # Default to 1 if null
        "p_location_id": 1,
        "p_category_id": product['category_id'] or 1 # Default to 1 if null
    }

    try:
        response = client.rpc("add_product_and_price", payload).execute()
        logger.info(f"Successfully persisted price ${price} for {product['product_name']} at Retailer {retailer_id}")
    except Exception as e:
        logger.error(f"Failed to persist data for Retailer {retailer_id}: {e}")

# --- Hard Target Scrapers (Playwright) ---

async def scrape_walmart(playwright, product: Dict[str, Any]) -> Optional[float]:
    """
    Scrapes Walmart Mexico using Trust Propagation via Google with Proxy Rotation.
    """
    price = None
    retries = 5
    ean = product['ean_code']
    name = product['product_name']
    
    for attempt in range(retries):
        proxy_data = rotator.get_proxy()
        proxy_url = proxy_data['url'] if proxy_data else None
        proxy_id = proxy_data['proxy_id'] if proxy_data else None
        
        logger.info(f"[Walmart] Attempt {attempt+1}/{retries} for {name} using proxy: {proxy_url}")
        
        launch_args = {"headless": True, "args": ["--no-sandbox"]}
        if proxy_url:
            launch_args["proxy"] = {"server": "per-context"}

        browser = await playwright.chromium.launch(**launch_args)
        context = None
        
        try:
            context_args = {
                "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "viewport": {"width": 1920, "height": 1080}
            }
            if proxy_url:
                context_args["proxy"] = {"server": proxy_url}
                
            context = await browser.new_context(**context_args)
            
            # Block resources
            await context.route("**/*", lambda route: route.abort() 
                if route.request.resource_type in ["image", "media", "font", "stylesheet"] 
                else route.continue_())

            page = await context.new_page()
            
            # 1. Start at Google
            await page.goto("https://www.google.com.mx", timeout=30000)
            await page.wait_for_selector("textarea[name='q']") 
            
            # 2. Simulate human typing
            search_query = f"{name} Walmart"
            await page.type("textarea[name='q']", search_query, delay=100)
            await page.press("textarea[name='q']", "Enter")
            
            # 3. Click organic result
            await page.wait_for_selector("a[href*='walmart.com.mx']", timeout=30000)
            
            async with page.expect_popup() as popup_info:
                await page.click("a[href*='walmart.com.mx']")
            
            target_page = await popup_info.value
            await target_page.wait_for_load_state("domcontentloaded")
            
            # 4. Extract from __NEXT_DATA__
            if ean not in target_page.url:
                 logger.info("[Walmart] Navigating to specific product search...")
                 await target_page.goto(f"https://www.walmart.com.mx/productos?Ntt={ean}", timeout=30000)
                 await target_page.wait_for_load_state("networkidle")
                 await target_page.click("div[data-automation-id='product-container'] a")
                 await target_page.wait_for_load_state("domcontentloaded")

            next_data = await target_page.evaluate("window.__NEXT_DATA__")
            
            if next_data:
                try:
                    product_data = next_data['props']['pageProps']['initialData']['data']['product']
                    price_info = product_data['price']['price'] 
                    price = float(price_info.get('price', 0)) or float(price_info.get('leadPrice', 0))
                    if price:
                        if proxy_id: rotator.report_success(proxy_id)
                        return price # Success
                except KeyError:
                    logger.warning("[Walmart] JSON structure mismatch.")
                    
        except (PlaywrightTimeoutError, Exception) as e:
            logger.warning(f"[Walmart] Attempt {attempt+1} failed: {e}")
            if proxy_id: rotator.report_failure(proxy_id)
        finally:
            if context:
                await context.close()
            await browser.close()
            
    return None

async def scrape_bodega(playwright: Playwright, product: Dict[str, Any]) -> Optional[float]:
    """
    Scrapes Bodega Aurrera using Playwright with Proxy Rotation.
    """
    price = None
    retries = 5
    ean = product['ean_code']
    name = product['product_name']
    
    for attempt in range(retries):
        proxy_data = rotator.get_proxy()
        proxy_server = proxy_data['url'] if proxy_data else None
        proxy_id = proxy_data['proxy_id'] if proxy_data else None
        
        logger.info(f"[Bodega] Attempt {attempt+1}/{retries} for {name} using proxy: {proxy_server}")

        browser = None
        try:
            browser = await playwright.chromium.launch(
                headless=True,
                proxy={"server": proxy_server} if proxy_server else None
            )
            
            context = await browser.new_context(
                user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
            )
            
            page = await context.new_page()
            
            # Optimize: Block images, fonts, media
            await context.route("**/*", lambda route: route.abort() if route.request.resource_type in ["image", "media", "font", "stylesheet"] else route.continue_())
            
            url = f"https://www.bodegaaurrera.com.mx/productos?Ntt={ean}"
            await page.goto(url, timeout=30000)
            await page.wait_for_load_state("networkidle")
            
            await page.click("div[data-automation-id='product-container'] a", timeout=30000)
            await page.wait_for_load_state("domcontentloaded")
            
            next_data = await page.evaluate("window.__NEXT_DATA__")
            if next_data:
                product_data = next_data['props']['pageProps']['initialData']['data']['product']
                price_info = product_data['price']['price']
                price = float(price_info.get('price', 0)) or float(price_info.get('leadPrice', 0))
                if price:
                    if proxy_id: rotator.report_success(proxy_id)
                    return price # Success

        except (PlaywrightTimeoutError, Exception) as e:
            logger.warning(f"[Bodega] Attempt {attempt+1} failed: {e}")
            if proxy_id: rotator.report_failure(proxy_id)
        finally:
            if context:
                await context.close()
            await browser.close()
            
    return None


# --- Soft Target Scrapers (HTTPX) ---

async def scrape_chedraui(playwright: Playwright, product: Dict[str, Any]) -> Optional[float]:
    """
    Simulates VTEX Search API call for Chedraui with Proxy Rotation.
    """
    price = None
    retries = 5
    ean = product['ean_code']
    name = product['product_name']
    
    for attempt in range(retries):
        proxy_data = rotator.get_proxy()
        proxy_url = proxy_data['url'] if proxy_data else None
        proxy_id = proxy_data['proxy_id'] if proxy_data else None
        
        logger.info(f"[Chedraui] Attempt {attempt+1}/{retries} for {name} using proxy: {proxy_url}")
        
        try:
            async with httpx.AsyncClient(proxy=proxy_url, timeout=10) as client:
                # Try EAN first
                url = f"https://www.chedraui.com.mx/api/catalog_system/pub/products/search?ft={ean}"
                headers = {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    "Accept": "application/json"
                }
                
                response = await client.get(url, headers=headers)
                
                if response.status_code == 200:
                    data = response.json()
                    if data and len(data) > 0:
                        item = data[0]
                        price = item['items'][0]['sellers'][0]['commertialOffer']['Price']
                        if proxy_id: rotator.report_success(proxy_id)
                        return float(price)
                    else:
                        # Fallback to Name Search
                        logger.info(f"[Chedraui] EAN not found, trying name search for '{name}'")
                        url_name = f"https://www.chedraui.com.mx/api/catalog_system/pub/products/search?ft={name}"
                        response_name = await client.get(url_name, headers=headers)
                        if response_name.status_code == 200:
                            data_name = response_name.json()
                            if data_name and len(data_name) > 0:
                                # Simple heuristic: pick first result
                                item = data_name[0]
                                price = item['items'][0]['sellers'][0]['commertialOffer']['Price']
                                if proxy_id: rotator.report_success(proxy_id)
                                return float(price)

                elif response.status_code in [403, 502, 503]:
                    logger.warning(f"[Chedraui] Blocked/Error {response.status_code}")
                    if proxy_id: rotator.report_failure(proxy_id)
                else:
                    logger.warning(f"[Chedraui] API returned {response.status_code}")
                    
        except (httpx.ConnectError, httpx.TimeoutException, Exception) as e:
            logger.warning(f"[Chedraui] Attempt {attempt+1} failed: {e}")
            if proxy_id: rotator.report_failure(proxy_id)
            
    return None

async def scrape_soriana(playwright: Playwright, product: Dict[str, Any]) -> Optional[float]:
    """
    Simulates Salesforce Commerce Cloud search for Soriana with Proxy Rotation.
    """
    price = None
    retries = 5
    ean = product['ean_code']
    name = product['product_name']
    
    for attempt in range(retries):
        proxy_data = rotator.get_proxy()
        proxy_url = proxy_data['url'] if proxy_data else None
        proxy_id = proxy_data['proxy_id'] if proxy_data else None
        
        logger.info(f"[Soriana] Attempt {attempt+1}/{retries} for {name} using proxy: {proxy_url}")
        
        try:
            async with httpx.AsyncClient(proxy=proxy_url, timeout=10) as client:
                url = "https://www.soriana.com/on/demandware.store/Sites-Soriana-Site/es_MX/Search-ShowAjax"
                headers = {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    "Accept": "application/json, text/html"
                }
                
                # Try EAN first
                params = {"q": ean, "lang": "es_MX"}
                response = await client.get(url, params=params, headers=headers)
                
                if response.status_code == 200:
                    found = False
                    try:
                        data = response.json()
                        if 'productSearch' in data and 'productIds' in data['productSearch'] and data['productSearch']['productIds']:
                            # Need to fetch product details if IDs found, but let's assume we need to parse HTML if JSON is partial
                            # Actually Soriana JSON usually returns IDs, then we need another call? 
                            # Or sometimes it returns HTML in 'grid' field?
                            pass 
                    except json.JSONDecodeError:
                        # HTML Fallback
                        soup = BeautifulSoup(response.text, 'html.parser')
                        if soup.select_one(".price .sales .value"):
                            price_element = soup.select_one(".price .sales .value")
                            price_text = price_element.get_text(strip=True).replace("$", "").replace(",", "")
                            if proxy_id: rotator.report_success(proxy_id)
                            return float(price_text)
                        
                    # Fallback to Name Search if EAN failed
                    logger.info(f"[Soriana] EAN not found, trying name search for '{name}'")
                    params_name = {"q": name, "lang": "es_MX"}
                    response_name = await client.get(url, params=params_name, headers=headers)
                    
                    if response_name.status_code == 200:
                         soup = BeautifulSoup(response_name.text, 'html.parser')
                         # Try multiple selectors for price in search results
                         price_element = soup.select_one(".price .sales .value") or \
                                         soup.select_one(".product-tile .price .value") or \
                                         soup.select_one(".product-price")
                                         
                         if price_element:
                             price_text = price_element.get_text(strip=True).replace("$", "").replace(",", "")
                             if proxy_id: rotator.report_success(proxy_id)
                             return float(price_text)
                         else:
                             logger.warning(f"[Soriana] Price element not found in search results for '{name}'")

                elif response.status_code in [403, 502, 503]:
                    logger.warning(f"[Soriana] Blocked/Error {response.status_code}")
                    if proxy_id: rotator.report_failure(proxy_id)
                    
        except (httpx.ConnectError, httpx.TimeoutException, Exception) as e:
            logger.warning(f"[Soriana] Attempt {attempt+1} failed: {e}")
            if proxy_id: rotator.report_failure(proxy_id)
            
    return None

async def scrape_lacomer(playwright: Playwright, product: Dict[str, Any]) -> Optional[float]:
    """
    Simulates La Comer internal API with Proxy Rotation.
    """
    price = None
    retries = 5
    ean = product['ean_code']
    
    for attempt in range(retries):
        proxy_data = rotator.get_proxy()
        proxy_url = proxy_data['url'] if proxy_data else None
        proxy_id = proxy_data['proxy_id'] if proxy_data else None
        
        logger.info(f"[La Comer] Attempt {attempt+1}/{retries} for {ean} using proxy: {proxy_url}")
        
        try:
            async with httpx.AsyncClient(proxy=proxy_url, timeout=15) as client:
                url = "https://www.lacomer.com.mx/lacomer-api/api/v1/public/articulopasillo/detalleArticulo"
                params = {
                    "artEan": ean,
                    "noPagina": "1",
                    "succId": "287"
                }
                headers = {
                    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                    "Accept": "application/json, text/plain, */*",
                    "Accept-Language": "es-MX,es;q=0.9,en-US;q=0.8,en;q=0.7",
                    "Referer": "https://www.lacomer.com.mx/",
                    "Origin": "https://www.lacomer.com.mx",
                    "Sec-Ch-Ua": '"Not_A Brand";v="8", "Chromium";v="120", "Google Chrome";v="120"',
                    "Sec-Ch-Ua-Mobile": "?0",
                    "Sec-Ch-Ua-Platform": '"Windows"',
                    "Sec-Fetch-Dest": "empty",
                    "Sec-Fetch-Mode": "cors",
                    "Sec-Fetch-Site": "same-origin",
                    "Connection": "keep-alive"
                }
                
                response = await client.get(url, params=params, headers=headers)
                
                if response.status_code == 200:
                    data = response.json()
                    if 'estrucArti' in data and data['estrucArti']:
                        if proxy_id: rotator.report_success(proxy_id)
                        return float(data['estrucArti'].get('artPrven', 0))
                elif response.status_code in [403, 502, 503]:
                    logger.warning(f"[La Comer] Blocked/Error {response.status_code}")
                    if proxy_id: rotator.report_failure(proxy_id)
                else:
                    logger.warning(f"[La Comer] API returned {response.status_code}")

        except (httpx.ConnectError, httpx.TimeoutException, Exception) as e:
            logger.warning(f"[La Comer] Attempt {attempt+1} failed: {e}")
            if proxy_id: rotator.report_failure(proxy_id)
            
    return None


async def fetch_specific_product(client: Client, product_id: int) -> List[Dict[str, Any]]:
    """
    Fetches a single product by ID.
    """
    try:
        response = client.table("cpi_products").select("*").eq("product_id", product_id).execute()
        if response.data:
            logger.info(f"Fetched specific product: {response.data[0]['product_name']}")
            return response.data
        else:
            logger.warning(f"Product {product_id} not found.")
            return []
    except Exception as e:
        logger.error(f"Failed to fetch product {product_id}: {e}")
        return []

# --- Scraper Registry ---
# Maps establishment names (from DB) to scraper functions.
SCRAPER_REGISTRY = {
    "Walmart": scrape_walmart,
    "Wal-Mart": scrape_walmart, # Match DB Name
    "Bodega Aurrera": scrape_bodega,
    "Chedraui": scrape_chedraui,
    "Soriana": scrape_soriana,
    "La Comer": scrape_lacomer
}

async def main():
    logger.info("Starting Hybrid Scraper...")
    
    # Parse Arguments
    parser = argparse.ArgumentParser(description="CPI Web Scraper")
    parser.add_argument("--product_id", type=int, help="Scrape a specific product ID only")
    parser.add_argument("--all", action="store_true", help="Scrape ALL products in the database (no limit)")
    args = parser.parse_args()

    client = get_supabase_client()
    if not client:
        return

    # Fetch Establishments
    establishments = await fetch_establishments(client)
    if not establishments:
        logger.error("No establishments found in DB. Exiting.")
        return

    async with async_playwright() as playwright:
        # Determine which products to scrape
        if args.product_id:
            logger.info(f"Mode: Single Product (ID: {args.product_id})")
            products = await fetch_specific_product(client, args.product_id)
        elif args.all:
            logger.info("Mode: ALL Products (no limit)")
            products = await fetch_products_to_scrape(client, limit=9999)
        else:
            logger.info("Mode: Batch Scraping (limit 3)")
            products = await fetch_products_to_scrape(client, limit=3)

        if not products:
            logger.info("No products to scrape.")
            return

        for product in products:
            product_id = product['product_id']
            name = product['product_name']
            ean = product['ean_code']
            
            logger.info(f"--- Processing Product: {name} (EAN: {ean}) ---")
            
            # Scrape all retailers for this product
            for establishment in establishments:
                est_id = establishment['establishment_id']
                est_name = establishment['establishment_name']
                
                # Get the scraper function
                scraper_func = SCRAPER_REGISTRY.get(est_name)
                
                if not scraper_func:
                    logger.warning(f"No scraper implemented for '{est_name}'. Skipping. (Available: {list(SCRAPER_REGISTRY.keys())})")
                    continue
                
                # Check if price exists
                if await check_existing_price(client, product_id, est_id):
                    continue
                
                # Execute scraper
                try:
                    price = await scraper_func(playwright, product)
                    if price:
                        await persist_price(client, product, est_id, price)
                    else:
                        logger.warning(f"No price found for {est_name}")
                except Exception as e:
                    logger.error(f"Error scraping {est_name}: {e}")

    logger.info("Scraping Cycle Completed.")

if __name__ == "__main__":
    asyncio.run(main())
