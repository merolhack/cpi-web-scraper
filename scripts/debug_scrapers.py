import asyncio
import httpx
import json
from bs4 import BeautifulSoup

# Test Products
PRODUCTS = [
    {"ean_code": "7501295600126", "name": "Leche Santa Clara"},
    {"ean_code": "034587030013", "name": "Sal La Fina"},
    {"ean_code": "75002343", "name": "Aceite 1-2-3"}
]

async def debug_chedraui(ean):
    print(f"\n--- Debugging Chedraui for {ean} ---")
    url = f"https://www.chedraui.com.mx/api/catalog_system/pub/products/search?ft={ean}"
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json"
    }
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(url, headers=headers)
            print(f"Status: {response.status_code}")
            if response.status_code == 200:
                try:
                    data = response.json()
                    print(f"Response JSON (First 500 chars): {str(data)[:500]}")
                    if data and len(data) > 0:
                        item = data[0]
                        price = item['items'][0]['sellers'][0]['commertialOffer']['Price']
                        print(f"Extracted Price: {price}")
                    else:
                        print("Data is empty list []")
                except json.JSONDecodeError:
                    print("Failed to decode JSON")
                    print(f"Response Text: {response.text[:500]}")
    except Exception as e:
        print(f"Error: {e}")

async def debug_soriana(ean):
    print(f"\n--- Debugging Soriana for {ean} ---")
    url = "https://www.soriana.com/on/demandware.store/Sites-Soriana-Site/es_MX/Search-ShowAjax"
    params = {"q": ean, "lang": "es_MX"}
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        "Accept": "application/json, text/html"
    }
    try:
        async with httpx.AsyncClient(timeout=10) as client:
            response = await client.get(url, params=params, headers=headers)
            print(f"Status: {response.status_code}")
            if response.status_code == 200:
                print(f"Response Text (First 500 chars): {response.text[:500]}")
                try:
                    data = response.json()
                    if 'productSearch' in data:
                        print("JSON contains 'productSearch'")
                    else:
                        print("JSON missing 'productSearch'")
                except json.JSONDecodeError:
                    print("Response is not JSON, trying HTML parsing...")
                    soup = BeautifulSoup(response.text, 'html.parser')
                    price_element = soup.select_one(".price .sales .value")
                    if price_element:
                        price_text = price_element.get_text(strip=True).replace("$", "").replace(",", "")
                        print(f"Extracted Price: {price_text}")
                    else:
                        print("Could not find price element '.price .sales .value'")
    except Exception as e:
        print(f"Error: {e}")

async def main():
    for p in PRODUCTS:
        await debug_chedraui(p['ean_code'])
        await debug_soriana(p['ean_code'])

if __name__ == "__main__":
    asyncio.run(main())
