import os

/// Unified logging. Read with:
///   log stream --predicate 'subsystem == "com.autoduck.app"' --level info
enum Log {
    static let subsystem = "com.autoduck.app"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let volume = Logger(subsystem: subsystem, category: "volume")
    static let duck = Logger(subsystem: subsystem, category: "duck")
}
