// Core.swift — спільні дрібниці (файли, журнал, час), локальний протокол станції Oukitel/Quectel
// (кадри AA AA, TTLV, AES-128-CBC) і пошук станції в домашній мережі (UDP 6606).
import Foundation
import CommonCrypto
import CryptoKit

// MARK: файли й журнал

let appSupport: URL = {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("Станція", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()
/// Папка першої (Python) версії — звідти один раз переносяться ключ, історія й налаштування.
let legacyDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("oukitel", isDirectory: true)

let logURL = appSupport.appendingPathComponent("station.log")
let logLock = NSLock()
func log(_ msg: String) {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date())) \(msg)\n"
    logLock.lock(); defer { logLock.unlock() }
    if let h = try? FileHandle(forWritingTo: logURL) {
        h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.data(using: .utf8)!.write(to: logURL)
    }
    // журнал не росте безмежно: понад 2 МБ — лишаємо останню половину
    if let a = try? FileManager.default.attributesOfItem(atPath: logURL.path), (a[.size] as? Int ?? 0) > 2_000_000,
       let d = try? Data(contentsOf: logURL) {
        try? d.suffix(d.count / 2).write(to: logURL)
    }
}

// MARK: час і числа

private func fmt(_ pattern: String) -> DateFormatter { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern; return f }
func isoMin(_ d: Date) -> String { fmt("yyyy-MM-dd'T'HH:mm").string(from: d) }
func isoSec(_ d: Date) -> String { fmt("yyyy-MM-dd'T'HH:mm:ss").string(from: d) }
func dayKey(_ d: Date) -> String { fmt("yyyy-MM-dd").string(from: d) }
/// Початок доби (місцевий час) для ключа yyyy-MM-dd.
func startOfDay(_ key: String) -> Date? {
    let p = key.prefix(10).split(separator: "-").compactMap { Int($0) }
    guard p.count == 3 else { return nil }
    var c = DateComponents(); c.year = p[0]; c.month = p[1]; c.day = p[2]; c.hour = 0; c.minute = 0; c.second = 0
    return Calendar.current.date(from: c)
}
func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
func median(_ a: [Double]) -> Double {
    guard !a.isEmpty else { return 0 }
    let s = a.sorted(), n = s.count
    return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
}

/// IPv4-адреса Mac у домашній мережі (для посилання на панель з телефона по Wi-Fi).
func lanIP() -> String? {
    var ifaddr: UnsafeMutablePointer<ifaddrs>? = nil
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
    defer { freeifaddrs(ifaddr) }
    var best: String? = nil
    for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
        guard let sa = p.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
        let flags = Int32(p.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        let ip = String(cString: host), name = String(cString: p.pointee.ifa_name)
        if ip.hasPrefix("169.254.") { continue }
        if name == "en0" { return ip }
        if best == nil { best = ip }
    }
    return best
}

// MARK: AES-CBC (вхід у Wonderfree і локальний канал станції)

