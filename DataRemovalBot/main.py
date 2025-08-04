import smtplib
import ssl
import json
import time
import sys
import re
import logging
import argparse
import os
import base64
from getpass import getpass
from email.message import EmailMessage
from dataclasses import dataclass, field, asdict
from typing import Dict, Any, List, Tuple, Set

from selenium import webdriver
from selenium.webdriver.common.by import By
from selenium.webdriver.chrome.service import Service as ChromeService
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC
from selenium.common.exceptions import TimeoutException, WebDriverException

@dataclass
class SmtpConfig:
    email: str = ""
    password: str = ""
    server: str = ""
    port: int = 587

@dataclass
class UserConfig:
    full_name: str = ""
    primary_country: str = "" # e.g., "SE"
    smtp: SmtpConfig = field(default_factory=SmtpConfig)

class Colors:
    HEADER = '\033[95m'
    BLUE = '\033[94m'
    CYAN = '\033[96m'
    GREEN = '\033[92m'
    WARNING = '\033[93m'
    FAIL = '\033[91m'
    ENDC = '\033[0m'
    BOLD = '\033[1m'

class SafeDict(dict):
    def __missing__(self, key):
        return ''

class DataRemovalBot:
    def __init__(self, targets_file: str, countries_file: str, args: argparse.Namespace):
        self.args = args
        self.config_path = "config.json"
        self.config = self._load_config()
        self.all_targets = self._load_json(targets_file)
        self.country_configs = self._load_json(countries_file)
        self.targets = self._filter_targets()
        self.user_info: Dict[str, Any] = {"identifiers": {}}
        self.smtp_config_obj: SmtpConfig = self.config.smtp
        self.chrome_service: ChromeService = None
        
        self.handlers = {
            "email": self._handle_email,
            "webform": self._handle_webform,
            "manual_eid": self._handle_manual_eid,
            "mrkoll_flow": self._handle_mrkoll,
            "ratsit_flow": self._handle_ratsit
        }

    def _obfuscate(self, data: str) -> str:
        return base64.b64encode(data.encode('utf-8')).decode('utf-8')

    def _deobfuscate(self, data: str) -> str:
        return base64.b64decode(data.encode('utf-8')).decode('utf-8')

    def _load_config(self) -> UserConfig:
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r') as f:
                    data = json.load(f)
                    if data.get("smtp", {}).get("password"):
                        data["smtp"]["password"] = self._deobfuscate(data["smtp"]["password"])
                    return UserConfig(**data)
            except (json.JSONDecodeError, TypeError):
                print(f"{Colors.WARNING}Warning: Could not read config.json. Starting fresh.{Colors.ENDC}")
        return UserConfig()

    def _save_config(self):
        config_to_save = asdict(self.config)
        if config_to_save.get("smtp", {}).get("password"):
             config_to_save["smtp"]["password"] = self._obfuscate(config_to_save["smtp"]["password"])
        
        with open(self.config_path, 'w') as f:
            json.dump(config_to_save, f, indent=2)
        print(f"{Colors.GREEN}Settings saved to {self.config_path}{Colors.ENDC}")

    def _filter_targets(self) -> List[Dict]:
        filtered = self.all_targets
        
        if self.args.country:
            filtered = [t for t in filtered if t.get('country', '').lower() == self.args.country.lower()]
            print(f"{Colors.CYAN}Filtering for country specified via flag: {self.args.country.upper()}{Colors.ENDC}")
        elif self.config.primary_country:
            filtered = [t for t in filtered if t.get('country', '').lower() == self.config.primary_country.lower()]
            print(f"{Colors.CYAN}Using primary country from settings: {self.config.primary_country.upper()}{Colors.ENDC}")
            print(f"{Colors.CYAN}To process other countries, use the --country flag or clear settings with --clear-config.{Colors.ENDC}")

        if self.args.type:
            filtered = [t for t in filtered if t.get('type', '').lower() == self.args.type.lower()]
        if self.args.target_name:
            filtered = [t for t in filtered if self.args.target_name.lower() in t.get('name', '').lower()]
        
        if not filtered:
            print(f"{Colors.FAIL}No targets match your filter criteria. Exiting.{Colors.ENDC}")
            sys.exit(0)
        return filtered
    
    def _load_json(self, file_path: str) -> Dict | List:
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                return json.load(f)
        except FileNotFoundError:
            print(f"{Colors.FAIL}Error: The file '{file_path}' was not found.{Colors.ENDC}"); sys.exit(1)
        except json.JSONDecodeError:
            print(f"{Colors.FAIL}Error: The file '{file_path}' contains invalid JSON.{Colors.ENDC}"); sys.exit(1)
    
    def _interactive_country_selection(self):
        available_countries = sorted(list({t['country'] for t in self.targets if 'country' in t}))
        if len(available_countries) <= 1: return

        print(f"\n{Colors.HEADER}--- Step 1: Select Countries to Process ---{Colors.ENDC}")
        country_map = {str(i + 1): code for i, code in enumerate(available_countries)}
        for number, code in country_map.items():
            print(f"  [{number}] {self.country_configs.get(code, {}).get('name', code)} ({code})")

        while True:
            choice = input(f"{Colors.CYAN}Enter numbers for countries (e.g., 1,3 or all): {Colors.ENDC}").lower().strip()
            selected_codes = set()
            if choice == 'all':
                selected_codes.update(available_countries); break
            parts = [p.strip() for p in choice.split(',')]
            valid_choice = True
            for part in parts:
                if part in country_map: selected_codes.add(country_map[part])
                else: print(f"{Colors.FAIL}[!] Invalid selection: '{part}'.{Colors.ENDC}"); valid_choice = False; break
            if valid_choice and selected_codes: break
            elif valid_choice: print(f"{Colors.FAIL}[!] Please make a selection.{Colors.ENDC}")
        
        self.targets = [t for t in self.targets if t.get('country') in selected_codes]
        if len(selected_codes) == 1 and not self.config.primary_country:
            chosen_code = list(selected_codes)[0]
            if input(f"Set {self.country_configs[chosen_code]['name']} as primary country? (Y/n): ").lower().strip() != 'n':
                self.config.primary_country = chosen_code

    def _get_user_info(self):
        print(f"\n{Colors.HEADER}--- Step 2: Provide Your Personal Information ---{Colors.ENDC}")
        prompt = f"Enter your full name" + (f" [{self.config.full_name}]" if self.config.full_name else "")
        self.config.full_name = input(f"{prompt}: ") or self.config.full_name
        self.user_info['full_name'] = self.config.full_name

        countries_in_targets: Set[str] = {t.get('country', '').upper() for t in self.targets if t.get('country')}
        if not countries_in_targets: return

        for country_code in sorted(list(countries_in_targets)):
            config = self.country_configs.get(country_code)
            if not config: continue
            
            print(f"\n{Colors.CYAN}--- Collecting information for {config['name']} ({country_code}) ---{Colors.ENDC}")
            self.user_info["identifiers"][country_code] = {}
            for id_key, id_config in config.get("identifiers", {}).items():
                while True:
                    value = input(f"{Colors.CYAN}{id_config['prompt']}{Colors.ENDC}")
                    if not value and id_config.get("optional"): break
                    if id_config.get("validation_regex") and not re.match(id_config["validation_regex"], value):
                        print(f"{Colors.FAIL}[!] Invalid format. Try again.{Colors.ENDC}"); continue
                    self.user_info["identifiers"][country_code][id_key] = value; break

    def _get_smtp_config(self):
        print(f"\n{Colors.HEADER}--- Step 3: Configure Email Settings ---{Colors.ENDC}")
        if self.smtp_config_obj.email and self.smtp_config_obj.password:
            if input(f"Use saved SMTP settings for {self.smtp_config_obj.email}? (Y/n): ").lower().strip() != 'n':
                self.user_info['email'] = self.smtp_config_obj.email; return
        
        email = input("Your email address: "); password = getpass("Your email App Password: ")
        SMTP_PROVIDERS = {"gmail.com": ("smtp.gmail.com", 465), "outlook.com": ("smtp.office365.com", 587)}
        domain = email.split('@')[-1]; default_server, default_port = SMTP_PROVIDERS.get(domain, ("", 587))
        server = input(f"SMTP server [{default_server}]: ") or default_server
        port_str = input(f"SMTP port [{default_port}]: ") or str(default_port)
        self.smtp_config_obj = SmtpConfig(email=email, password=password, server=server, port=int(port_str))
        self.config.smtp = self.smtp_config_obj; self.user_info['email'] = email
        
    def _initialize_driver_service(self):
        print(f"\n{Colors.CYAN}[*] Checking for web browser driver...{Colors.ENDC}")
        try:
            logging.getLogger('selenium.webdriver.remote.remote_connection').setLevel(logging.WARNING)
            self.chrome_service = ChromeService()
            print(f"{Colors.GREEN}[+] Driver is ready.{Colors.ENDC}")
        except WebDriverException as e:
            print(f"{Colors.FAIL}[!] Could not initialize Chrome driver: {e}{Colors.ENDC}")

    def _get_email_content(self, template_name: str, country_code: str) -> Tuple[str, str]:
        template_file = f"templates/{template_name}.txt"
        try:
            with open(template_file, 'r', encoding='utf-8') as f: content = f.read().strip()
            subject, body = content.split('\n', 1)
            format_dict = SafeDict({"full_name": self.user_info.get('full_name'), "email": self.user_info.get('email')})
            if country_code: format_dict.update(self.user_info["identifiers"].get(country_code, {}))
            return subject.replace("Subject: ", "").strip(), body.strip().format_map(format_dict)
        except Exception as e:
            print(f"{Colors.FAIL}[!] Error processing template {template_file}: {e}{Colors.ENDC}"); return None, None

    def _send_email_with_config(self, msg: EmailMessage):
        try:
            context = ssl.create_default_context()
            if (port := self.smtp_config_obj.port) == 465:
                with smtplib.SMTP_SSL(self.smtp_config_obj.server, port, context=context) as server:
                    server.login(self.smtp_config_obj.email, self.smtp_config_obj.password); server.send_message(msg)
            else:
                with smtplib.SMTP(self.smtp_config_obj.server, port) as server:
                    server.starttls(context=context); server.login(self.smtp_config_obj.email, self.smtp_config_obj.password); server.send_message(msg)
            print(f"{Colors.GREEN}[+] Email successfully sent to {msg['To']}!{Colors.ENDC}")
        except smtplib.SMTPAuthenticationError:
            print(f"{Colors.FAIL}[!] Authentication failed. Check email/password.{Colors.ENDC}")
        except Exception as e:
            print(f"{Colors.FAIL}[!] Error sending to {msg['To']}: {e}{Colors.ENDC}")

    def _handle_email(self, target: Dict[str, Any]):
        recipient, template = target['contact'], target.get('template')
        country_code = target.get('country', '').upper()
        print(f"{Colors.BLUE}[*] Preparing email for {target['name']} ({recipient})...{Colors.ENDC}")
        subject, body = self._get_email_content(template, country_code)
        if not body: return
        msg = EmailMessage(); msg.set_content(body); msg['Subject'] = subject
        msg['From'] = self.smtp_config_obj.email; msg['To'] = recipient
        self._send_email_with_config(msg)

    def _handle_webform(self, target: Dict[str, Any]):
        if not self.chrome_service: return
        print(f"\n{Colors.BLUE}[*] Processing web form for {target['name']}...{Colors.ENDC}")
        input("Press Enter to open browser..."); driver = None
        try:
            driver = webdriver.Chrome(service=self.chrome_service)
            driver.get(target['url']); wait = WebDriverWait(driver, 15)
            try:
                xpath = " | ".join(["//button[contains(translate(., 'ACCEPTP', 'acceptp'), 'accept')]", "//button[contains(translate(., 'AGREE', 'agree'), 'agree')]"])
                wait.until(EC.element_to_be_clickable((By.XPATH, xpath))).click(); time.sleep(1)
            except TimeoutException: pass
            country_code = target.get('country', '').upper()
            available_data = {"full_name": self.user_info.get('full_name'), "email": self.user_info.get('email')}
            if country_code: available_data.update(self.user_info["identifiers"].get(country_code, {}))
            for key, selector in target['field_map'].items():
                if (val := available_data.get(key)) is None: continue
                try: wait.until(EC.presence_of_element_located((By.CSS_SELECTOR, selector))).send_keys(val)
                except TimeoutException: print(f"{Colors.FAIL}[!] Timeout for '{key}' ({selector}).{Colors.ENDC}"); break
            print(f"\n{Colors.CYAN}Details filled. Complete the process in the browser.{Colors.ENDC}")
            input("Press Enter once submitted..."); print(f"{Colors.GREEN}[+] Marked as handled.{Colors.ENDC}")
        except WebDriverException as e: print(f"{Colors.FAIL}[!] Browser error: {e}{Colors.ENDC}")
        except Exception as e: print(f"{Colors.FAIL}[!] Unexpected error: {e}{Colors.ENDC}")
        finally:
            if driver: driver.quit()

    def _handle_manual_eid(self, target: Dict[str, Any]):
        print(f"\n{Colors.CYAN}--- Manual Action Required for {target['name']} ---{Colors.ENDC}")
        print(f"[*] URL: {Colors.BOLD}{target['url']}{Colors.ENDC}")
        if 'notes' in target: print(f"[*] Notes: {target['notes']}")
        input("Press Enter to continue...")
        
    def _handle_mrkoll(self, target: Dict[str, Any]):
        if not self.chrome_service: return
        print(f"\n{Colors.BLUE}[*] Starting automated flow for {target['name']}...{Colors.ENDC}")
        if 'notes' in target: print(f"[*] Notes: {target['notes']}")
        input("Press Enter to open browser and begin..."); driver = None
        try:
            driver = webdriver.Chrome(service=self.chrome_service)
            driver.get(target['url'])
            wait = WebDriverWait(driver, 15)
            long_wait = WebDriverWait(driver, 120)

            print("[1/3] Clicking 'Starta inloggning med Mobilt BankID'...")
            login_button = wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, "div.csBtn1[onclick*='requestLogin']")))
            login_button.click()

            print(f"[2/3] {Colors.CYAN}Please complete BankID on your mobile device (waiting up to 2 minutes)...{Colors.ENDC}")
            long_wait.until(EC.url_to_be(target['url']))
            print(f"{Colors.GREEN}BankID login successful.{Colors.ENDC}")
            time.sleep(2)

            print("[3/3] Clicking 'Dölj' to hide address information...")
            hide_button = wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, "div#abtn.bankID_button")))
            hide_button.click()
            
            print(f"\n{Colors.GREEN}[+] MrKoll.se flow completed successfully!{Colors.ENDC}")
            input("Press Enter to continue...")
        except TimeoutException:
            print(f"{Colors.FAIL}[!] The process timed out. BankID login may have taken too long.{Colors.ENDC}")
            input("Press Enter to continue...")
        except Exception as e:
            print(f"{Colors.FAIL}[!] An unexpected error occurred: {e}{Colors.ENDC}")
        finally:
            if driver: driver.quit()
    
    def _handle_ratsit(self, target: Dict[str, Any]):
        if not self.chrome_service: return
        print(f"\n{Colors.BLUE}[*] Starting automated flow for {target['name']}...{Colors.ENDC}")
        if 'notes' in target: print(f"[*] Notes: {target['notes']}")
        input("Press Enter to open browser and begin..."); driver = None
        try:
            driver = webdriver.Chrome(service=self.chrome_service)
            driver.get(target['url'])
            wait = WebDriverWait(driver, 15)
            
            print("[1/2] Clicking the 'Mobilt BankID' button...")
            bankid_button = wait.until(EC.element_to_be_clickable((By.CSS_SELECTOR, "button[data-ga-event-label*='Validera BankID på annan enhet']")))
            bankid_button.click()

            print(f"[2/2] {Colors.CYAN}The BankID process is now active in the browser.{Colors.ENDC}")
            print("Please complete the login on your mobile device to finalize.")
            input("Press Enter here once you are finished...")
            print(f"{Colors.GREEN}[+] Ratsit.se flow marked as handled.{Colors.ENDC}")
        except Exception as e:
            print(f"{Colors.FAIL}[!] An unexpected error occurred: {e}{Colors.ENDC}")
        finally:
            if driver: driver.quit()

    def _setup(self):
        print(f"{Colors.BOLD}{Colors.HEADER}{'='*60}\n         Multi-Country Data Removal Automation Tool\n{'='*60}{Colors.ENDC}")
        if not self.args.country and not self.config.primary_country:
            self._interactive_country_selection()

        types_in_targets = {t.get('type') for t in self.targets}
        needs_email = "email" in types_in_targets
        needs_browser = any(t in types_in_targets for t in ["webform", "mrkoll_flow", "ratsit_flow"])
        needs_email_address = needs_email or any('email' in t.get('field_map', {}) for t in self.targets)

        self._get_user_info()
        if needs_email: self._get_smtp_config()
        elif needs_email_address and not self.smtp_config_obj.email:
            self.smtp_config_obj.email = input("Enter your email address (for forms): ")
            self.user_info['email'] = self.smtp_config_obj.email
        if needs_browser: self._initialize_driver_service()

        print(f"\n{Colors.BOLD}--- SUMMARY ---\nAbout to process {Colors.GREEN}{len(self.targets)}{Colors.ENDC} target(s).{Colors.ENDC}")
        if not self.targets: print(f"{Colors.WARNING}No targets to process. Exiting.{Colors.ENDC}"); sys.exit(0)
        if input("Ready to start? (Y/n): ").lower().strip() == 'n':
            print(f"{Colors.WARNING}Aborted.{Colors.ENDC}"); sys.exit(0)

    def _process_targets(self):
        print(f"\n{Colors.BOLD}{Colors.HEADER}{'='*60}\n                  Starting Removal Process\n{'='*60}{Colors.ENDC}")
        for i, target in enumerate(self.targets, 1):
            print(f"\n{Colors.BOLD}--- Processing {i}/{len(self.targets)}: {target['name']} ---{Colors.ENDC}")
            handler = self.handlers.get(target['type'])
            if handler: handler(target); time.sleep(1)
            else: print(f"{Colors.WARNING}Unknown type '{target['type']}'. Skipping.{Colors.ENDC}")
        
        if input("\nSave settings for next time? (Y/n): ").lower().strip() != 'n':
            print(f"{Colors.WARNING}Password will be saved in an obfuscated form.{Colors.ENDC}")
            self._save_config()
        print(f"\n{Colors.BOLD}{Colors.GREEN}{'='*60}\nProcess complete.\n{'='*60}{Colors.ENDC}")

    def run(self):
        self._setup(); self._process_targets()

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Automate data removal requests.", formatter_class=argparse.RawTextHelpFormatter)
    parser.add_argument('-c', '--country', help='Filter by country code (e.g., SE, US).')
    parser.add_argument('-t', '--type', choices=['email', 'webform', 'manual_eid', 'mrkoll_flow', 'ratsit_flow'], help='Filter by type.')
    parser.add_argument('-n', '--target-name', help='Filter by name (case-insensitive).')
    parser.add_argument('--clear-config', action='store_true', help='Delete the saved config file and exit.')
    args = parser.parse_args()

    if args.clear_config:
        if os.path.exists(config_file := "config.json"):
            os.remove(config_file); print(f"{Colors.GREEN}Deleted {config_file}.{Colors.ENDC}")
        else: print(f"{Colors.WARNING}{config_file} not found.{Colors.ENDC}")
        sys.exit(0)
    try:
        bot = DataRemovalBot("targets.json", "countries.json", args)
        bot.run()
    except KeyboardInterrupt:
        print(f"\n\n{Colors.FAIL}[!] Process aborted by user.{Colors.ENDC}"); sys.exit(0)