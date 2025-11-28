import asyncio
import json
import os
import random
import logging
from datetime import datetime
from typing import Optional, Dict, Any

import httpx
from playwright.async_api import async_playwright, Page
from supabase import create_client, Client
from bs4 import BeautifulSoup
from dotenv import load_dotenv

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

PRODUCT_EAN = "7501055904143"
PRODUCT_NAME = "Leche Alpura Deslactosada Light 1L"

# Retailer Mapping (ID from DB)
RETAILERS = {
    "WALMART": 1,
    "BODEGA_AURRERA": 2,
    "CHEDRAUI": 3,
    "SORIANA": 4,
    "LA_COMER": 5
}

# --- Supabase Client ---
def get_supabase_client() -> Optional[Client]:
    if not SUPABASE_URL or not SUPABASE_KEY:
        logger.error("Supabase credentials missing.")
        return None
    return create_client(SUPABASE_URL, SUPABASE_KEY)

async def persist_price(client: Client, retailer_id: int, price: float):
    """
    Persists the price to Supabase via RPC `add_product_and_price`.
    Verified against API-Specification.txt.
    """
    if not client:
        return

    payload = {
        "p_ean_code": PRODUCT_EAN,
        "p_price_value": price,
        "p_product_name": PRODUCT_NAME,
        "p_price_date": datetime.now().strftime("%Y-%m-%d"),
        "p_establishment_id": retailer_id,
        "p_country_id": 1,
        "p_location_id": 1,
        "p_category_id": 1
    }

    try:
        response = client.rpc("add_product_and_price", payload).execute()
        logger.info(f"Successfully persisted price ${price} for Retailer {retailer_id}")
    except Exception as e:
        logger.error(f"Failed to persist data for Retailer {retailer_id}: {e}")

# --- Hard Target Scrapers (Playwright) ---

async def scrape_walmart(playwright) -> Optional[float]:
    """
    Scrapes Walmart Mexico using Trust Propagation via Google.
    Extracts price from __NEXT_DATA__ JSON.
    """
    browser = await playwright.chromium.launch(headless=True)
    context = await browser.new_context(
        user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        viewport={"width": 1920, "height": 1080}
    )
    
    # Block resources to save bandwidth/RAM
    await context.route("**/*", lambda route: route.abort() 
        if route.request.resource_type in ["image", "media", "font", "stylesheet"] 
        else route.continue_())

    page = await context.new_page()
    price = None

    try:
        logger.info("[Walmart] Starting Trust Propagation...")
        # 1. Start at Google
        await page.goto("https://www.google.com.mx")
        await page.wait_for_selector("textarea[name='q']") 
        
        # 2. Simulate human typing
        search_query = f"{PRODUCT_NAME} Walmart"
        await page.type("textarea[name='q']", search_query, delay=100)
        await page.press("textarea[name='q']", "Enter")
        
        # 3. Click organic result (Look for walmart.com.mx link)
        await page.wait_for_selector("a[href*='walmart.com.mx']", timeout=10000)
        
        async with page.expect_popup() as popup_info:
            await page.click("a[href*='walmart.com.mx']")
        
        target_page = await popup_info.value
        await target_page.wait_for_load_state("domcontentloaded")
        
        # 4. Extract from __NEXT_DATA__
        if "7501055904143" not in target_page.url:
             logger.info("[Walmart] Navigating to specific product search...")
             await target_page.goto(f"https://www.walmart.com.mx/productos?Ntt={PRODUCT_EAN}")
             await target_page.wait_for_load_state("networkidle")
             await target_page.click("div[data-automation-id='product-container'] a")
             await target_page.wait_for_load_state("domcontentloaded")

        next_data = await target_page.evaluate("window.__NEXT_DATA__")
        
        if next_data:
            try:
                product_data = next_data['props']['pageProps']['initialData']['data']['product']
                price_info = product_data['price']['price'] 
                price = float(price_info.get('price', 0)) or float(price_info.get('leadPrice', 0))
            except KeyError:
                logger.warning("[Walmart] JSON structure mismatch.")
                pass
                
    except Exception as e:
        logger.error(f"[Walmart] Error: {e}")
    finally:
        await browser.close()
        
    return price

