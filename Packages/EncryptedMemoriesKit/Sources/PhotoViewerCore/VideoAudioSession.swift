#if os(iOS)
    import AVFoundation

    /// A video plays its sound also when the Ring/Silent switch is set to silent, and the volume
    /// buttons control it. Only a playing video takes the audio session. When the last video player goes away, the
    /// default category returns, so browsing and Live Photos follow the switch again.
    @MainActor
    public enum VideoAudioSession {
        private static var players = 0

        public static func begin() {
            players += 1
            guard players == 1 else { return }
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback)
                try session.setActive(true)
            } catch {
                // The default category stays: the video plays, and its sound follows the switch as before.
            }
        }

        public static func end() {
            guard players > 0 else { return }
            players -= 1
            guard players == 0 else { return }
            let session = AVAudioSession.sharedInstance()
            // Other apps may resume their audio. A failure keeps the session active until the next video ends.
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(.soloAmbient)
        }
    }
#endif
