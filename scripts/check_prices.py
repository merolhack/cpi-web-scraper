import os
import logging
from datetime import datetime
from dotenv import load_dotenv
from supabase import create_client, Client

# Load environment variables
load_dotenv()

# Configure Logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def get_supabase_client() -> Client:
    url = os.environ.get("SUPABASE_URL")
    key = os.environ.get("SUPABASE_KEY")
    if not url or not key:
        raise ValueError("Supabase credentials missing in .env file.")
    return create_client(url, key)

def check_latest_prices():
    try:
        client = get_supabase_client()
        logger.info("Connected to Supabase.")

        # Query the cpi_prices table
        # Order by date descending to see the latest entries
        response = client.table("cpi_prices").select("*").order("date", desc=True).limit(10).execute()
        
        prices = response.data
        
        if not prices:
            logger.info("No prices found in the database.")
            return

        logger.info(f"Found {len(prices)} recent price entries:")
        for price in prices:
            print(f"ID: {price.get('price_id')} | Date: {price.get('date')} | Value: {price.get('price_value')} | Product ID: {price.get('product_id')} | Establishment ID: {price.get('establishment_id')}")

    except Exception as e:
        logger.error(f"Failed to fetch prices: {e}")

if __name__ == "__main__":
    check_latest_prices()
