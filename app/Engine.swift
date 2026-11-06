// Engine.swift — стан станції, історія, графік Yasno, розрахунки та вбудований веб-сервер.
import Foundation
import Network

struct Sample { let ts: Double; let soc: Double; let out: Double; let inW: Double; let temp: Double; let mode: String }
struct GridEvent { let ts: Double; let type: String }
/// Опціональне значення → значення або NSNull для JSON.
func nn<T>(_ v: T?) -> Any { v.map { $0 as Any } ?? NSNull() }

final class Engine {
    static let shared = Engine()
    let lock = NSRecursiveLock()   // рекурсивний: cfgD/cfgS викликаються і зсередини заблокованих ділянок
    private let saveQueue = DispatchQueue(label: "ua.oukitel.save")
    let port: UInt16 = 8765

    // файли
    let configURL = appSupport.appendingPathComponent("config.json")
    let historyURL = appSupport.appendingPathComponent("history.csv")
    let schedURL = appSupport.appendingPathComponent("schedules.json")
    let lastURL = appSupport.appendingPathComponent("last_state.json")
    let authURL = appSupport.appendingPathComponent("auth.json")

    var config: [String: Any] = [
        "group": "", "group_candidates": [String](), "group_confirmed": false,
        "region_id": 25, "dso_id": 902, "region_name": "Київ", "model": "", "setup_skipped_group": false,
        "capacity_wh": 2048.0, "inverter_efficiency": 0.90, "reserve_percent": 0.0, "charge_efficiency": 0.92,
        "max_ac_charge_w": 1800.0, "night": [23, 8], "weekend_days": [5, 6],
        "fallback_watts": ["work": 150.0, "night": 60.0, "weekend": 120.0],
        "manual_power_on": NSNull(), "host": NSNull(), "last_host": NSNull(),
    ]
    var state: [String: Any] = ["connected": false]
    var recent: [(Double, Double)] = []
    var history: [Sample] = []
    var events: [GridEvent] = []
    var schedule: [String: Any] = ["ok": false, "error": "ще не завантажено"]
    var schedStore: [String: [String: [String: Any]]] = [:]
    var controlQueue: [(Int, Data)] = []
    var pendingSwitch: [String: (value: Bool, until: Double)] = [:]   // щойно надіслані команди: не даємо старим звітам «відкотити» перемикач
    var health = HealthStats()
    var session = 0   // збільшується при виході з акаунта — розриває поточне з'єднання
    private var grid: (state: Bool?, streak: Int, cand: Bool?, candTs: Double) = (nil, 0, nil, 0)
    private var lastSaved: [String: String] = [:]
    private var analyticsCache: (Double, [String: Any]?) = (0, nil)
    var lastCloudLogged: Double = 0
    private var mwCache: (Double, [String: (w: Double, history: Bool, n: Int)])? = nil
    private var chargeCache: (Double, Double?)? = nil
    var historyHandle: FileHandle?
    var cloudQueue: [(String, Any)] = []   // команди для режиму «через сервер»
    private var listener: NWListener?

    // MARK: старт

    func start() {
        migrateLegacy()
        loadConfig()
        loadHistory()
        loadHealth()
        if let d = try? Data(contentsOf: schedURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: [String: [String: Any]]] { schedStore = j }
        if let d = try? Data(contentsOf: lastURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in j where !(v is NSNull) { state[k] = v }
        }
        startServer()
        Thread { self.stationLoop() }.start()
        Thread { self.historyLoop() }.start()
        Thread { self.scheduleLoop() }.start()
        Thread { self.backfillLoop() }.start()
        log("програму запущено, дані: \(appSupport.path)")
    }

    /// Переносить ключ, історію та налаштування з попередньої версії (~/oukitel).
    private func migrateLegacy() {
        let fm = FileManager.default
        for name in ["auth.json", "config.json", "history.csv", "schedules.json", "last_state.json"] {
            let src = legacyDir.appendingPathComponent(name), dst = appSupport.appendingPathComponent(name)
            if !fm.fileExists(atPath: dst.path) && fm.fileExists(atPath: src.path) {
                try? fm.copyItem(at: src, to: dst)
                log("перенесено \(name) з ~/oukitel")
            }
        }
    }

    func cfgD(_ k: String) -> Double { lock.lock(); defer { lock.unlock() }; return (config[k] as? Double) ?? (config[k] as? Int).map(Double.init) ?? 0 }
    func cfgS(_ k: String) -> String? { lock.lock(); defer { lock.unlock() }; return config[k] as? String }

    private func loadConfig() {
        if let d = try? Data(contentsOf: configURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in j { config[k] = v }
        }
        saveConfig()
    }
    func saveConfig() {
        lock.lock(); let snap = config; lock.unlock()
        guard let d = try? JSONSerialization.data(withJSONObject: snap, options: [.prettyPrinted]) else { return }
        let url = configURL
        saveQueue.async { try? d.write(to: url, options: .atomic) }   // по черзі й атомарно — файл не обріжеться
        pushConfigToCloud()
    }

    func modeAt(_ d: Date) -> String {
        let cal = Calendar.current
        let h = cal.component(.hour, from: d)
        let night = (config["night"] as? [Int]) ?? [23, 8]
        let isNight = night[0] > night[1] ? (h >= night[0] || h < night[1]) : (h >= night[0] && h < night[1])
        if isNight { return "night" }
        let wd = (cal.component(.weekday, from: d) + 5) % 7   // Пн=0 … Нд=6
        return ((config["weekend_days"] as? [Int]) ?? [5, 6]).contains(wd) ? "weekend" : "work"
    }

    // MARK: станція

