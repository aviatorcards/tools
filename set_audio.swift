import Foundation
import CoreServices

// 1. Define the bundle ID of your preferred player
// Examples: 
// VLC: "org.videolan.vlc"
// IINA: "com.colliderli.iina"
// QuickTime: "com.apple.QuickTimePlayerX"
let preferredPlayer = "com.apple.QuickTimePlayerX" 

// 2. Define the audio formats you want to hijack
let audioTypes = [
    "public.mp3",
    "public.mpeg-4-audio",
    "com.microsoft.waveform-audio",
    "public.aifc-audio",
    "public.aiff-audio"
]

func setHandler() {
    print("Setting default player to: \(preferredPlayer)")
    
    for type in audioTypes {
        let status = LSSetDefaultRoleHandlerForContentType(
            type as CFString,
            .all,
            preferredPlayer as CFString
        )
        
        if status == noErr {
            print("✅ Successfully updated \(type)")
        } else {
            print("❌ Failed to update \(type). Error code: \(status)")
        }
    }
    
    print("\nNote: You may need to restart Finder or log out for changes to fully reflect in icons.")
}

setHandler()
