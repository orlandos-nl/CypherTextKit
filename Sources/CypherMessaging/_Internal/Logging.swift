import Foundation

public struct LogDomain {
    fileprivate  enum Raw: String {
        case none, webrtc, crypto, transport
    }
    
    fileprivate let raw: Raw
    
    public static let none = LogDomain(raw: .none)
    public static let webrtc = LogDomain(raw: .webrtc)
    public static let transport = LogDomain(raw: .transport)
    internal static let crypto = LogDomain(raw: .crypto)
}

fileprivate let formatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter
}()

// TODO: Swift-log
// This way this is a NO-OP in release
@inline(__always) public func debugLog(domain: LogDomain = .none, _ args: Any...) {
    #if DEBUG || Xcode
    print(domain.raw.rawValue, formatter.string(from: Date()), args)
    
    guard var url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
        return
    }
    
    url.appendPathComponent("logs.txt")
    
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: nil
        )
    }
    
    do {
        var string = ""
        print(formatter.string(from: Date()), args, terminator: "\n", to: &string)
        let handle = try FileHandle(forWritingTo: url)
        defer { handle.closeFile() }
        handle.seekToEndOfFile()
        handle.write(string.data(using: .utf8)!)
    } catch {
        print(error)
    }
    #endif
}