    static let knownIDs = [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 14, 20, 27, 28, 31, 34, 43, 44, 46, 100]
    /// Номери, яких немає в описі моделі — раз за з'єднання перевіряємо, чи станція щось на них відповідає.
    static let probeIDs = Array(10...99).filter { ![11, 12, 14, 20, 27, 28, 31, 34, 43, 44, 46].contains($0) }
    static let names: [Int: String] = [1: "soc", 2: "remain_min", 3: "remain_charge_min", 4: "in_w", 5: "out_w", 11: "ac_in_w",
                                       12: "dc_in_w", 14: "temp", 20: "ac_limit", 27: "freq", 28: "ac_set_v", 31: "ac_ver", 34: "bms_ver",
                                       43: "ac_on", 44: "usb_on", 46: "dc_on", 100: "hf"]
    static let sticky = ["temp", "temp_ts", "ac_on", "usb_on", "dc_on", "ac_limit", "ac_v"]
    let hfMode = 3

    private func readRequest() -> Data { var d = Data(); for i in Engine.knownIDs { d.append(contentsOf: be16(i)) }; return d }

    private func apply(_ items: [(Int, TV)]) {
        let now = Date().timeIntervalSince1970
        lock.lock()
        func setSwitch(_ k: String, _ x: Bool) {
            if let p = pendingSwitch[k], now < p.until {
                if x == p.value { pendingSwitch[k] = nil } else { return }   // старий звіт до перемикання — ігноруємо
            }
            state[k] = x
        }
        for (id, v) in items {
            switch id {
            case 6:
                let d = v.dict
                if let x = d[1]?.bool { setSwitch("ac_on", x) }
                if let x = d[2]?.double { state["ac_out_w"] = x }
                if let x = d[3]?.double { state["ac_v"] = x }
            case 7:
                let d = v.dict
                if let x = d[1]?.bool { setSwitch("usb_on", x) }
                var a = (state["usb_a"] as? [Double]) ?? [0, 0]
                if let x = d[2]?.double { a[0] = x }
                if let x = d[3]?.double { a[1] = x }
                state["usb_a"] = a
            case 8:
                let d = v.dict
                var c = (state["usb_c"] as? [Double]) ?? [0, 0, 0, 0]
                for (i, k) in [2, 5, 6, 7].enumerated() { if let x = d[k]?.double { c[i] = x } }
                state["usb_c"] = c
            case 9:
                let d = v.dict
                if let x = d[1]?.bool { setSwitch("dc_on", x) }
                if let x = d[2]?.double { state["dc_out_w"] = x }
                if let x = d[3]?.double { state["dc_v"] = x }
                if let x = d[4]?.double { state["dc_a"] = x }
            case 43, 44, 46:
                if let x = v.bool { setSwitch(Engine.names[id]!, x) }
            default:
                if let n = Engine.names[id], let x = v.double {
                    state[n] = x
                    if id == 5 { recent.append((now, x)) }
                    if id == 14 { state["temp_ts"] = now }
                } else if Engine.names[id] == nil {
                    var ex = (state["extra"] as? [String: Any]) ?? [:]
                    let desc: Any; if let d = v.double { desc = d } else if let b = v.bool { desc = b } else { desc = "\(v)" }
                    if ex["\(id)"] == nil { log("станція віддала недокументований id \(id) = \(desc)") }
                    ex["\(id)"] = desc; state["extra"] = ex
                }
            }
        }
        state["last_update"] = now
        state["connected"] = true
        state["error"] = NSNull()
        recent.removeAll { $0.0 < now - 900 }
        var sticky = [String: Any](); var sig = [String: String]()
        for k in Engine.sticky { if let v = state[k] { sticky[k] = v; sig[k] = "\(v)" } }
        let changed = sig != lastSaved
        if changed { lastSaved = sig }
        lock.unlock()
        if changed, let d = try? JSONSerialization.data(withJSONObject: sticky) { try? d.write(to: lastURL) }
    }

