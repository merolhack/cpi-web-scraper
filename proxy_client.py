import logging
import os
from typing import Optional, Dict, Any
from supabase import create_client, Client
from dotenv import load_dotenv

load_dotenv()
logger = logging.getLogger(__name__)

class ProxyRotator:
    def __init__(self):
        self.supabase_url = os.environ.get("SUPABASE_URL")
        self.supabase_key = os.environ.get("SUPABASE_KEY")
        self.client: Optional[Client] = None
        
        if self.supabase_url and self.supabase_key:
            self.client = create_client(self.supabase_url, self.supabase_key)
        else:
            logger.error("Supabase credentials missing for ProxyRotator.")

    def get_proxy(self) -> Optional[Dict[str, Any]]:
        """
        Fetches the best available MX proxy from Supabase.
        Returns dict with 'proxy_id', 'ip_address', 'port', 'protocol', 'url'.
        """
        if not self.client:
            return None

        try:
            response = self.client.rpc("get_best_proxy_mx", {}).execute()
            if response.data:
                proxy_data = response.data
                # Construct URL
                protocol = proxy_data.get('protocol', 'http')
                ip = proxy_data.get('ip_address')
                port = proxy_data.get('port')
                proxy_data['url'] = f"{protocol}://{ip}:{port}"
                return proxy_data
            else:
                logger.warning("No active MX proxies available in DB.")
                return None
        except Exception as e:
            logger.error(f"Failed to get proxy from DB: {e}")
            return None

    def report_failure(self, proxy_id: int):
        """Increments fail_count. If > 5, marks as dead."""
        if not self.client or not proxy_id:
            return

        try:
            # We can do this via a direct update or another RPC. 
            # Direct update for simplicity.
            # First get current fail count? Or just increment.
            # Let's just increment and check logic in DB or here.
            # Ideally an RPC 'report_proxy_failure' would be atomic.
            # For now, simple read-modify-write or just blind update.
            
            # Fetch current
            res = self.client.table("cpi_proxies").select("fail_count").eq("proxy_id", proxy_id).execute()
            if res.data:
                current_fail = res.data[0]['fail_count'] or 0
                new_fail = current_fail + 1
                status = 'dead' if new_fail > 5 else 'active'
                
                self.client.table("cpi_proxies").update({
                    "fail_count": new_fail,
                    "status": status
                }).eq("proxy_id", proxy_id).execute()
                
        except Exception as e:
            logger.error(f"Failed to report failure for proxy {proxy_id}: {e}")

    def report_success(self, proxy_id: int):
        """Resets fail_count and increments success_count."""
        if not self.client or not proxy_id:
            return

        try:
            # Atomic increment for success_count would be better, but...
            res = self.client.table("cpi_proxies").select("success_count").eq("proxy_id", proxy_id).execute()
            if res.data:
                current_success = res.data[0]['success_count'] or 0
                
                self.client.table("cpi_proxies").update({
                    "fail_count": 0,
                    "success_count": current_success + 1,
                    "status": "active" # Ensure it stays active
                }).eq("proxy_id", proxy_id).execute()
                
        except Exception as e:
            logger.error(f"Failed to report success for proxy {proxy_id}: {e}")