func aesCBC(_ data: Data, key: Data, iv: Data, encrypt: Bool) -> Data? {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { d in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count, o.baseAddress, out.count, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    return out.prefix(moved)
}

// MARK: TTLV — значення в кадрах станції

/// Значення TTLV: число (цілі й «з десятковими» — як Double), логічне, рядок, байти або структура (список полів).
enum TV: CustomStringConvertible {
    case bool(Bool), num(Double), str(String), bytes(Data), list([(Int, TV)])
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var double: Double? { if case .num(let d) = self { return d }; return nil }
    var string: String? { if case .str(let s) = self { return s }; if case .bytes(let d) = self { return String(data: d, encoding: .utf8) }; return nil }
    /// Поля структури як словник id → значення.
    var dict: [Int: TV] { if case .list(let l) = self { var r = [Int: TV](); for (k, v) in l { r[k] = v }; return r }; return [:] }
    var description: String {
        switch self {
        case .bool(let b): return b ? "true" : "false"
        case .num(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .str(let s): return s
        case .bytes(let d): return "hex:" + d.map { String(format: "%02x", $0) }.joined()
        case .list(let l): return "{" + l.map { "\($0.0)=\($0.1)" }.joined(separator: ", ") + "}"
        }
    }
}

func be16(_ v: Int) -> [UInt8] { [UInt8((v >> 8) & 0xFF), UInt8(v & 0xFF)] }

/// Ціле: тег (id<<3 | 2), байт «знак|довжина−1», величина старшим байтом уперед.
func ttlv(_ id: Int, int v: Int) -> Data {
    var mag = v.magnitude, raw = [UInt8]()
    repeat { raw.insert(UInt8(mag & 0xFF), at: 0); mag >>= 8 } while mag > 0
    var d = Data(be16(id << 3 | 2)); d.append(UInt8((v < 0 ? 0x80 : 0) | (raw.count - 1))); d.append(contentsOf: raw)
    return d
}
/// Логічне: тег (id<<3 | 0/1), без значення.
func ttlv(_ id: Int, bool b: Bool) -> Data { Data(be16(id << 3 | (b ? 1 : 0))) }
/// Рядок: тег (id<<3 | 3), довжина (2 байти), байти.
func ttlv(_ id: Int, str s: String) -> Data {
    let raw = Array(s.utf8)
    var d = Data(be16(id << 3 | 3)); d.append(contentsOf: be16(raw.count)); d.append(contentsOf: raw)
    return d
}

/// Розбирає список TTLV. Структури (тип 4 — лічильник полів, тип 5 — вкладений список) розбираються рекурсивно.
func decodeTTLV(_ payload: Data) -> [(Int, TV)] {
    let b = [UInt8](payload)
    var off = 0
    return decodeList(b, &off, end: b.count, count: nil)
}
private func decodeList(_ b: [UInt8], _ off: inout Int, end: Int, count: Int?) -> [(Int, TV)] {
    var res = [(Int, TV)]()
    while off + 2 <= end, count == nil || res.count < count! {
        let tag = Int(b[off]) << 8 | Int(b[off + 1]); off += 2
        let id = tag >> 3, type = tag & 7
        switch type {
        case 0, 1:
            res.append((id, .bool(type == 1)))
        case 2:
            guard off < end else { return res }
            let h = Int(b[off]); off += 1
            let len = (h & 7) + 1
            guard off + len <= end else { return res }
            var v: Double = 0
            for i in 0..<len { v = v * 256 + Double(b[off + i]) }
            off += len
            if h & 0x80 != 0 { v = -v }
            let dec = (h >> 3) & 0x0F
            if dec > 0 { v /= pow(10, Double(dec)) }
            res.append((id, .num(v)))
        case 3, 5:
            guard off + 2 <= end else { return res }
            let len = Int(b[off]) << 8 | Int(b[off + 1]); off += 2
            guard off + len <= end else { return res }
            let raw = Array(b[off..<off + len]); off += len
            if type == 5 {
                var o = 0
                res.append((id, .list(decodeList(raw, &o, end: raw.count, count: nil))))
            } else if let s = String(bytes: raw, encoding: .utf8), !s.contains(where: { $0.asciiValue.map { $0 < 32 } ?? false }) {
                res.append((id, .str(s)))
            } else {
                res.append((id, .bytes(Data(raw))))
            }
        case 4:
            guard off + 2 <= end else { return res }
            let n = Int(b[off]) << 8 | Int(b[off + 1]); off += 2
            res.append((id, .list(decodeList(b, &off, end: end, count: n))))
        default:
            off = end   // невідомий тип — далі розібрати не можемо
        }
    }
    return res
}

// MARK: кадри AA AA

private func frameChecksum(_ d: ArraySlice<UInt8>) -> UInt8 { UInt8(d.reduce(0) { ($0 + Int($1)) & 0xFF }) }

/// Кадр: AA AA, довжина (payload+5), контрольна сума, id пакета, команда, дані; після заголовка кожне AA перед 55/AA доповнюється байтом 55.
func encodeFrame(packetID: Int, command: Int, payload: Data = Data()) -> Data {
    var f = [UInt8]([0xAA, 0xAA]) + be16(payload.count + 5) + [0x00] + be16(packetID & 0xFFFF) + be16(command & 0xFFFF) + [UInt8](payload)
    f[4] = frameChecksum(f[5...])
    var out = Array(f[0..<2])
    for i in 2..<f.count {
        out.append(f[i])
        if i + 1 < f.count, f[i] == 0xAA, f[i + 1] == 0x55 || f[i + 1] == 0xAA { out.append(0x55) }
    }
    return Data(out)
}

struct Frame { let packetID: Int; let cmd: Int; let payload: Data }

/// Вирізає з буфера перший повний кадр (знімаючи доповнення 55) або повертає nil, якщо кадр ще не весь.
func extractFrame(_ buf: inout [UInt8]) -> Frame? {
    guard let start = (0..<max(0, buf.count - 1)).first(where: { buf[$0] == 0xAA && buf[$0 + 1] == 0xAA }) else {
        if buf.count > 1 { buf.removeAll() }
        return nil
    }
    if start > 0 { buf.removeFirst(start) }
    guard buf.count >= 4 else { return nil }
    var logical = Array(buf[0..<2]), raw = 2, expected: Int? = nil
    while raw < buf.count {
        let b = buf[raw]; logical.append(b); raw += 1
        if b == 0xAA, raw + 1 < buf.count, buf[raw] == 0x55, buf[raw + 1] == 0x55 || buf[raw + 1] == 0xAA { raw += 1 }
        if expected == nil, logical.count >= 4 { expected = 4 + (Int(logical[2]) << 8 | Int(logical[3])) }
        if let e = expected, logical.count == e {
            buf.removeFirst(raw)
            guard logical.count >= 9 else { return nil }
            return Frame(packetID: Int(logical[5]) << 8 | Int(logical[6]), cmd: Int(logical[7]) << 8 | Int(logical[8]), payload: Data(logical[9...]))
        }
    }
    return nil
}

enum NetErr: Error, CustomStringConvertible {
    case connect(String), auth(String), timeout, closed
    var description: String {
        switch self {
        case .connect(let s): return "немає з'єднання: \(s)"
        case .auth(let s): return "авторизація: \(s)"
        case .timeout: return "станція мовчить"
        case .closed: return "станція закрила з'єднання"
        }
    }
}

// MARK: TCP-з'єднання зі станцією (порт 6607)

final class StationConn {
    private var fd: Int32 = -1
    private let key: Data
    private var iv: Data? = nil
    private var seq = 1000
    private var buf = [UInt8]()

    init(host: String, port: UInt16, key: Data) throws {
        self.key = key
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>? = nil
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let ai = res else { throw NetErr.connect("адресу \(host) не розпізнано") }
        defer { freeaddrinfo(res) }
        fd = socket(ai.pointee.ai_family, ai.pointee.ai_socktype, ai.pointee.ai_protocol)
        guard fd >= 0 else { throw NetErr.connect("socket") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // підключення з таймаутом 5 с: неблокуючий connect + poll
        let fl = fcntl(fd, F_GETFL); _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
        let rc = connect(fd, ai.pointee.ai_addr, ai.pointee.ai_addrlen)
        if rc != 0 && errno != EINPROGRESS { close(fd); fd = -1; throw NetErr.connect("\(host):\(port) недоступна") }
        if rc != 0 {
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, 5000) > 0 else { close(fd); fd = -1; throw NetErr.connect("\(host):\(port) не відповідає") }
            var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
            if err != 0 { close(fd); fd = -1; throw NetErr.connect("\(host):\(port) відмовила (\(err))") }
        }
        _ = fcntl(fd, F_SETFL, fl)
    }
    deinit { if fd >= 0 { close(fd) } }

    private func crypt(_ d: Data, encrypt: Bool) -> Data? { iv.flatMap { aesCBC(d, key: key, iv: $0, encrypt: encrypt) } }

    func send(_ cmd: Int, _ payload: Data = Data()) throws {
        seq = seq >= 65534 ? 1000 : seq + 1
        var p = payload
        if !p.isEmpty, iv != nil { guard let e = crypt(p, encrypt: true) else { throw NetErr.auth("шифрування") }; p = e }
        let f = [UInt8](encodeFrame(packetID: seq, command: cmd, payload: p))
        var sent = 0
        while sent < f.count {
            let n = f[sent...].withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 { throw NetErr.closed }
            sent += n
        }
    }

    /// Наступний кадр або nil, якщо за `timeout` секунд нічого не прийшло.
    func recv(_ timeout: Double) throws -> Frame? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let f = extractFrame(&buf) {
                if !f.payload.isEmpty, iv != nil, let d = crypt(f.payload, encrypt: false) { return Frame(packetID: f.packetID, cmd: f.cmd, payload: d) }
                return f
            }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, Int32(left * 1000))
            if r == 0 { return nil }
            if r < 0 { if errno == EINTR { continue }; throw NetErr.closed }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, 4096, 0) }
            if n <= 0 { throw NetErr.closed }
            buf.append(contentsOf: chunk[0..<n])
        }
    }

    /// Рукостискання: станція дає nonce, ми відповідаємо sha256(hex(ключ) + ";" + nonce); далі дані шифруються AES-CBC з iv = nonce.
    func auth() throws {
        try send(0x7032)
        guard let f1 = try recv(3) else { throw NetErr.timeout }
        guard let nonceTV = decodeTTLV(f1.payload).first(where: { $0.0 == 1 })?.1 else { throw NetErr.auth("станція не дала nonce") }
        let nonce: Data
        switch nonceTV { case .str(let s): nonce = Data(s.utf8); case .bytes(let d): nonce = d; default: throw NetErr.auth("дивний nonce") }
        guard let nonceStr = String(data: nonce, encoding: .utf8) else { throw NetErr.auth("дивний nonce") }
        let digest = SHA256.hash(data: Data((key.map { String(format: "%02x", $0) }.joined() + ";" + nonceStr).utf8)).map { String(format: "%02x", $0) }.joined()
        try send(0x7034, ttlv(2, str: digest))
        guard let f2 = try recv(3) else { throw NetErr.timeout }
        let status = decodeTTLV(f2.payload).first(where: { $0.0 == 3 })?.1.double ?? -1
        guard status == 0 else { throw NetErr.auth("станція відхилила ключ (статус \(Int(status))) — увійдіть у Wonderfree знову") }
        iv = nonce
        try send(0x7039, ttlv(1, int: 30) + ttlv(2, int: 1))
    }
}

