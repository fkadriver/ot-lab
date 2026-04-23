#!/usr/bin/env python3
"""
Armis PCAP Uploader
Continuously monitors a directory for PCAP files and uploads them to Armis cloud API.

Usage:
    ARMIS_API_KEY=xxx python armis-upload.py

Environment Variables:
    ARMIS_API_KEY       (required) - Your Armis API token
    ARMIS_HOSTNAME      (default: lab-kudelski.armis.com) - Your Armis tenant hostname
    ARMIS_TENANT_ID     (optional) - Your tenant ID for additional context
    UPLOAD_INTERVAL     (default: 30) - Seconds between directory scans
"""

import os
import sys
import glob
import time
import logging
import requests
import json
from pathlib import Path
from datetime import datetime
from typing import Optional

# ============================================================================
# Configuration
# ============================================================================

ARMIS_API_KEY = os.getenv("ARMIS_API_KEY", "").strip()
ARMIS_HOSTNAME = os.getenv("ARMIS_HOSTNAME", "lab-kudelski.armis.com").strip()
ARMIS_TENANT_ID = os.getenv("ARMIS_TENANT_ID", "").strip()
PCAP_DIR = "/pcap"
UPLOAD_INTERVAL = int(os.getenv("UPLOAD_INTERVAL", 30))
MAX_RETRIES = 3
RETRY_DELAY = 5

# ============================================================================
# Logging Setup
# ============================================================================

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler('/tmp/armis-uploader.log')
    ]
)
logger = logging.getLogger(__name__)

# ============================================================================
# Validation
# ============================================================================

def validate_config() -> bool:
    """Validate required configuration"""
    if not ARMIS_API_KEY:
        logger.error("ARMIS_API_KEY environment variable not set")
        return False
    
    if not ARMIS_HOSTNAME:
        logger.error("ARMIS_HOSTNAME is empty")
        return False
    
    if ARMIS_HOSTNAME not in ["lab-kudelski.armis.com", "api.armis.com", "eu.armis.com"] and not "." in ARMIS_HOSTNAME:
        logger.warning(f"Unusual ARMIS_HOSTNAME: {ARMIS_HOSTNAME}")
    
    if not os.path.isdir(PCAP_DIR):
        logger.error(f"PCAP directory does not exist: {PCAP_DIR}")
        return False
    
    logger.info(f"Configuration: hostname={ARMIS_HOSTNAME}, key={'***' + ARMIS_API_KEY[-4:]}, interval={UPLOAD_INTERVAL}s")
    return True

# ============================================================================
# Armis API Client
# ============================================================================

class ArmisUploader:
    """Client for uploading PCAP files to Armis"""

    def __init__(self, api_key: str, hostname: str, tenant_id: Optional[str] = None):
        self.secret_key = api_key
        self.base_url = f"https://{hostname}/api/v1"
        self.tenant_id = tenant_id
        self.session = requests.Session()
        self._access_token: Optional[str] = None
        self._token_expiry: float = 0.0
        self._authenticate()

    def _authenticate(self) -> bool:
        """Exchange secret key for a short-lived access token."""
        try:
            resp = self.session.post(
                f"{self.base_url}/access_token/",
                headers={"Content-Type": "application/x-www-form-urlencoded"},
                data={"secret_key": self.secret_key},
                timeout=15,
            )
            if resp.status_code == 200:
                data = resp.json().get("data", {})
                self._access_token = data["access_token"]
                # Refresh 60 s before the stated expiry
                from datetime import datetime
                expiry_str = data.get("expiration_utc", "")
                if expiry_str:
                    exp = datetime.fromisoformat(expiry_str)
                    self._token_expiry = exp.timestamp() - 60
                else:
                    self._token_expiry = time.time() + 840  # 14 min fallback
                # Raw token, no prefix
                self.session.headers.update({"Authorization": self._access_token})
                logger.info("✓ Armis access token obtained")
                return True
            logger.error(f"✗ Token exchange failed ({resp.status_code}): {resp.text[:200]}")
            return False
        except Exception as e:
            logger.error(f"✗ Token exchange error: {e}")
            return False

    def _ensure_token(self):
        """Re-authenticate if token is missing or about to expire."""
        if not self._access_token or time.time() >= self._token_expiry:
            self._authenticate()
    
    def upload_pcap(self, filepath: str) -> bool:
        """
        Upload a single PCAP file to Armis
        
        Args:
            filepath: Full path to PCAP file
            
        Returns:
            True if upload successful, False otherwise
        """
        
        if not os.path.exists(filepath):
            logger.warning(f"File not found: {filepath}")
            return False
        
        file_size = os.path.getsize(filepath)
        
        # Skip empty files
        if file_size == 0:
            logger.debug(f"Skipping empty file: {filepath}")
            return False
        
        # Warn if file is very large (>500MB)
        if file_size > 500 * 1024 * 1024:
            logger.warning(f"PCAP file is large ({file_size / (1024*1024):.1f}MB): {filepath}")
        
        logger.info(f"Uploading {Path(filepath).name} ({file_size / (1024*1024):.1f}MB)...")

        url = f"{self.base_url}/uploads/pcap/"
        params = {}
        if self.tenant_id:
            params['tenantId'] = self.tenant_id

        # Attempt upload with retries
        for attempt in range(1, MAX_RETRIES + 1):
            try:
                self._ensure_token()
                with open(filepath, 'rb') as f:
                    files = {'file': (Path(filepath).name, f, 'application/octet-stream')}
                    response = self.session.post(
                        url,
                        files=files,
                        params=params,
                        timeout=120,
                    )

                if response.status_code in (200, 201):
                    logger.info(f"✓ Successfully uploaded {Path(filepath).name}")
                    try:
                        result = response.json()
                        if 'uploadId' in result:
                            logger.debug(f"  Upload ID: {result['uploadId']}")
                    except:
                        pass
                    return True

                elif response.status_code == 401:
                    logger.warning(f"✗ Got 401 — refreshing token and retrying...")
                    self._access_token = None  # force re-auth on next attempt
                    if attempt < MAX_RETRIES:
                        time.sleep(RETRY_DELAY)
                        continue
                    return False
                
                elif response.status_code == 403:
                    logger.error(f"✗ Forbidden (403). Check permissions for tenant {self.tenant_id}.")
                    return False
                
                elif response.status_code == 429:
                    logger.warning(f"✗ Rate limited (429). Waiting {RETRY_DELAY}s before retry...")
                    time.sleep(RETRY_DELAY)
                    continue
                
                else:
                    logger.warning(f"✗ Upload failed ({response.status_code}): {response.text[:200]}")
                    
                    if attempt < MAX_RETRIES:
                        logger.info(f"  Retrying in {RETRY_DELAY}s ({attempt}/{MAX_RETRIES})...")
                        time.sleep(RETRY_DELAY)
                        continue
                    return False
            
            except requests.exceptions.Timeout:
                logger.warning(f"✗ Upload timeout (attempt {attempt}/{MAX_RETRIES})")
                if attempt < MAX_RETRIES:
                    time.sleep(RETRY_DELAY)
                    continue
                return False
            
            except requests.exceptions.ConnectionError as e:
                logger.warning(f"✗ Connection error: {e}")
                if attempt < MAX_RETRIES:
                    logger.info(f"  Retrying in {RETRY_DELAY}s ({attempt}/{MAX_RETRIES})...")
                    time.sleep(RETRY_DELAY)
                    continue
                return False
            
            except Exception as e:
                logger.error(f"✗ Unexpected error during upload: {e}")
                return False
        
        return False
    
    def test_connection(self) -> bool:
        """Test connectivity to Armis API"""
        logger.info("Testing connection to Armis API...")
        return self._access_token is not None

