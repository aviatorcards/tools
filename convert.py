import os
import subprocess

def convert_flac_to_mp3(input_dir=".", output_dir="mp3_output"):
    """
    Converts all FLAC files in a directory (and its subdirectories)
    to 320 kbps MP3 files in a specified output directory.

    Args:
        input_dir (str): The directory to search for FLAC files.
                         Defaults to the current directory.
        output_dir (str): The directory to save the converted MP3 files.
                          Defaults to 'mp3_output'.
    """
    if not os.path.exists(output_dir):
        os.makedirs(output_dir)

    for root, _, files in os.walk(input_dir):
        for file in files:
            if file.lower().endswith(".flac"):
                flac_path = os.path.join(root, file)
                # Create the corresponding output directory structure
                relative_path = os.path.relpath(root, input_dir)
                target_output_dir = os.path.join(output_dir, relative_path)
                if not os.path.exists(target_output_dir):
                    os.makedirs(target_output_dir)

                base_name = os.path.splitext(file)[0]
                mp3_path = os.path.join(target_output_dir, f"{base_name}.mp3")

                print(f"Converting \"{flac_path}\" to \"{mp3_path}\"...")

                # ffmpeg command
                command = [
                    "ffmpeg",
                    "-i", flac_path,
                    "-ab", "320k",
                    "-map_metadata", "0",
                    "-id3v2_version", "3",
                    mp3_path
                ]

                try:
                    subprocess.run(command, check=True, capture_output=True, text=True)
                    print(f"Successfully converted \"{flac_path}\"")
                except subprocess.CalledProcessError as e:
                    print(f"Error converting \"{flac_path}\": {e}")
                    print(f"Stderr: {e.stderr}")
                print("-" * 20) # Separator

    print("Conversion process finished.")

if __name__ == "__main__":
    # You can change the input_dir and output_dir here if needed
    convert_flac_to_mp3()
