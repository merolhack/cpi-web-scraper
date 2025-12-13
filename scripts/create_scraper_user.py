import os
import asyncio
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()

SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY") # This should be the SERVICE_ROLE_KEY to bypass email confirmation if possible, or just standard key

if not SUPABASE_URL or not SUPABASE_KEY:
    print("Error: SUPABASE_URL and SUPABASE_KEY must be set in .env")
    exit(1)

async def create_scraper_user():
    supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)
    
    email = "webmaster@indicedeprecios.com"
    password = "ScraperStrongPassword123!" # We won't really login with this often, mostly need the UUID
    
    print(f"Attempting to create user: {email}")
    
    try:
        # Check if user already exists (by trying to sign in or just creating)
        # We'll try to sign up
        res = supabase.auth.sign_up({
            "email": email,
            "password": password,
            "options": {
                "data": {
                    "full_name": "Web Scraper",
                    "role": "bot"
                }
            }
        })
        
        if res.user:
            print(f"User created/retrieved successfully!")
            print(f"UUID: {res.user.id}")
            print(f"Email: {res.user.email}")
            
            # Upsert into cpi_volunteers is handled by handle_new_user trigger, 
            # but we might want to ensure 'Web Scraper' name is set.
            
        else:
            print("User creation returned no user object. Check logs.")
            
    except Exception as e:
        print(f"An error occurred: {e}")
        # If user exists, we might get an error. In that case, we can't easily get the UUID via Client API without login.
        # But we can try logging in.
        try:
            print("Attempting login to retrieve UUID...")
            res = supabase.auth.sign_in_with_password({
                "email": email,
                "password": password
            })
            if res.user:
                print(f"Login successful!")
                print(f"UUID: {res.user.id}")
        except Exception as login_error:
            print(f"Login failed too: {login_error}")

if __name__ == "__main__":
    asyncio.run(create_scraper_user())
