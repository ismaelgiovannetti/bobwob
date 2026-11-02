import CryptoKit
import Foundation

public enum DockerEndpoint {
    /// Follows Docker's own resolution order, because `/var/run/docker.sock` is optional.
    public static func resolveSocketPath(home: URL, environment: [String: String]) -> String? {
        if let host = environment["DOCKER_HOST"] {
            return unixPath(from: host)
        }
        let contextName = environment["DOCKER_CONTEXT"] ?? currentContext(home: home)
        if let contextName, contextName != "default" {
            return contextSocketPath(named: contextName, home: home)
        }
        return "/var/run/docker.sock"
    }

    private static func currentContext(home: URL) -> String? {
        let url = home.appending(path: ".docker/config.json")
        guard let data = try? Data(contentsOf: url),
            let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return config["currentContext"] as? String
    }

    private static func contextSocketPath(named name: String, home: URL) -> String? {
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = home.appending(path: ".docker/contexts/meta/\(digest)/meta.json")
        guard let data = try? Data(contentsOf: url),
            let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let endpoints = meta["Endpoints"] as? [String: Any],
            let docker = endpoints["docker"] as? [String: Any],
            let host = docker["Host"] as? String
        else { return nil }
        return unixPath(from: host)
    }

    private static func unixPath(from host: String) -> String? {
        guard host.hasPrefix("unix://") else { return nil }
        return String(host.dropFirst("unix://".count))
    }
}