    private func authKey() -> (String, Data)? {
        guard let d = try? Data(contentsOf: authURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let dk = j["device_key"] as? String, let k = j["auth_key"] as? String, let key = Data(base64Encoded: k), key.count == 16 else { return nil }
        return (dk, key)
    }

    func setError(_ msg: String) {
        lock.lock(); state["connected"] = false; state["error"] = msg; lock.unlock()
    }

    private func stationLoop() {
        while true {
            do {
                guard let ak = authKey() else { setError("потрібне налаштування"); Thread.sleep(forTimeInterval: 3); continue }
                let dk = ak.0, key = ak.1
                var host = cfgS("host"), port: UInt16 = 6607
                if host == nil {
                    if let f = discover().first(where: { $0.deviceKey == dk }) {
                        host = f.host; port = f.port
                        if cfgS("last_host") != f.host { lock.lock(); config["last_host"] = f.host; lock.unlock(); saveConfig() }
                    } else if let lh = cfgS("last_host") {
                        host = lh
                    }
                }
                guard let h = host else { throw NetErr.connect("станцію не знайдено в мережі") }
                log("підключаюсь до \(h):\(port)")
                let mySession = session
                let c = try StationConn(host: h, port: port, key: key)
                try c.auth()
                lock.lock(); state["source"] = "lan"; lock.unlock()
                try c.send(19, ttlv(100, int: hfMode))
                Thread.sleep(forTimeInterval: 0.4)
                try c.send(17, readRequest())
                Thread.sleep(forTimeInterval: 0.3)
                var probe = Data(); for i in Engine.probeIDs { probe.append(contentsOf: be16(i)) }
                try c.send(17, probe)
                var lastData = Date(), lastHB = Date(), lastPoll = Date(), lastHF = Date()
                var followUp: Date? = nil
                while true {
                    if session != mySession { throw NetErr.auth("вихід з акаунта") }
                    if -lastHB.timeIntervalSinceNow > 10 {
                        try c.send(0x7039, ttlv(1, int: 30) + ttlv(2, int: 1)); try c.send(0x7037); lastHB = Date()
                    }
                    lock.lock(); let q = controlQueue; controlQueue.removeAll(); cloudQueue.removeAll(); lock.unlock()
                    for (id, payload) in q {
                        log("керування: id \(id)")
                        try c.send(19, payload)
                        try c.send(17, Data(be16(id)))          // одразу питаємо саме цей перемикач
                        followUp = Date().addingTimeInterval(1.2)
                    }
                    if let f = followUp, f <= Date() { try c.send(17, readRequest()); followUp = nil; lastPoll = Date() }
                    if -lastPoll.timeIntervalSinceNow > 15 { try c.send(17, readRequest()); lastPoll = Date() }
                    if let f = try c.recv(0.15) {
                        if [18, 20, 50].contains(f.cmd) && !f.payload.isEmpty {
                            let items = decodeTTLV(f.payload)
                            if !items.isEmpty { apply(items); lastData = Date() }
                        }
                    } else {
                        let silent = -lastData.timeIntervalSinceNow
                        if silent > 60 { throw NetErr.timeout }
                        if silent > 8 && -lastHF.timeIntervalSinceNow > 20 { try c.send(19, ttlv(100, int: hfMode)); lastHF = Date() }
                    }
                }
            } catch {
                log("зв'язок зі станцією: \(error)")
                lock.lock()
                let cloudFresh = (state["source"] as? String) == "cloud" && Date().timeIntervalSince1970 - ((state["last_update"] as? Double) ?? 0) < 60
                lock.unlock()
                if !cloudFresh { setError("\(error)") }   // поки дані з сервера свіжі — не показуємо «немає зв'язку» під час спроби Wi-Fi
            }
            if bridge() != nil && authKey() != nil { runCloud(seconds: 90) } else { Thread.sleep(forTimeInterval: 5) }
        }
    }

    /// Інформація про підключену станцію (для меню акаунта).
    func accountInfo() -> [String: String] {
        guard let d = try? Data(contentsOf: authURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return ["name": (j["name"] as? String) ?? "", "device_key": (j["device_key"] as? String) ?? "",
                "model": (config["model"] as? String) ?? "", "group": (config["group"] as? String) ?? ""]
    }

    /// Вихід з акаунта: видаляє ключ станції, обнуляє стан і повертає до першого налаштування.
    func logout() {
        DispatchQueue.global().async { self.unregisterFromServer() }
        try? FileManager.default.removeItem(at: authURL)
        lock.lock()
        session += 1
        state = ["connected": false, "error": "потрібне налаштування"]
        recent.removeAll()
        config["last_host"] = NSNull(); config["model"] = ""
        lock.unlock()
        saveConfig()
        log("вихід з акаунта")
    }

    func control(key: String, value: Any) -> Bool {
        let map: [String: Int] = ["ac": 43, "usb": 44, "dc": 46, "charge_limit": 20]
        guard let id = map[key] else { return false }
        var payload: Data
        if key == "charge_limit" {
            guard let n = (value as? Double) ?? (value as? Int).map(Double.init), n >= 3, n <= 100 else { return false }
            payload = ttlv(id, int: Int(n))
        } else {
            guard let b = value as? Bool else { return false }
            payload = ttlv(id, bool: b)
        }
        lock.lock(); defer { lock.unlock() }
        guard (state["connected"] as? Bool) == true else { return false }
        controlQueue.append((id, payload))
        cloudQueue.append((key, value))
        if let b = value as? Bool, let n = Engine.names[id] {
            state[n] = b                                                     // інтерфейс бачить новий стан одразу
            let viaCloud = (state["source"] as? String) == "cloud"
            pendingSwitch[n] = (b, Date().timeIntervalSince1970 + (viaCloud ? 25 : 6))   // через хмару підтвердження йде довше
        }
        if key == "charge_limit", let n = (value as? Double) ?? (value as? Int).map(Double.init) { state["ac_limit"] = n }
        return true
    }

    // MARK: історія та події

    private func trackGrid(_ ts: Double, _ inW: Double, _ out: Double) {
        // вхід 0 і вихід 0 (розетки вимкнені, батарея не дозаряджається) — по станції не видно, чи є світло:
        // стан не міняємо, а «світла немає» ставимо лише якщо зараз відключення за графіком
        let g: Bool
        if inW > 5 || out > 5 { g = inW > 5 }
        else if outageIntervals().contains(where: { ts >= $0.0.timeIntervalSince1970 && ts < $0.1.timeIntervalSince1970 }) { g = false }
        else { if grid.cand == false { grid.cand = nil; grid.streak = 0 }; return }
        guard let cur = grid.state else { grid.state = g; return }
        if g == cur { grid.cand = nil; grid.streak = 0; return }
        if grid.cand != g { grid.cand = g; grid.streak = 1; grid.candTs = ts } else { grid.streak += 1 }
        if grid.streak >= 3 {
            grid.state = g
            events.append(GridEvent(ts: grid.candTs, type: g ? "on" : "off"))
            if g, !(config["manual_power_on"] is NSNull), config["manual_power_on"] != nil, grid.candTs > Date().timeIntervalSince1970 - 600 {
                config["manual_power_on"] = NSNull()   // світло вже дали — ручний час більше не потрібен
                DispatchQueue.global().async { self.saveConfig() }
            }
            if events.count > 500 { events.removeFirst(events.count - 500) }
            grid.cand = nil; grid.streak = 0
        }
    }

    /// Перебудувати події «світло зникло / дали» з усієї історії (після дозаповнення з сервера).
    func rebuildEvents() {
        grid = (nil, 0, nil, 0); events.removeAll()
        for s in history { trackGrid(s.ts, s.inW, s.out) }
    }

    private func loadHistory() {
        guard let text = try? String(contentsOf: historyURL, encoding: .utf8) else { return }
        let cutoff = Date().timeIntervalSince1970 - 30 * 86400
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            let p = line.trimmingCharacters(in: .whitespaces).split(separator: ",", omittingEmptySubsequences: false)
            guard p.count >= 6, let ts = Double(p[0]), let soc = Double(p[1]), let o = Double(p[2]), let i = Double(p[3]) else { continue }
            if ts < cutoff { continue }
            history.append(Sample(ts: ts, soc: soc, out: o, inW: i, temp: Double(p[4]) ?? 0, mode: String(p[5]).trimmingCharacters(in: .whitespacesAndNewlines)))
            trackGrid(ts, i, o)
        }
        if zip(history, history.dropFirst()).contains(where: { $0.ts > $1.ts }) { history.sort { $0.ts < $1.ts }; rebuildEvents() }
        // файл росте ~0,5 МБ на добу: прибираємо записи старші за 30 днів
        let totalLines = text.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
        if totalLines > history.count + 20000 {
            let compact = history.map { "\(Int($0.ts)),\($0.soc),\($0.out),\($0.inW),\($0.temp),\($0.mode)\n" }.joined()
            try? compact.data(using: .utf8)?.write(to: historyURL, options: .atomic)
            log("історія: стиснуто файл до \(history.count) записів")
        }
        log("історія: \(history.count) записів")
    }

    private func historyLoop() {
        if !FileManager.default.fileExists(atPath: historyURL.path) { FileManager.default.createFile(atPath: historyURL.path, contents: nil) }
        historyHandle = try? FileHandle(forWritingTo: historyURL)
        historyHandle?.seekToEndOfFile()
        while true {
            Thread.sleep(forTimeInterval: 10)
            lock.lock()
            let now = Date().timeIntervalSince1970
            guard let lu = state["last_update"] as? Double, now - lu < 30, let soc = state["soc"] as? Double, let out = state["out_w"] as? Double else { lock.unlock(); continue }
            var ts = now
            if (state["source"] as? String) == "cloud" {   // через сервер: та сама відповідь не пишеться кілька разів
                guard let cu = state["cloud_upd"] as? Double, cu > lastCloudLogged else { lock.unlock(); continue }
                lastCloudLogged = cu; ts = cu
            }
            let s = Sample(ts: ts, soc: soc, out: out, inW: (state["in_w"] as? Double) ?? 0, temp: (state["temp"] as? Double) ?? 0, mode: modeAt(Date()))
            history.append(s)
            trackGrid(s.ts, s.inW, s.out)
            updateHealth(ts: s.ts, soc: s.soc, out: s.out, temp: state["temp"] as? Double)
            if history.count > 30 * 8640 { history.removeFirst(history.count - 30 * 8640) }
            let line = "\(Int(s.ts)),\(s.soc),\(s.out),\(s.inW),\(s.temp),\(s.mode)\n"
            historyHandle?.write(line.data(using: .utf8)!)
            lock.unlock()
        }
    }

    func modeWatts() -> [String: (w: Double, history: Bool, n: Int)] {
        if let c = mwCache, Date().timeIntervalSince1970 - c.0 < 60 { return c.1 }
        let r = modeWattsRaw(); mwCache = (Date().timeIntervalSince1970, r); return r
    }
    private func modeWattsRaw() -> [String: (w: Double, history: Bool, n: Int)] {
        let cutoff = Date().timeIntervalSince1970 - 14 * 86400
        let fb = (config["fallback_watts"] as? [String: Any]) ?? [:]
        var res = [String: (w: Double, history: Bool, n: Int)]()
        for m in ["work", "night", "weekend"] {
            let vals = history.filter { $0.mode == m && $0.ts >= cutoff }.map { $0.out }
            if vals.count >= 30 { res[m] = (median(vals), true, vals.count) }
            else { res[m] = ((fb[m] as? Double) ?? (fb[m] as? Int).map(Double.init) ?? 100, false, vals.count) }
        }
        return res
    }

    func learnedChargeW() -> Double? {
        if let c = chargeCache, Date().timeIntervalSince1970 - c.0 < 60 { return c.1 }
        let vals = history.suffix(8640 * 7).map { $0.inW - $0.out }.filter { $0 > 100 }
        let r = vals.count >= 30 ? median(vals) : nil
        chargeCache = (Date().timeIntervalSince1970, r); return r
    }

    // MARK: графік Yasno

    func parseDay(_ day: [String: Any]?) -> [String: Any]? {
        guard let day = day, let ds = day["date"] as? String else { return nil }
        let key = String(ds.prefix(10))
        var off = [[Any]]()
        for s in (day["slots"] as? [[String: Any]]) ?? [] {
            let typ = (s["type"] as? String) ?? "Definite"
            if ["notplanned", "none", "on"].contains(typ.lowercased()) { continue }
            func mins(_ v: Any?) -> Double { let x = (v as? Double) ?? (v as? Int).map(Double.init) ?? 0; return x <= 24 ? x * 60 : x }
            let a = mins(s["start"]), b = mins(s["end"])
            if b > a { off.append([a, b, typ]) }
        }
        return ["date": key, "status": day["status"] ?? NSNull(), "off": off] as [String: Any]
    }

    private func scheduleLoop() {
        while true {
            let grp = cfgS("group").flatMap { $0.isEmpty ? nil : $0 }
            let url = URL(string: "https://app.yasno.ua/api/blackout-service/public/shutdowns/regions/\(Int(cfgD("region_id")))/dsos/\(Int(cfgD("dso_id")))/planned-outages")!
            var req = URLRequest(url: url); req.timeoutInterval = 20
            req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)", forHTTPHeaderField: "User-Agent")
            let sem = DispatchSemaphore(value: 0)
            var result: [String: Any]? = nil; var errText: String? = nil
            URLSession.shared.dataTask(with: req) { d, _, e in
                if let d = d, let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { result = j } else { errText = e?.localizedDescription ?? "погана відповідь" }
                sem.signal()
            }.resume()
            sem.wait()
            lock.lock()
            if let data = result {
                let groups = data.keys.sorted { a, b in
                    let pa = a.split(separator: ".").compactMap { Int($0) }, pb = b.split(separator: ".").compactMap { Int($0) }
                    return pa.lexicographicallyPrecedes(pb)
                }
                var cands = Set((config["group_candidates"] as? [String]) ?? []); if let g = grp { cands.insert(g) }
                for cg in cands {
                    guard let gd = data[cg] as? [String: Any] else { continue }
                    for k in ["today", "tomorrow"] {
                        if let d = parseDay(gd[k] as? [String: Any]), let key = d["date"] as? String {
                            schedStore[cg, default: [:]][key] = ["status": d["status"]!, "off": d["off"]!]
                        }
                    }
                }
                if let g = grp, let gd = data[g] as? [String: Any] {
                    schedule = ["ok": true, "group": g, "groups": groups, "updated": gd["updatedOn"] ?? NSNull(),
                                "today": nn(parseDay(gd["today"] as? [String: Any])),
                                "tomorrow": nn(parseDay(gd["tomorrow"] as? [String: Any])),
                                "fetched": Date().timeIntervalSince1970]
                } else {
                    schedule = ["ok": false, "groups": groups, "error": grp == nil ? "групу не вказано" : "групи \(grp!) немає у графіку"]
                }
                let store = schedStore
                lock.unlock()
                if let d = try? JSONSerialization.data(withJSONObject: store) { try? d.write(to: schedURL) }
            } else {
                schedule["error"] = "не вдалося оновити: \(errText ?? "")"
                lock.unlock()
                log("графік Yasno: \(errText ?? "")")
            }
            let rid = cfgD("region_id")
            for _ in 0..<900 { Thread.sleep(forTimeInterval: 1); if cfgS("group").flatMap({ $0.isEmpty ? nil : $0 }) != grp || cfgD("region_id") != rid { break } }
        }
    }