async def scrape_bodega(playwright) -> Optional[float]:
    """
    Scrapes Bodega Aurrera.
    """
    browser = await playwright.chromium.launch(headless=True)
    context = await browser.new_context(user_agent="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
    page = await context.new_page()
    price = None
    
    try:
        logger.info("[Bodega] Starting extraction...")
        url = f"https://www.bodegaaurrera.com.mx/productos?Ntt={PRODUCT_EAN}"
        await page.goto(url)
        await page.wait_for_load_state("networkidle")
        
        try:
             await page.click("div[data-automation-id='product-container'] a", timeout=5000)
             await page.wait_for_load_state("domcontentloaded")
             
             next_data = await page.evaluate("window.__NEXT_DATA__")
             if next_data:
                 product_data = next_data['props']['pageProps']['initialData']['data']['product']
                 price_info = product_data['price']['price']
                 price = float(price_info.get('price', 0)) or float(price_info.get('leadPrice', 0))
        except Exception as e:
            logger.error(f"[Bodega] Product not found or layout changed: {e}")

    except Exception as e:
        logger.error(f"[Bodega] Error: {e}")
    finally:
        await browser.close()
        
    return price


# --- Soft Target Scrapers (HTTPX) ---

async def scrape_chedraui() -> Optional[float]:
    """
    Simulates VTEX Search API call for Chedraui.
    """
    price = None
    try:
        async with httpx.AsyncClient() as client:
            url = f"https://www.chedraui.com.mx/api/catalog_system/pub/products/search?ft={PRODUCT_EAN}"
            headers = {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Accept": "application/json"
            }
            
            response = await client.get(url, headers=headers, timeout=10)
            if response.status_code == 200:
                data = response.json()
                if data and len(data) > 0:
                    item = data[0]
                    price = item['items'][0]['sellers'][0]['commertialOffer']['Price']
            else:
                logger.warning(f"[Chedraui] API returned {response.status_code}")
                
    except Exception as e:
        logger.error(f"[Chedraui] Error: {e}")
        
    return float(price) if price else None

async def scrape_soriana() -> Optional[float]:
    """
    Simulates Salesforce Commerce Cloud search for Soriana.
    Includes BeautifulSoup fallback if API returns HTML.
    """
    price = None
    try:
        async with httpx.AsyncClient() as client:
            url = "https://www.soriana.com/on/demandware.store/Sites-Soriana-Site/es_MX/Search-ShowAjax"
            params = {"q": PRODUCT_EAN, "lang": "es_MX"}
            headers = {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
                "Accept": "application/json, text/html"
            }
            
            response = await client.get(url, params=params, headers=headers, timeout=10)
            
            if response.status_code == 200:
                try:
                    data = response.json()
                    if 'productSearch' in data and 'productIds' in data['productSearch']:
                        # Logic to extract price from JSON if available
                        pass
                except json.JSONDecodeError:
                    # HTML Fallback
                    soup = BeautifulSoup(response.text, 'html.parser')
                    # Try to find price in product tile
                    price_element = soup.select_one(".price .sales .value")
                    if price_element:
                        price_text = price_element.get_text(strip=True).replace("$", "").replace(",", "")
                        price = float(price_text)
            
    except Exception as e:
        logger.error(f"[Soriana] Error: {e}")
        
    return price

async def scrape_lacomer() -> Optional[float]:
    """
    Simulates La Comer internal API.
    """
    price = None
    try:
        async with httpx.AsyncClient() as client:
            # La Comer API (often Algolia or internal)
            # Endpoint: https://www.lacomer.com.mx/api/articulo/articulos-alias/7501055904143
            # Or search: https://www.lacomer.com.mx/api/v2/articulo/search
            
            url = "https://www.lacomer.com.mx/api/articulo/articulos-alias/7501055904143" # Direct EAN lookup often works
            headers = {
                "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            }
            
            response = await client.get(url, headers=headers, timeout=10)
            if response.status_code == 200:
                data = response.json()
                # Structure: { "precioVenta": 123.45, ... }
                if 'precioVenta' in data:
                    price = float(data['precioVenta'])
                elif 'articulos' in data and len(data['articulos']) > 0:
                     price = float(data['articulos'][0].get('precioVenta', 0))

    except Exception as e:
        logger.error(f"[La Comer] Error: {e}")
        
    return price


# --- Main Orchestrator ---

async def main():
    logger.info("Starting Hybrid Scraper...")
    
    supabase = get_supabase_client()
    if not supabase:
        logger.error("Aborting: Supabase client not initialized.")
        return

    # Define tasks
    tasks = []
    
    # Playwright Tasks
    async with async_playwright() as p:
        # We run playwright tasks sequentially or in parallel? 
        # Parallel is faster but heavier. Let's do parallel.
        
        # Note: Playwright objects (browser) are bound to the async context.
        # We need to pass the 'p' object to functions.
        
        # Hard Targets
        walmart_task = scrape_walmart(p)
        bodega_task = scrape_bodega(p)
        
        # Soft Targets
        chedraui_task = scrape_chedraui()
        soriana_task = scrape_soriana()
        lacomer_task = scrape_lacomer()
        
        # Execute all
        results = await asyncio.gather(
            walmart_task, 
            bodega_task, 
            chedraui_task, 
            soriana_task, 
            lacomer_task, 
            return_exceptions=True
        )
        
        # Process Results
        retailer_ids = [
            RETAILERS["WALMART"],
            RETAILERS["BODEGA_AURRERA"],
            RETAILERS["CHEDRAUI"],
            RETAILERS["SORIANA"],
            RETAILERS["LA_COMER"]
        ]
        
        for retailer_id, result in zip(retailer_ids, results):
            if isinstance(result, Exception):
                logger.error(f"Scraper for Retailer {retailer_id} failed: {result}")
            elif result is not None:
                logger.info(f"Found price {result} for Retailer {retailer_id}")
                await persist_price(supabase, retailer_id, result)
            else:
                logger.warning(f"No price found for Retailer {retailer_id}")

if __name__ == "__main__":
    asyncio.run(main())
