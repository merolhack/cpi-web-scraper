
import os
import asyncio
from dotenv import load_dotenv
from supabase import create_client

load_dotenv()

SUPABASE_URL = os.environ.get("SUPABASE_URL")
SUPABASE_KEY = os.environ.get("SUPABASE_KEY")

async def main():
    if not SUPABASE_URL or not SUPABASE_KEY:
        print("ERROR: Supabase credentials missing in environment.")
        return

    try:
        supabase = create_client(SUPABASE_URL, SUPABASE_KEY)
        response = supabase.table("cpi_establishments").select("*").execute()
        print(f"Found {len(response.data)} establishments:")
        for est in response.data:
            print(f"ID: {est['establishment_id']}, Name: '{est['establishment_name']}'")
            
    except Exception as e:
        print(f"Error fetching establishments: {e}")

if __name__ == "__main__":
    asyncio.run(main())
