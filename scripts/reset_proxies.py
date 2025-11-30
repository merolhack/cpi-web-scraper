import os
import logging
from supabase import create_client
from dotenv import load_dotenv

load_dotenv()
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

url = os.environ.get("SUPABASE_URL")
key = os.environ.get("SUPABASE_KEY")
supabase = create_client(url, key)

def reset_proxies():
    try:
        logger.info("Resetting all proxies to active state...")
        # Update all proxies: set fail_count=0, success_count=0, status='active'
        # We want to give them a fresh start.
        data = supabase.table("cpi_proxies").update({
            "fail_count": 0,
            "status": "active"
        }).neq("status", "unchecked").execute()
        
        logger.info(f"Reset complete. Response: {data}")
    except Exception as e:
        logger.error(f"Failed to reset proxies: {e}")

if __name__ == "__main__":
    reset_proxies()
