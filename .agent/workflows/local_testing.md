---
description: How to test the hybrid scraper locally on Windows
---

# Local Testing Guide

Follow these steps to run the scraper on your local machine.

## 1. Prerequisites
Ensure you have Python 3.10+ installed.

## 2. Setup Environment
Open a PowerShell terminal in the project directory: `c:\Users\lenin\Documents\Freelances\Inflacion\Development\cpi-web-scraper`

### Install Dependencies
```powershell
pip install -r requirements.txt
```

### Install Playwright Browsers
```powershell
playwright install chromium
```

## 3. Configure Secrets
You need to set the Supabase credentials as environment variables for the current session.
Replace `your_url` and `your_key` with your actual Supabase project details.

```powershell
$env:SUPABASE_URL="your_supabase_url"
$env:SUPABASE_KEY="your_supabase_service_role_key"
```

## 4. Run the Scraper
Execute the main script.

```powershell
python main.py
```

## 5. Verify Results
- Check the terminal output for logs like `[INFO] Successfully persisted price...`.
- Check your Supabase database table `cpi_prices` to see if new rows were added.