// MARK: пошук станції в мережі (UDP 6606)

struct FoundStation { let host: String; let port: UInt16; let deviceKey: String; let productKey: String }

func discover(timeout: Double = 3) -> [FoundStation] {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return [] }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))
    func mkAddr(_ port: UInt16, _ addr: UInt32) -> sockaddr_in {
        var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET)
        a.sin_port = port.bigEndian; a.sin_addr = in_addr(s_addr: addr.bigEndian); return a
    }
    var bindTo = mkAddr(6606, INADDR_ANY)
    let bound = withUnsafePointer(to: &bindTo) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if bound != 0 { var any = mkAddr(0, INADDR_ANY); _ = withUnsafePointer(to: &any) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
    let probe = [UInt8](encodeFrame(packetID: 1000, command: 0x7030))
    var dst = mkAddr(6606, INADDR_BROADCAST)
    var found = [String: FoundStation]()
    let deadline = Date().addingTimeInterval(timeout)
    var nextSend = Date()
    while Date() < deadline {
        if Date() >= nextSend {
            _ = withUnsafePointer(to: &dst) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, probe, probe.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            nextSend = Date().addingTimeInterval(1)
        }
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, 300) > 0 else { continue }
        var chunk = [UInt8](repeating: 0, count: 4096)
        var from = sockaddr_in(); var flen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &chunk, 4096, 0, $0, &flen) } }
        guard n > 0 else { continue }
        var b = Array(chunk[0..<n])
        guard let f = extractFrame(&b), f.cmd == 0x7031 else { continue }
        var vals = [Int: TV](); for (k, v) in decodeTTLV(f.payload) { vals[k] = v }
        let sender = String(cString: inet_ntoa(from.sin_addr))
        let host = vals[5]?.string ?? sender
        let port = UInt16(clamping: Int(vals[6]?.double ?? 6607))
        guard let dk = vals[4]?.string else { continue }
        found[dk] = FoundStation(host: host.isEmpty ? sender : host, port: port == 0 ? 6607 : port, deviceKey: dk, productKey: vals[3]?.string ?? "")
    }
    return Array(found.values)
}
