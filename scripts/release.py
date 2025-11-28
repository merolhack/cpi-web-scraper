import os
import datetime
import re

def main():
    # 1. Read Version
    try:
        with open('VERSION', 'r') as f:
            version = f.read().strip()
    except FileNotFoundError:
        version = "0.1.0"
    
    parts = list(map(int, version.split('.')))
    parts[2] += 1 # Increment patch
    new_version = ".".join(map(str, parts))
    
    # 2. Update Version File
    with open('VERSION', 'w') as f:
        f.write(new_version)
        
    # 3. Update Changelog
    today = datetime.date.today().strftime("%Y-%m-%d")
    header = f"## [{new_version}] - {today}"
    
    # Generate commit message/changelog content
    new_entry = f"\n{header}\n- Automated release updates.\n- Unit tests added.\n"
    
    try:
        with open('CHANGELOG.txt', 'r') as f:
            content = f.read()
    except FileNotFoundError:
        content = "# Changelog\n"
        
    # Insert after the first line (assuming # Changelog is first)
    lines = content.splitlines()
    if lines and lines[0].startswith("# Changelog"):
        lines.insert(2, new_entry.strip()) 
    else:
        lines.insert(0, "# Changelog\n\n" + new_entry.strip())
        
    with open('CHANGELOG.txt', 'w') as f:
        f.write("\n".join(lines))
        
    print(f":sparkles: feat: Release version {new_version} - Unit tests and deployment")

if __name__ == "__main__":
    main()
