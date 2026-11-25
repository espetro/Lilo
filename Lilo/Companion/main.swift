import Foundation

// lilo-companion: the native-messaging host the Lilo companion extension connects to. A browser
// launches it with the caller's origin as its only argument, and speaks Chrome's native messaging
// framing over its standard input and output.

CompanionHostMain.run(origin: CommandLine.arguments.dropFirst().first)
