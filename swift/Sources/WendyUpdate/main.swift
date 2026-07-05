import Foundation

enum WendyUpdate {
    static let version = "0.1.0-dev"
}

FileHandle.standardError.write(Data("wendyos-update: usage: wendyos-update <verb> [options]\n".utf8))
