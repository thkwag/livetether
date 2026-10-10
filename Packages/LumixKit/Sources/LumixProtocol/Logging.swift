import os

/// Unified-logging subsystem shared by every LUMIX Webcam process and module.
public enum LumixLog {
    public static let subsystem = "com.github.thkwag.lumixwebcam"

    public static func logger(category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
