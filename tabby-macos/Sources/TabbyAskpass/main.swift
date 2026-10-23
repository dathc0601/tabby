// tabby-askpass: SSH_ASKPASS helper for TabbyMac.
//
// OpenSSH runs this with the prompt as argv[1] (and SSH_ASKPASS_PROMPT set to "confirm" or
// "none" for non-secret prompts). The helper forwards the prompt to the app over a Unix
// socket and prints the answer for ssh. Exit status 1 means "cancelled".
//
// `tabby-askpass --connected` is used as ssh's LocalCommand to tell the app that
// authentication succeeded.

import Foundation
#if !ASKPASS_STANDALONE
// In the Xcode tool target the TabbyIPC sources are compiled into this module directly.
import TabbyIPC
#endif

let env = ProcessInfo.processInfo.environment
guard let socketPath = env[AskpassEnvironment.socketKey],
      let session = env[AskpassEnvironment.sessionKey],
      let token = env[AskpassEnvironment.tokenKey] else {
    FileHandle.standardError.write(Data("tabby-askpass: not started by TabbyMac\n".utf8))
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let request: AskpassRequest
if args.first == "--connected" {
    request = AskpassRequest(kind: .connected, session: session, token: token)
} else {
    request = AskpassRequest(kind: .prompt, session: session, token: token,
                             prompt: args.joined(separator: " "), promptType: env["SSH_ASKPASS_PROMPT"])
}

do {
    let fd = try UnixSocket.connect(path: socketPath)
    defer { UnixSocket.closeSocket(fd) }
    let line = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    UnixSocket.writeLine(fd, line)
    guard let reply = UnixSocket.readLine(fd),
          let response = try? JSONDecoder().decode(AskpassResponse.self, from: Data(reply.utf8)) else {
        exit(1)
    }
    if request.kind == .connected { exit(0) }
    guard response.ok else { exit(1) }
    if let answer = response.answer {
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
    }
    exit(0)
} catch {
    FileHandle.standardError.write(Data("tabby-askpass: \(error)\n".utf8))
    exit(1)
}
