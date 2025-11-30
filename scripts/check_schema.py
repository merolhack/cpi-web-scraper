import os
from supabase import create_client
from dotenv import load_dotenv

load_dotenv()

url = os.environ.get("SUPABASE_URL")
key = os.environ.get("SUPABASE_KEY")
supabase = create_client(url, key)

try:
    # Query information_schema to get column names for cpi_proxies
    # Supabase-py doesn't support direct SQL easily without RPC, but we can try to select * limit 1 and check keys
    response = supabase.table("cpi_proxies").select("*").limit(1).execute()
    if response.data:
        print("Columns found:", response.data[0].keys())
    else:
        print("Table is empty, cannot infer columns from data.")
        # Try to insert a dummy to see what happens? No, that's risky.
        # Let's assume if data is empty we can't see columns easily via simple select.
        pass
except Exception as e:
    print(f"Error: {e}")
