import asyncio
import httpx
from bs4 import BeautifulSoup

# Test Products
PRODUCTS = [
    {"ean_code": "7501295600126", "name": "Leche Santa Clara"},
]

async def debug_lacomer():
    print(f"\n--- Debugging La Comer ---")
    url = "https://www.lacomer.com.mx/lacomer-api/api/v1/public/articulopasillo/detalleArticulo"
    params = {
        "artEan": "7501295600126",
        "noPagina": "1",
        "succId": "287"
    }
    # Improved Headers
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
    
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(url, params=params, headers=headers)
            print(f"Status: {response.status_code}")
            print(f"Response: {response.text[:200]}")
    except Exception as e:
        print(f"Error: {e}")

async def debug_soriana_search():
    print(f"\n--- Debugging Soriana Search ---")
    url = "https://www.soriana.com/on/demandware.store/Sites-Soriana-Site/es_MX/Search-ShowAjax"
    # Searching by name as EAN often fails
    params = {"q": "Leche Santa Clara", "lang": "es_MX"}
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "text/html, */*; q=0.01"
    }
    
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(url, params=params, headers=headers)
            print(f"Status: {response.status_code}")
            if response.status_code == 200:
                soup = BeautifulSoup(response.text, 'html.parser')
                
                # Check for product tiles
                tiles = soup.select(".product-tile")
                print(f"Found {len(tiles)} product tiles")
                
                if tiles:
                    first_tile = tiles[0]
                    # Try to find price in the tile
                    price_element = first_tile.select_one(".price .sales .value")
                    if price_element:
                        print(f"Price found in tile: {price_element.get_text(strip=True)}")
                    else:
                        print("Price element not found in tile. Dumping tile HTML:")
                        print(str(first_tile)[:500])
                else:
                    print("No product tiles found. Dumping response start:")
                    print(response.text[:500])

    except Exception as e:
        print(f"Error: {e}")

async def main():
    await debug_lacomer()
    await debug_soriana_search()

if __name__ == "__main__":
    asyncio.run(main())
