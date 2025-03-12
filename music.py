import os
import platform
import datetime
from pydub import AudioSegment
import gspread
from google.oauth2.service_account import Credentials
import logging
import time

# Enable debug logging for troubleshooting
logging.basicConfig(level=logging.DEBUG)

# Google Sheets setup
SCOPES = [
    'https://www.googleapis.com/auth/spreadsheets',
    'https://www.googleapis.com/auth/drive'
]
SERVICE_ACCOUNT_FILE = '../credentials.json'  # Replace with your credentials file

credentials = Credentials.from_service_account_file(
    SERVICE_ACCOUNT_FILE, scopes=SCOPES
)
client = gspread.authorize(credentials)

# Open the Google Sheet by ID
SPREADSHEET_ID = "15a6dmLkK8yk-GaXxDgljgf4zdgZ2FsJyxk_DF_60OhQ"
try:
    spreadsheet = client.open_by_key(SPREADSHEET_ID)
    sheet = spreadsheet.sheet1
except Exception as e:
    print(f"Error accessing Google Sheet: {e}")
    exit()

# Add headers to the Google Sheet if it's empty
if not sheet.get_all_records():
    sheet.append_row(["File Name", "Duration (sec)", "File Size (KB)", "Date Created"])

# Function to extract metadata using pydub
def get_audio_metadata(file_path):
    try:
        # Use pydub to load the audio file and calculate duration
        audio = AudioSegment.from_file(file_path)
        duration_seconds = int(len(audio) / 1000)

        minutes = duration_seconds // 60
        seconds = duration_seconds % 60
        duration_formatted = f"{minutes}:{seconds:02d}"

        # Get file size in KB
        file_size = os.path.getsize(file_path) / 1024

        # Get creation date
        if platform.system() == "Windows":
            created_time = os.path.getctime(file_path)  # Creation time for Windows
        else:
            stat = os.stat(file_path)
            created_time = stat.st_birthtime if hasattr(stat, 'st_birthtime') else stat.st_mtime  # For Unix-based systems
        
        # Convert to readable date
        created_date = datetime.datetime.fromtimestamp(created_time).strftime('%Y-%m-%d %H:%M:%S')

        return {
            "file_name": os.path.basename(file_path),
            "duration": duration_formatted,
            "file_size": round(file_size, 2),
            "created_date": created_date,
        }
    except Exception as e:
        print(f"Error processing file {file_path}: {e}")
        return None

# Directory containing audio files
audio_dir = "/home/tristan/fuck/"
if not os.path.exists(audio_dir):
    print(f"Directory '{audio_dir}' not found!")
    exit()

# Process files and append metadata to Google Sheets
for root, _, files in os.walk(audio_dir):
    for file in files:
        if file.lower().endswith(('.mp3', '.wav', '.flac', '.aac', '.ogg')):
            file_path = os.path.join(root, file)
            print(f"Processing file: {file_path}")  # Debugging
            
            metadata = get_audio_metadata(file_path)
            if metadata:
                print(f"Metadata for {metadata['file_name']}: {metadata}")  # Debugging
                try:
                    sheet.append_row([
                        metadata["file_name"],
                        metadata["duration"],
                        metadata["file_size"],
                        metadata["created_date"],
                    ])
                    print(f"Successfully added {metadata['file_name']} to Google Sheet.")
                    time.sleep(0.5)  # Pause to avoid hitting rate limits
                except Exception as e:
                    print(f"Failed to write metadata for {file_path}: {e}")

print("Metadata export completed.")