    func outageIntervals() -> [(Date, Date)] {
        var res = [(Date, Date)]()
        guard (schedule["ok"] as? Bool) == true else { return res }
        for k in ["today", "tomorrow"] {
            guard let d = schedule[k] as? [String: Any], let key = d["date"] as? String, let base = startOfDay(key) else { continue }
            // «стінний» час: у дні переходу на літній/зимовий час проста сума хвилин дала б зсув на годину
            func at(_ m: Double) -> Date {
                let mins = Int(m), cal = Calendar.current
                let day = cal.date(byAdding: .day, value: mins / 1440, to: base) ?? base
                return cal.date(bySettingHour: (mins % 1440) / 60, minute: mins % 60, second: 0, of: day) ?? base.addingTimeInterval(m * 60)
            }
            for slot in (d["off"] as? [[Any]]) ?? [] {
                guard slot.count >= 2, let a = slot[0] as? Double, let b = slot[1] as? Double else { continue }
                res.append((at(a), at(b)))
            }
        }
        res.sort { $0.0 < $1.0 }
        var merged = [(Date, Date)]()
        for iv in res {
            if let last = merged.last, iv.0 <= last.1 { merged[merged.count - 1] = (last.0, max(last.1, iv.1)) } else { merged.append(iv) }
        }
        return merged
    }

