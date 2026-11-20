import Foundation

public protocol CommandRunner: Sendable {
    func run(_ path: String, _ args: [String], stdin: Data?) throws -> (status: Int32, stdout: Data)
}

public extension CommandRunner {
    func run(_ path: String, _ args: [String]) throws -> (status: Int32, stdout: Data) {
        try run(path, args, stdin: nil)
    }
}

public struct ProcessRunner: CommandRunner {
    public init() {}

    public func run(_ path: String, _ args: [String], stdin: Data?) throws -> (status: Int32, stdout: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = stdin == nil ? FileHandle.nullDevice : input
        try process.run()
        if let stdin {
            input.fileHandleForWriting.write(stdin)
            try input.fileHandleForWriting.close()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
