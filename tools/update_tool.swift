import CryptoKit
import Foundation

// Signs updates so the app only installs files that came from you.
//   swift tools/update_tool.swift gen          make the key pair (once); prints the public key
//   swift tools/update_tool.swift pub          print the public key
//   swift tools/update_tool.swift sign <file>  print the file's signature
// The private key lives at ~/.island-update-key, outside the project and the dmg. Back it up:
// if it is lost, installed copies can never accept an update again.
let keyPath = NSHomeDirectory() + "/.island-update-key"
let args = CommandLine.arguments
func load() -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: keyPath, encoding: .utf8),
          let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else {
        FileHandle.standardError.write(Data("no key at \(keyPath): run gen first\n".utf8)); exit(1)
    }
    return key
}
switch args.dropFirst().first {
case "gen":
    if FileManager.default.fileExists(atPath: keyPath) { print("key already exists; public key:") }
    else {
        let key = Curve25519.Signing.PrivateKey()
        try key.rawRepresentation.base64EncodedString().write(toFile: keyPath, atomically: true, encoding: .utf8)
        chmod(keyPath, 0o600)
    }
    print(load().publicKey.rawRepresentation.base64EncodedString())
case "pub":
    print(load().publicKey.rawRepresentation.base64EncodedString())
case "sign":
    guard args.count > 2, let data = FileManager.default.contents(atPath: args[2]) else { print("usage: sign <file>"); exit(1) }
    print(try load().signature(for: data).base64EncodedString())
default:
    print("usage: gen | pub | sign <file>")
}