    func groupMatch() -> [String: Any] {
        var res = [String: Any](); var ranked = [(String, Int, Int)]()
        for g in (config["group_candidates"] as? [String]) ?? [] {
            var hit = 0, tried = 0
            for e in events.suffix(60) {
                let t = Date(timeIntervalSince1970: e.ts), key = dayKey(t)
                guard let day = schedStore[g]?[key], (day["status"] as? String) == "ScheduleApplies", let base = startOfDay(key) else { continue }
                tried += 1
                let edges = ((day["off"] as? [[Any]]) ?? []).compactMap { s -> Date? in
                    guard s.count >= 2, let a = s[0] as? Double, let b = s[1] as? Double else { return nil }
                    return base.addingTimeInterval((e.type == "off" ? a : b) * 60)
                }
                if edges.contains(where: { abs($0.timeIntervalSince(t)) <= 1800 }) { hit += 1 }
            }
            res[g] = ["hits": hit, "tried": tried]; ranked.append((g, hit, tried))
        }
        ranked.sort { $0.1 > $1.1 }
        if ranked.count >= 2, (config["group_confirmed"] as? Bool) != true, ranked[0].1 >= 3, ranked[0].1 >= 2 * max(1, ranked[1].1) {
            config["group"] = ranked[0].0; config["group_confirmed"] = true
            DispatchQueue.global().async { self.saveConfig() }
            log("групу визначено за відключеннями: \(ranked[0].0)")
        }
        return res
    }

