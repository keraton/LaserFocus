import Foundation

/// Runs the system `git` for the writing library.
///
/// Credentials never touch git's own configuration: each command gets `GIT_ASKPASS` pointing
/// back at LaserFocus itself (see ``GitAskPass``), which answers git's password prompt with
/// the GitHub token passed in the environment.
enum Git {
    struct Result {
        let status: Int32
        let output: Data
        let error: String
        var ok: Bool { status == 0 }
        var text: String { String(data: output, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        /// NUL-separated output of `-z` commands.
        var paths: [String] {
            (String(data: output, encoding: .utf8) ?? "").split(separator: "\0").map(String.init).filter { !$0.isEmpty }
        }
        var message: String {
            let lines = (error.isEmpty ? text : error).split(separator: "\n").map(String.init)
            return lines.last { $0.lowercased().hasPrefix("fatal") || $0.lowercased().hasPrefix("error") } ?? lines.last ?? "git failed"
        }
    }

    static let executable = "/usr/bin/git"

    /// True when git can run. Without Apple's Command Line Tools, /usr/bin/git only offers to
    /// install them, which this also triggers.
    static var isAvailable: Bool {
        let result = run(["--version"], in: nil, token: nil, timeout: 20)
        return result.ok && result.text.hasPrefix("git version")
    }

    @discardableResult
    static func run(_ arguments: [String], in directory: URL?, token: String?, timeout: TimeInterval = 120) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // No credential helper: the token comes from GIT_ASKPASS only, and isn't stored anywhere.
        process.arguments = ["-c", "credential.helper=", "-c", "core.quotepath=false"] + arguments
        if let directory = directory { process.currentDirectoryURL = directory }

        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        if let token = token, let me = Bundle.main.executablePath {
            environment["GIT_ASKPASS"] = me
            environment[GitAskPass.flag] = "1"
            environment[GitAskPass.tokenVariable] = token
        }
        process.environment = environment

        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: Data(), error: error.localizedDescription)
        }
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        // Read both pipes concurrently so neither can fill up and stall git.
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        deadline.cancel()
        return Result(status: process.terminationStatus, output: data,
                      error: String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

/// LaserFocus doubles as git's password prompt: when git runs it with the flag set, it prints
/// the token (or a username) and exits, before any app setup.
enum GitAskPass {
    static let flag = "LASERFOCUS_ASKPASS"
    static let tokenVariable = "LASERFOCUS_GIT_TOKEN"

    static func handleIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        guard environment[flag] == "1" else { return }
        let prompt = CommandLine.arguments.dropFirst().first?.lowercased() ?? ""
        print(prompt.hasPrefix("username") ? "x-access-token" : (environment[tokenVariable] ?? ""))
        exit(0)
    }
}

/// The few GitHub calls sync needs: who the writer is, their repositories, and creating one.
enum GitHub {
    struct Account {
        let login: String
        let id: Int
        let name: String?
        /// GitHub's private address for commits, so no real email is published.
        var commitEmail: String { "\(id)+\(login)@users.noreply.github.com" }
    }

    enum Failure: LocalizedError {
        case noToken, http(Int, String), offline(String)
        var errorDescription: String? {
            switch self {
            case .noToken: return "Connect a GitHub account first."
            case .http(401, _): return "GitHub didn't accept the token. Paste a new one."
            case .http(let status, let message): return "GitHub error \(status): \(message)"
            case .offline(let message): return "Couldn't reach GitHub: \(message)"
            }
        }
    }

    /// A pasted token wins; otherwise the GitHub CLI's login, if it's installed and signed in.
    static func token() -> (value: String, source: String)? {
        if let saved = Keychain.string(for: Keychain.gitHubTokenAccount), !saved.isEmpty {
            return (saved, "token")
        }
        guard let gh = ghPath() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: gh)
        process.arguments = ["auth", "token"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return process.terminationStatus == 0 && !token.isEmpty ? (token, "GitHub CLI") : nil
    }

    static func ghPath() -> String? {
        ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func account(token: String) throws -> Account {
        let json = try request("GET", "/user", token: token) as? [String: Any] ?? [:]
        guard let login = json["login"] as? String, let id = json["id"] as? Int else {
            throw Failure.http(0, "unexpected reply")
        }
        return Account(login: login, id: id, name: json["name"] as? String)
    }

    /// The writer's repositories, most recently updated first, as "owner/name".
    static func repositories(token: String) throws -> [String] {
        let list = try request("GET", "/user/repos?per_page=100&sort=updated&affiliation=owner,collaborator",
                               token: token) as? [[String: Any]] ?? []
        return list.compactMap { $0["full_name"] as? String }
    }

    /// Creates a private repository and returns its "owner/name".
    static func createPrivateRepository(named name: String, token: String) throws -> String {
        let body: [String: Any] = ["name": name, "private": true, "auto_init": false,
                                   "description": "Writing library synced by LaserFocus"]
        let json = try request("POST", "/user/repos", body: body, token: token) as? [String: Any] ?? [:]
        guard let fullName = json["full_name"] as? String else { throw Failure.http(0, "unexpected reply") }
        return fullName
    }

    /// A blocking HTTPS request; call it off the main thread.
    private static func request(_ method: String, _ path: String, body: [String: Any]? = nil, token: String) throws -> Any {
        var request = URLRequest(url: URL(string: "https://api.github.com" + path)!)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("LaserFocus", forHTTPHeaderField: "User-Agent")
        if let body = body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var result: Swift.Result<Any, Error> = .failure(Failure.offline("no response"))
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { done.signal() }
            if let error = error {
                result = .failure(Failure.offline(error.localizedDescription))
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            guard (200..<300).contains(status) else {
                var message = (json as? [String: Any])?["message"] as? String ?? "request failed"
                if let errors = (json as? [String: Any])?["errors"] as? [[String: Any]],
                   let detail = errors.first?["message"] as? String {
                    message += " (\(detail))"
                }
                result = .failure(Failure.http(status, message))
                return
            }
            result = .success(json ?? [:])
        }.resume()
        done.wait()
        return try result.get()
    }
}