# ============================================================================
# File Monitoring & Upload
# ============================================================================

def monitor_and_upload(uploader: ArmisUploader):
    """Monitor PCAP directory and upload new files"""
    
    processed_files = set()
    consecutive_failures = 0
    max_consecutive_failures = 5
    
    logger.info(f"Monitoring {PCAP_DIR} for PCAP files every {UPLOAD_INTERVAL}s...")
    
    while True:
        try:
            # Find all PCAP files
            pcap_files = sorted(glob.glob(f"{PCAP_DIR}/*.pcap*"))
            
            for pcap_file in pcap_files:
                # Skip already processed files
                if pcap_file in processed_files:
                    continue
                
                # Skip if file is still being written to (mtime < 2 seconds ago)
                mtime = os.path.getmtime(pcap_file)
                age = time.time() - mtime
                if age < 2:
                    logger.debug(f"Skipping active file (too recent): {Path(pcap_file).name}")
                    continue
                
                # Try to upload
                if uploader.upload_pcap(pcap_file):
                    processed_files.add(pcap_file)
                    consecutive_failures = 0
                    
                    # Delete after successful upload (optional)
                    # Uncomment to save disk space
                    # try:
                    #     os.remove(pcap_file)
                    #     logger.debug(f"Deleted {Path(pcap_file).name} after upload")
                    # except Exception as e:
                    #     logger.warning(f"Could not delete {Path(pcap_file).name}: {e}")
                else:
                    consecutive_failures += 1
                    if consecutive_failures >= max_consecutive_failures:
                        logger.warning(f"{consecutive_failures} consecutive failures. Pausing uploads...")
                        time.sleep(60)
                        consecutive_failures = 0
            
            # Report stats
            if pcap_files:
                pending = len(pcap_files) - len(processed_files)
                if pending > 0:
                    pending_size = sum(os.path.getsize(f) for f in pcap_files if f not in processed_files) / (1024*1024)
                    logger.debug(f"Status: {pending} files pending ({pending_size:.1f}MB)")
            
            time.sleep(UPLOAD_INTERVAL)
        
        except KeyboardInterrupt:
            logger.info("Shutting down...")
            break
        
        except Exception as e:
            logger.error(f"Unexpected error in monitor loop: {e}", exc_info=True)
            time.sleep(UPLOAD_INTERVAL)

# ============================================================================
# Main
# ============================================================================

def main():
    """Main entry point"""
    
    if not validate_config():
        sys.exit(1)
    
    # Create uploader
    uploader = ArmisUploader(ARMIS_API_KEY, ARMIS_HOSTNAME, ARMIS_TENANT_ID)
    
    # Test connection
    if not uploader.test_connection():
        logger.warning("Could not verify connection to Armis. Attempting to continue...")
    
    # Start monitoring
    try:
        monitor_and_upload(uploader)
    except KeyboardInterrupt:
        logger.info("Interrupted")
        sys.exit(0)
    except Exception as e:
        logger.error(f"Fatal error: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
