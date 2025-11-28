---
description: Automates testing, versioning, changelog updates, and deployment to GitHub.
---

# Test and Deploy Workflow

Follow these steps to test, document, and deploy the application.

## 1. Stage Changes
Stage all modified files.
```powershell
git add .
```

## 2. Run Local Tests
Execute the scraper locally to ensure it runs without errors.
```powershell
python main.py
```
*If this fails, STOP and fix the errors.*

## 3. Update Version and Changelog
1.  Read the current version from `VERSION` (create it with `0.1.0` if missing).
2.  Increment the patch version (e.g., `0.1.0` -> `0.1.1`).
3.  Update `VERSION` file.
4.  Append a new entry to `CHANGELOG.txt` with the new version and a summary of changes (you can use `git diff --name-only --cached` to see what changed).
    *   Format: `[Version] - YYYY-MM-DD` followed by changes.

## 4. Commit Changes
Commit with a standard message including the new version.
```powershell
git commit -m ":sparkles: feat: Release version <NEW_VERSION> - Product price monitoring updates"
```

## 5. Push to GitHub
```powershell
git push origin main
```

## 6. Trigger and Verify GitHub Action
1.  Trigger the workflow (if not triggered by push).
    ```powershell
    gh workflow run scraper.yml
    ```
2.  Check the status.
    ```powershell
    gh run list --limit 1
    ```