    // MARK: аналітика

    func analytics() -> [String: Any] {
        let nowTs = Date().timeIntervalSince1970
        if nowTs - analyticsCache.0 < 60, let c = analyticsCache.1 { return c }
        let rows = history.filter { $0.ts > nowTs - 8 * 86400 }
        let cal = Calendar.current, today = Date()
        var days = [(String, Double, Double)]()
        for i in stride(from: 6, through: 0, by: -1) { days.append((dayKey(cal.date(byAdding: .day, value: -i, to: today)!), 0, 0)) }
        var hours = [[Double]](repeating: [], count: 24)
        var inWh = 0.0, outWh = 0.0, peak = 0.0, gridMin = 0.0, offMin = 0.0, lastG = true
        var minSoc: Double? = nil, maxSoc: Double? = nil
        var prev: Double? = nil
        let todayKey = dayKey(today)
        for r in rows {
            let step = prev.map { min(60, r.ts - $0) } ?? 10; prev = r.ts
            let t = Date(timeIntervalSince1970: r.ts), key = dayKey(t)
            if let idx = days.firstIndex(where: { $0.0 == key }) { days[idx].1 += r.inW * step / 3600; days[idx].2 += r.out * step / 3600 }
            if r.ts > nowTs - 7 * 86400 { hours[cal.component(.hour, from: t)].append(r.out) }
            if key == todayKey {
                inWh += r.inW * step / 3600; outWh += r.out * step / 3600; peak = max(peak, r.out)
                minSoc = min(minSoc ?? r.soc, r.soc); maxSoc = max(maxSoc ?? r.soc, r.soc)
                if r.inW > 5 || r.out > 5 { lastG = r.inW > 5 }   // 0/0 — стан не видно, лишаємо попередній
                if lastG { gridMin += step / 60 } else { offMin += step / 60 }
            }
        }
        let data: [String: Any] = [
            "days": days.map { ["date": $0.0, "in_wh": $0.1.rounded(), "out_wh": $0.2.rounded()] as [String: Any] },
            "hours": hours.map { $0.isEmpty ? NSNull() as Any : mean($0).rounded() as Any },
            "today": ["in_wh": r1(inWh), "out_wh": r1(outWh), "peak_w": r1(peak), "min_soc": nn(minSoc), "max_soc": nn(maxSoc),
                      "grid_min": r1(gridMin), "off_min": r1(offMin)] as [String: Any],
        ]
        analyticsCache = (nowTs, data)
        return data
    }

    // MARK: розрахунки (порт compute() з Python-версії)

    func compute() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        let now = Date(), nowTs = now.timeIntervalSince1970
        let s = state
        let cap = cfgD("capacity_wh") > 0 ? cfgD("capacity_wh") : 2048, eff = cfgD("inverter_efficiency"), reserve = cfgD("reserve_percent"), chEff = cfgD("charge_efficiency")
        var out: [String: Any] = ["now": isoSec(now), "station": s, "schedule": schedule,
                                  "config": ["group": config["group"] ?? NSNull(), "capacity_wh": cap, "reserve_percent": reserve,
                                             "manual_power_on": config["manual_power_on"] ?? NSNull(), "night": config["night"] ?? [23, 8]] as [String: Any]]
        out["setup"] = setupInfo()
        guard let soc = s["soc"] as? Double else { out["ready"] = false; return out }
        out["ready"] = true
        let usableWh = max(0, soc - reserve) / 100 * cap * eff
        out["usable_wh"] = usableWh.rounded(); out["stored_wh"] = (soc / 100 * cap).rounded()
        let w5 = recent.filter { $0.0 > nowTs - 300 }.map { $0.1 }
        let nowW = w5.isEmpty ? ((s["out_w"] as? Double) ?? 0) : mean(w5)
        out["now_w"] = nowW.rounded()
        let inW = (s["in_w"] as? Double) ?? 0, idle = inW <= 5 && ((s["out_w"] as? Double) ?? 0) <= 5
        let grid = inW > 5 || (idle && self.grid.state == true)
        out["grid"] = grid; out["idle"] = idle && grid
        let mw = modeWatts(), curMode = modeAt(now)

        var scen: [[String: Any]] = [["key": "now", "name": "Як зараз", "w": nowW, "src": "середнє за 5 хв"]]
        for (k, nm) in [("work", "Робота"), ("night", "Ніч"), ("weekend", "Вихідні")] {
            let m = mw[k]!
            scen.append(["key": k, "name": nm, "w": m.w, "src": m.history ? "медіана, \(m.n / 6) хв історії" : "типово (ще вчиться)", "current": k == curMode] as [String: Any])
        }
        scen = scen.map { var x = $0; let w = x["w"] as! Double; x["hours"] = nn(w > 1 ? usableWh / w : nil); x["w"] = w.rounded(); return x }

        var simWh = usableWh, t = now, first = true
        while simWh > 0 && t < now.addingTimeInterval(7 * 86400) {
            let m = modeAt(t)
            let w = (first && m == curMode) ? nowW : mw[m]!.w
            if m != curMode { first = false }
            simWh -= max(w, 1) * 300 / 3600; t = t.addingTimeInterval(300)
        }
        out["runout_at"] = nn(simWh <= 0 ? isoMin(t) : nil)

