import os
from supabase import create_client
from dotenv import load_dotenv

load_dotenv()

url = os.environ.get("SUPABASE_URL")
key = os.environ.get("SUPABASE_KEY")
supabase = create_client(url, key)

try:
    print("Calling get_best_proxy_mx...")
    response = supabase.rpc("get_best_proxy_mx", {}).execute()
    print("Success!")
    print("Data:", response.data)
except Exception as e:
    print("RPC Failed!")
    print(e)
