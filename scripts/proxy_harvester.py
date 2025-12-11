import asyncio
import os
import logging
import aiohttp
import geoip2.database
import httpx
from typing import List, Optional, Tuple
from datetime import datetime
from supabase import create_client, Client
from dotenv import load_dotenv

# Load environment variables
load_dotenv()

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Configuration
SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY")
GEOIP_DB_PATH = "GeoLite2-Country.mmdb"
GEOIP_DB_URL = "https://raw.githubusercontent.com/P3TERX/GeoLite.mmdb/download/GeoLite2-Country.mmdb"

# Americas country codes - US and Central America
AMERICAS_COUNTRY_CODES = ['MX', 'US', 'GT', 'SV', 'HN', 'CR', 'NI', 'PA', 'BZ']

PROXY_SOURCES = [
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt",
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.txt",
    "https://raw.githubusercontent.com/zloi-user/hideip.me/main/http.txt",
    "https://raw.githubusercontent.com/Anonym0usWork1220/Free-Proxy-List/master/proxy_list.txt",
    "https://raw.githubusercontent.com/officialputuid/KangProxy/KangProxy/http/http.txt",
    "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt",
    "https://raw.githubusercontent.com/mmpx12/proxy-list/master/http.txt",
    "https://raw.githubusercontent.com/sunny9577/proxy-scraper/master/proxies.txt"
]

def get_supabase_client() -> Optional[Client]:
    if not SUPABASE_URL or not SUPABASE_KEY:
        logger.error("Supabase credentials missing.")
        return None
    return create_client(SUPABASE_URL, SUPABASE_KEY)

async def download_geoip_db():
    if not os.path.exists(GEOIP_DB_PATH):
        logger.info("Downloading GeoLite2-Country.mmdb...")
        async with httpx.AsyncClient() as client:
            response = await client.get(GEOIP_DB_URL, follow_redirects=True)
            if response.status_code == 200:
                with open(GEOIP_DB_PATH, "wb") as f:
                    f.write(response.content)
                logger.info("Download complete.")
            else:
                logger.error(f"Failed to download GeoIP DB: {response.status_code}")

def is_americas_proxy(ip: str, reader: geoip2.database.Reader) -> tuple[bool, str]:
    """Check if IP is from Americas (US/Central America). Returns (is_valid, country_code)."""
    try:
        response = reader.country(ip)
        country_code = response.country.iso_code
        if country_code in AMERICAS_COUNTRY_CODES:
            return True, country_code
        return False, ''
    except Exception:
        return False, ''

async def fetch_proxies(client: httpx.AsyncClient, url: str) -> List[str]:
    try:
        response = await client.get(url)
        if response.status_code == 200:
            return [line.strip() for line in response.text.splitlines() if ":" in line]
    except Exception as e:
        logger.warning(f"Failed to fetch from {url}: {e}")
    return []

async def validate_proxy(session: aiohttp.ClientSession, proxy: str) -> Tuple[str, str, int]:
    """
    Validates proxy against httpbin.org.
    Returns (proxy, status, latency_ms)
    """
    proxy_url = f"http://{proxy}"
    start_time = datetime.now()
    try:
        async with session.get("http://httpbin.org/ip", proxy=proxy_url, timeout=5) as response:
            if response.status == 200:
                latency = int((datetime.now() - start_time).total_seconds() * 1000)
                return proxy, 'active', latency
    except Exception:
        pass
    return proxy, 'dead', 9999

async def main():
    supabase = get_supabase_client()
    if not supabase:
        return

    await download_geoip_db()
    
    try:
        reader = geoip2.database.Reader(GEOIP_DB_PATH)
    except FileNotFoundError:
        logger.error("GeoIP DB not found. Exiting.")
        return

    # 1. Harvest
    logger.info("Harvesting proxies...")
    raw_proxies = set()
    async with httpx.AsyncClient(timeout=10) as client:
        tasks = [fetch_proxies(client, source) for source in PROXY_SOURCES]
        results = await asyncio.gather(*tasks)
        for result in results:
            raw_proxies.update(result)
    
    logger.info(f"Found {len(raw_proxies)} raw proxies.")

    # 2. Filter Americas (US + Central America)
    americas_proxies = []  # List of (proxy_string, country_code)
    for p in raw_proxies:
        try:
            ip = p.split(":")[0]
            is_valid, country_code = is_americas_proxy(ip, reader)
            if is_valid:
                americas_proxies.append((p, country_code))
        except Exception:
            continue
            
    logger.info(f"Filtered {len(americas_proxies)} Americas proxies.")
    
    if not americas_proxies:
        logger.warning("No Americas proxies found.")
        return

    # 3. Validate
    logger.info("Validating Americas proxies...")
    valid_proxies = []
    
    # Create a mapping from proxy string to country code for lookup after validation
    proxy_country_map = {p: cc for p, cc in americas_proxies}
    
    async with aiohttp.ClientSession() as session:
        tasks = [validate_proxy(session, p) for p, _ in americas_proxies]
        results = await asyncio.gather(*tasks)
        
        for proxy, status, latency in results:
            if status == 'active':
                country_code = proxy_country_map.get(proxy, 'US')  # Default to US if not found
                valid_proxies.append({
                    "ip_address": proxy.split(":")[0],
                    "port": int(proxy.split(":")[1]),
                    "protocol": "http",
                    "country_code": country_code,
                    "status": "active",
                    "latency_ms": latency,
                    "fail_count": 0,
                    "last_checked": datetime.now().isoformat()
                })

    logger.info(f"Found {len(valid_proxies)} active Americas proxies.")

    # 4. Upsert to Supabase
    if valid_proxies:
        try:
            # Upsert in chunks if necessary, but for now all at once
            data = supabase.table("cpi_proxies").upsert(
                valid_proxies, 
                on_conflict="ip_address,port,protocol"
            ).execute()
            logger.info(f"Upserted {len(valid_proxies)} proxies to Supabase.")
        except Exception as e:
            logger.error(f"Failed to upsert proxies: {e}")

if __name__ == "__main__":
    asyncio.run(main())