        let ivs = outageIntervals()
        let cur = ivs.first { $0.0 <= now && now < $0.1 }, nxt = ivs.first { $0.0 > now }
        var powerOn: Date? = nil
        if !grid {
            if let m = cfgS("manual_power_on") {
                let p = m.split(separator: ":").compactMap { Int($0) }
                if p.count == 2, var d = Calendar.current.date(bySettingHour: p[0], minute: p[1], second: 0, of: now) {
                    if d <= now { d = d.addingTimeInterval(86400) }; powerOn = d
                }
            } else if let c = cur { powerOn = c.1 }
        }
        out["power_on_at"] = nn(powerOn.map { isoMin($0) })
        out["next_off"] = nn(nxt.map { [isoMin($0.0), isoMin($0.1)] })
        let chargeW = learnedChargeW() ?? cfgD("max_ac_charge_w") * (((s["ac_limit"] as? Double) ?? 100) / 100)
        out["charge_w"] = chargeW.rounded()
        func hoursToFull(_ pct: Double) -> Double { (100 - pct) / 100 * cap / (chargeW * chEff) }

        if !grid, let po = powerOn {
            let hrs = po.timeIntervalSince(now) / 3600
            let budget: Double? = hrs > 0 ? usableWh / hrs : nil
            let endSoc = soc - (nowW * hrs / eff) / cap * 100
            out["budget"] = ["until": isoMin(po), "hours": hrs, "avg_w": nn(budget.map { $0.rounded() }),
                             "soc_at_on": r1(max(0, endSoc)), "enough": endSoc > reserve] as [String: Any]
            let after = ivs.first { $0.0 > po }
            let startSoc = max(0, endSoc)
            let fullAt = po.addingTimeInterval(hoursToFull(startSoc) * 3600)
            out["recharge"] = ["start_soc": startSoc.rounded(), "full_at": isoMin(fullAt),
                               "next_off": nn(after.map { isoMin($0.0) }), "ok": after == nil || fullAt <= after!.0] as [String: Any]
        } else if grid {
            let fullAt = soc < 99.5 ? now.addingTimeInterval(hoursToFull(soc) * 3600) : now
            var rc: [String: Any] = ["full_at": isoMin(fullAt), "charging": inW > nowW + 20]
            if let n = nxt {
                let hrs = n.0.timeIntervalSince(now) / 3600
                let socThen = min(100, soc + hrs * chargeW * chEff / cap * 100)
                rc["next_off"] = isoMin(n.0); rc["ok"] = fullAt <= n.0; rc["soc_at_off"] = socThen.rounded()
                let dur = n.1.timeIntervalSince(n.0) / 3600
                rc["off_hours"] = dur
                rc["off_budget_w"] = nn(dur > 0 ? ((socThen - reserve) / 100 * cap * eff / dur).rounded() : nil)
            }
            out["recharge"] = rc
        }
        out["scenarios"] = scen
        out["health"] = healthReport(soc: soc, grid: grid, charging: grid && inW > nowW + 20, nowW: nowW,
                                     nextOff: nxt.map { ($0.0, $0.1) }, chargeW: chargeW, capWh: cap)
        out["mode"] = curMode
        out["charging"] = grid && inW > nowW + 20
        out["net_w"] = (inW - ((s["out_w"] as? Double) ?? 0)).rounded()
        out["events"] = events.suffix(12).reversed().map { ["ts": $0.ts, "type": $0.type] as [String: Any] }
        out["analytics"] = analytics()
        out["mode_watts"] = ["work": mw["work"]!.w.rounded(), "night": mw["night"]!.w.rounded(), "weekend": mw["weekend"]!.w.rounded()]
        out["group_info"] = ["group": config["group"] ?? NSNull(), "confirmed": config["group_confirmed"] ?? false, "candidates": groupMatch()] as [String: Any]
        out["lan_url"] = nn(lanIP().map { "http://\($0):\(port)" })
        out["setup"] = setupInfo()
        var pts = [[Double]](); var bucket = -1
        for r in history where r.ts > nowTs - 86400 {
            let b = Int(r.ts / 60)
            if b != bucket { pts.append([r.ts.rounded(), r.soc, r.out.rounded(), r.inW.rounded()]); bucket = b }
        }
        out["series"] = pts
        return out
    }

    func updateConfig(_ data: [String: Any]) -> Bool {
        let allowed: Set<String> = ["group", "manual_power_on", "reserve_percent", "night", "fallback_watts", "group_confirmed",
                                    "capacity_wh", "region_id", "dso_id", "region_name", "setup_skipped_group"]
        // перевірка значень: погані дані тут роблять збій при кожному запуску
        func num(_ v: Any) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) }
        if let v = data["capacity_wh"], (num(v).map { !(100...20000).contains($0) } ?? true) { return false }
        if let v = data["reserve_percent"], (num(v).map { !(0...90).contains($0) } ?? true) { return false }
        if let v = data["night"] { guard let a = v as? [Int], a.count == 2, a.allSatisfy({ (0...23).contains($0) }) else { return false } }
        if let v = data["weekend_days"] { guard let a = v as? [Int], a.allSatisfy({ (0...6).contains($0) }) else { return false } }
        lock.lock()
        for (k, v) in data where allowed.contains(k) {
            if k == "manual_power_on" {
                if let str = v as? String, !str.isEmpty {
                    let p = str.split(separator: ":").compactMap { Int($0) }
                    guard p.count == 2, (0..<24).contains(p[0]), (0..<60).contains(p[1]) else { lock.unlock(); return false }
                    config[k] = String(format: "%02d:%02d", p[0], p[1])
                } else { config[k] = NSNull() }
            } else { config[k] = v }
        }
        lock.unlock()
        saveConfig()
        return true
    }

    // MARK: вбудований веб-сервер (сторінка дашборда + API)

    private func startServer() {
        listener?.cancel(); listener = nil
        do {
            let l = try NWListener(using: .tcp, on: NWEndpoint.Port(rawValue: port)!)
            l.newConnectionHandler = { [weak self] conn in
                conn.start(queue: .global())
                self?.receive(conn, Data())
            }
            l.stateUpdateHandler = { [weak self] st in
                if case .failed(let e) = st {
                    log("веб-сервер: \(e) — повтор через 3 с")
                    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { self?.startServer() }
                } else if case .ready = st { log("веб-сервер працює на порту \(self?.port ?? 0)") }
            }
            l.start(queue: .global())
            listener = l
        } catch {
            log("не вдалося запустити веб-сервер: \(error) — повтор через 3 с")
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in self?.startServer() }
        }
    }

    private func receive(_ conn: NWConnection, _ acc: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, err in
            guard let self = self else { return }
            var buf = acc; if let d = data { buf.append(d) }
            if let req = self.parseHTTP(buf) {
                // запити з чужих сайтів (Origin не збігається з адресою сервера) не виконуємо
                if let o = req.3["origin"], !Engine.sameOrigin(o, host: req.3["host"] ?? "") {
                    let resp = Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() }); return
                }
                self.respond(conn, req.0, req.1, req.2); return
            }
            if done || err != nil || buf.count > 1_000_000 { conn.cancel(); return }
            self.receive(conn, buf)
        }
    }

    /// Origin "http://localhost:8765" має збігатися з Host "localhost:8765" (інакше це запит із чужого сайту).
    static func sameOrigin(_ origin: String, host: String) -> Bool {
        guard let u = URL(string: origin), let h = u.host else { return false }
        return (u.port.map { "\(h):\($0)" } ?? h) == host
    }

    private func parseHTTP(_ d: Data) -> (String, String, Data, [String: String])? {
        guard let r = d.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: d[..<r.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return ("GET", "/", Data(), [:]) }
        var hdr = [String: String]()
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            hdr[l[..<c].lowercased().trimmingCharacters(in: .whitespaces)] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let len = min(max(Int(hdr["content-length"] ?? "") ?? 0, 0), 1_000_000)
        let body = d[r.upperBound...]
        if body.count < len { return nil }
        return (String(parts[0]), String(parts[1]), Data(body.prefix(len)), hdr)
    }

    private func respond(_ conn: NWConnection, _ method: String, _ rawPath: String, _ body: Data) {
        let path = String(rawPath.split(separator: "?").first ?? "/")
        var code = 200, type = "application/json; charset=utf-8", payload = Data("{}".utf8)
        if method == "GET" && (path == "/" || path == "/index.html") {
            type = "text/html; charset=utf-8"
            if let u = Bundle.main.url(forResource: "dashboard", withExtension: "html"), let d = try? Data(contentsOf: u) { payload = d } else { code = 500 }
        } else if method == "GET" && (path == "/panel" || path == "/panel.html") {
            type = "text/html; charset=utf-8"
            if let u = Bundle.main.url(forResource: "panel", withExtension: "html"), let d = try? Data(contentsOf: u) { payload = d } else { code = 500 }
        } else if method == "GET" && path.hasPrefix("/assets/") {
            let name = String(path.dropFirst("/assets/".count))
            let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
            if !name.contains("/"), let u = Bundle.main.url(forResource: base, withExtension: ext), let d = try? Data(contentsOf: u) {
                payload = d; type = ext == "png" ? "image/png" : ext == "svg" ? "image/svg+xml" : "application/octet-stream"
            } else { code = 404 }
        } else if method == "GET" && path.hasPrefix("/api/state") {
            payload = (try? JSONSerialization.data(withJSONObject: sanitize(compute()))) ?? payload
        } else if method == "POST" && path.hasPrefix("/api/control") {
            let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if let k = j["key"] as? String, let v = j["value"], control(key: k, value: v) { payload = Data(#"{"ok":true}"#.utf8) }
            else { code = 400; payload = Data(#"{"error":"bad control"}"#.utf8) }
        } else if path.hasPrefix("/api/setup/") {
            let q = queryItems(rawPath)
            let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            let (c, obj) = Setup.handle(path: path, query: q, body: j, engine: self)
            code = c; payload = (try? JSONSerialization.data(withJSONObject: sanitize(obj))) ?? payload
        } else if method == "POST" && path.hasPrefix("/api/config") {
            let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
            if updateConfig(j) { payload = Data(#"{"ok":true}"#.utf8) } else { code = 400 }
        } else { code = 404 }
        let status = [200: "OK", 400: "Bad Request", 404: "Not Found", 500: "Error"][code] ?? "OK"
        var resp = Data("HTTP/1.1 \(code) \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8)
        resp.append(payload)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    func setupInfo() -> [String: Any] {
        ["has_key": authKey() != nil, "group": config["group"] ?? "", "region_id": config["region_id"] ?? 25,
         "region_name": config["region_name"] ?? "", "model": config["model"] ?? "", "capacity_wh": cfgD("capacity_wh"),
         "skipped_group": config["setup_skipped_group"] ?? false, "server": Engine.sharedServer] as [String: Any]
    }

    func queryItems(_ raw: String) -> [String: String] {
        var r = [String: String]()
        for it in URLComponents(string: "http://x" + raw)?.queryItems ?? [] { r[it.name] = it.value ?? "" }
        return r
    }

    /// JSONSerialization не приймає NaN/нескінченність і нестандартні типи.
    private func sanitize(_ v: Any) -> Any {
        if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        switch v {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let a as [Any]: return a.map(sanitize)
        case let m as [String: Any]: return m.mapValues(sanitize)
        case is String, is Bool, is Int, is NSNull, is NSNumber: return v
        default: return "\(v)"
        }
    }
}
