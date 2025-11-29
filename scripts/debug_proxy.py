import asyncio
from playwright.async_api import async_playwright

PROXY = "http://103.152.112.162:80" # Example proxy, replace if needed

async def main():
    async with async_playwright() as p:
        print(f"Launching browser with proxy: {PROXY}")
        browser = await p.chromium.launch(headless=True)
        
        try:
            context = await browser.new_context(proxy={"server": PROXY})
            page = await context.new_page()
            print("Context created. Navigating...")
            
            try:
                await page.goto("http://example.com", timeout=10000)
                print("Navigation successful!")
                print(await page.title())
            except Exception as e:
                print(f"Navigation failed: {e}")
                
        except Exception as e:
            print(f"Context creation failed: {e}")
        finally:
            await browser.close()

if __name__ == "__main__":
    asyncio.run(main())
