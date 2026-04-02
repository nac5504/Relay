import Foundation
import Darwin

class PortAllocator {
    private var nextIndex: Int = 0
    private var freedIndices: [Int] = []
    private let basePort: Int

    init(basePort: Int = 17900) {
        self.basePort = basePort
    }

    struct Ports {
        let noVNC: Int
        let vnc: Int
        let selenium: Int
    }

    func allocate() -> Ports {
        // Try freed indices first, then new indices, skipping any with ports already in use
        while let reused = freedIndices.popLast() {
            let ports = portsForIndex(reused)
            if isAvailable(ports) { return ports }
        }
        while true {
            let index = nextIndex
            nextIndex += 1
            let ports = portsForIndex(index)
            if isAvailable(ports) { return ports }
        }
    }

    func release(noVNCPort: Int) {
        let index = (noVNCPort - basePort) / 10
        freedIndices.append(index)
    }

    func reset() {
        nextIndex = 0
        freedIndices.removeAll()
    }

    private func portsForIndex(_ index: Int) -> Ports {
        let offset = index * 10
        return Ports(
            noVNC: basePort + offset,
            vnc: basePort + offset + 1,
            selenium: basePort + offset + 2
        )
    }

    private func isAvailable(_ ports: Ports) -> Bool {
        isPortFree(ports.noVNC) && isPortFree(ports.vnc) && isPortFree(ports.selenium)
    }

    private func isPortFree(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        // If connect succeeds, port is in use; if it fails, port is free
        return result != 0
    }
}
