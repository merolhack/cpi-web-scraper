import asyncio
import logging
from proxy_client import ProxyRotator
from playwright.async_api import async_playwright
import httpx

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

async def main():
    rotator = ProxyRotator()
    
    # 1. Get a proxy
    logger.info("Requesting best MX proxy...")
    proxy = rotator.get_proxy()
    
    if not proxy:
        logger.error("No proxy retrieved. Run harvester first!")
        return

    logger.info(f"Got proxy: {proxy['url']} (ID: {proxy['proxy_id']})")

    # 2. Example with HTTPX
    logger.info("Testing with HTTPX...")
    try:
        async with httpx.AsyncClient(proxies=proxy['url'], timeout=10) as client:
            resp = await client.get("http://httpbin.org/ip")
            logger.info(f"HTTPX Result: {resp.status_code} - {resp.json()}")
            rotator.report_success(proxy['proxy_id'])
    except Exception as e:
        logger.error(f"HTTPX Failed: {e}")
        rotator.report_failure(proxy['proxy_id'])

    # 3. Example with Playwright
    logger.info("Testing with Playwright...")
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True, proxy={"server": proxy['url']})
        try:
            page = await browser.new_page()
            await page.goto("http://httpbin.org/ip", timeout=10000)
            content = await page.content()
            logger.info(f"Playwright Result: {content[:100]}...")
            rotator.report_success(proxy['proxy_id'])
        except Exception as e:
            logger.error(f"Playwright Failed: {e}")
            rotator.report_failure(proxy['proxy_id'])
        finally:
            await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
