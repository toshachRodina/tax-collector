#!/usr/bin/env python3
"""
setup_gmail_auth.py
Tax Collector — One-time Gmail OAuth setup

Run this ONCE on your Windows dev machine to generate token.json.
Then copy token.json to the Ubuntu server.

Steps:
  1. Download credentials.json from Google Cloud Console:
       APIs & Services → Credentials → OAuth 2.0 Client IDs → Download JSON
     Save it to the same folder as this script.

  2. Run this script:
       python setup_gmail_auth.py

  3. A browser window opens — sign in with toshach@gmail.com and allow access.

  4. token.json is created in the current folder.

  5. Copy BOTH files to the Ubuntu server:
       scp credentials.json token.json howieds@192.168.0.250:~/tax-collector/config/

  Note: Never commit credentials.json or token.json to git.
"""

from pathlib import Path
from google_auth_oauthlib.flow import InstalledAppFlow

SCOPES = ["https://www.googleapis.com/auth/gmail.readonly"]

CREDENTIALS_FILE = Path(__file__).parent / "credentials.json"
TOKEN_FILE       = Path(__file__).parent / "token.json"


def main():
    if not CREDENTIALS_FILE.exists():
        print(f"ERROR: credentials.json not found at {CREDENTIALS_FILE}")
        print(
            "\nDownload it from Google Cloud Console:\n"
            "  APIs & Services → Credentials → OAuth 2.0 Client IDs "
            "→ click the download icon → save as credentials.json in this folder."
        )
        raise SystemExit(1)

    print("Opening browser for Google authorisation...")
    flow  = InstalledAppFlow.from_client_secrets_file(str(CREDENTIALS_FILE), SCOPES)
    creds = flow.run_local_server(port=0)

    TOKEN_FILE.write_text(creds.to_json())
    print(f"\n✓ token.json saved to: {TOKEN_FILE}")
    print(
        "\nNext step — copy both files to the Ubuntu server:\n"
        f"  scp {CREDENTIALS_FILE} {TOKEN_FILE} "
        "howieds@192.168.0.250:~/tax-collector/config/"
    )


if __name__ == "__main__":
    main()
