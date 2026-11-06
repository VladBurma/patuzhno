// Cloud.swift — хмарний міст (Cloudflare): дані й керування, коли станції немає в локальній мережі,
// і дозаповнення історії за час, поки ноут був вимкнений чи не вдома.
import Foundation

extension Engine {
    var bridgeURL: URL { appSupport.appendingPathComponent("cloud_bridge.json") }

    func bridge() -> (url: String, key: String)? {
        guard let d = try? Data(contentsOf: bridgeURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let u = j["url"] as? String, let k = j["key"] as? String, !u.isEmpty, !k.isEmpty else { return nil }
        return (u, k)
    }

    /// Синхронний запит до мосту.
    func bridgeCall(_ path: String, body: [String: Any]? = nil, timeout: Double = 15) -> (Int, [String: Any]?) {
        guard let b = bridge(), let url = URL(string: b.url + path) else { return (0, nil) }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        req.setValue(b.key, forHTTPHeaderField: "X-Key")
        if let body = body {
            req.httpMethod = "POST"; req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let sem = DispatchSemaphore(value: 0); var res: (Int, [String: Any]?) = (0, nil)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            res = ((r as? HTTPURLResponse)?.statusCode ?? 0, d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            sem.signal()
        }.resume()
        sem.wait()
        return res
    }

    /// Режим «через сервер»: працює до `seconds`, потім повертає керування, щоб знову спробувати Wi-Fi.
    func runCloud(seconds: Double) {
        guard bridge() != nil else { return }
        let end = Date().addingTimeInterval(seconds), mySession = session
        log("станції немає в мережі — працюю через хмарний сервер")
        var lastLive = Date.distantPast
        while Date() < end && session == mySession {
            lock.lock(); let q = cloudQueue; cloudQueue.removeAll(); controlQueue.removeAll(); lock.unlock()
            for (k, v) in q {
                let (code, _) = bridgeCall("/api/control", body: ["key": k, "value": v])
                log("керування через сервер: \(k)=\(v) → \(code)")
                lastLive = .distantPast
            }
            if -lastLive.timeIntervalSinceNow >= 3 {
                let (code, j) = bridgeCall("/api/live")
                lastLive = Date()
                if code == 200, let j = j { applyCloud(j) }
                else if code == 0 { setError("немає інтернету"); return }
                else { setError("сервер: помилка \(code)"); return }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    private func applyCloud(_ j: [String: Any]) {
        let now = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        state["source"] = "cloud"
        if (j["need_login"] as? Bool) == true {
            state["connected"] = false; state["error"] = "сервер: потрібно заново увійти в Wonderfree (правий клік по іконці → «Увійти в Wonderfree знову…»)"; return
        }
        guard let st = j["state"] as? [String: Any], let upd = (j["updated"] as? Double) ?? (j["updated"] as? Int).map(Double.init) else {
            state["connected"] = false; state["error"] = "сервер ще не отримав даних"; return
        }
        let online = (j["online"] as? Bool) ?? true
        for (k, v) in st {
            if ["ac_on", "usb_on", "dc_on"].contains(k), let b = v as? Bool {
                if let p = pendingSwitch[k], now < p.until { if b == p.value { pendingSwitch[k] = nil } else { continue } }
                state[k] = b
            } else { state[k] = v }
        }
        if let o = st["out_w"] as? Double, upd > (state["last_update"] as? Double ?? 0) { recent.append((upd, o)) }
        state["cloud_upd"] = upd
        let fresh = online && now - upd < 120
        state["last_update"] = fresh ? max(upd, now - 25) : upd
        state["connected"] = fresh
        state["error"] = fresh ? NSNull() : (online ? "сервер: дані застаріли" : "станція не на зв'язку з хмарою")
    }

    // MARK: дозаповнення історії

    func backfillLoop() {
        Thread.sleep(forTimeInterval: 20)
        while true {
            if bridge() != nil { backfill() }
            Thread.sleep(forTimeInterval: 300)
        }
    }

    private func backfill() {
        lock.lock()
        let since = max(cfgD("backfill_until"), Date().timeIntervalSince1970 - 30 * 86400) - 600
        lock.unlock()
        let (code, j) = bridgeCall("/api/history?since=\(Int(since))", timeout: 60)
        guard code == 200, let rows = j?["samples"] as? [[Any]], !rows.isEmpty else { return }
        let cloud: [(Double, Double, Double, Double, Double)] = rows.compactMap { r in
            let d = r.map { ($0 as? Double) ?? ($0 as? Int).map(Double.init) ?? 0 }
            return d.count >= 5 ? (d[0], d[1], d[2], d[3], d[4]) : nil
        }
        guard let first = cloud.first?.0, let last = cloud.last?.0 else { return }
        lock.lock()
        var have = Set<Int>()
        for s in history where s.ts >= first - 20 && s.ts <= last + 20 { have.insert(Int(s.ts / 10)) }
        var added: [Sample] = []
        for c in cloud {
            let b = Int(c.0 / 10)
            if have.contains(b) || have.contains(b - 1) || have.contains(b + 1) { continue }
            added.append(Sample(ts: c.0, soc: c.1, out: c.2, inW: c.3, temp: c.4, mode: modeAt(Date(timeIntervalSince1970: c.0))))
            have.insert(b)
        }
        if !added.isEmpty {
            history.append(contentsOf: added)
            history.sort { $0.ts < $1.ts }
            // цикли батареї за пропущений час
            var h = health
            func index(of ts: Double) -> Int {   // двійковий пошук у відсортованій історії
                var lo = 0, hi = history.count - 1
                while lo < hi { let mid = (lo + hi) / 2; if history[mid].ts < ts { lo = mid + 1 } else { hi = mid } }
                return lo
            }
            for a in added {
                let i = index(of: a.ts)
                guard i > 0, i < history.count else { continue }
                let d = a.soc - history[i - 1].soc
                if d < 0 && d > -20 { h.dischargedPct += -d } else if d > 0 && d < 20 { h.chargedPct += d }
                if a.soc >= 99.5 { h.lastFullTs = max(h.lastFullTs ?? 0, a.ts) }
                if a.soc <= 20 { h.lastLowTs = max(h.lastLowTs ?? 0, a.ts) }
                if a.temp != 0 { h.maxTemp = max(h.maxTemp ?? a.temp, a.temp) }
                if a.out > h.peakOutW { h.peakOutW = a.out; h.peakOutTs = a.ts }
            }
            // калібрування (≤20% → 100%) могло статися, поки програма не бачила станцію — перераховуємо з усієї історії
            var minSinceFull: Double? = nil
            for x in history {
                if x.soc >= 99.5 { if let m = minSinceFull, m <= 20 { h.lastCalibTs = max(h.lastCalibTs ?? 0, x.ts) }; minSinceFull = x.soc }
                else { minSinceFull = min(minSinceFull ?? x.soc, x.soc) }
            }
            h.lowSinceFull = minSinceFull
            health = h
            rebuildEvents()
            let text = added.map { "\(Int($0.ts)),\($0.soc),\($0.out),\($0.inW),\($0.temp),\($0.mode)\n" }.joined()
            historyHandle?.write(text.data(using: .utf8)!)
        }
        config["backfill_until"] = last
        lock.unlock()
        saveConfig(); saveHealth()
        if !added.isEmpty { log("історія: дозаповнено \(added.count) записів із сервера") }
    }

    // MARK: налаштування → сервер

    /// Група відключень, ємність і режими мають бути однакові на Mac і на сервері (для графіка й сповіщень).
    func pushConfigToCloud() {
        guard bridge() != nil else { return }
        let keys = ["group", "region_id", "dso_id", "capacity_wh", "reserve_percent", "night", "weekend_days", "fallback_watts", "model"]
        var body = [String: Any]()
        for k in keys { if let v = config[k], !(v is NSNull) { body[k] = v } }
        guard let d = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), let sig = String(data: d, encoding: .utf8) else { return }
        let key = "cloudConfigSig"
        if UserDefaults.standard.string(forKey: key) == sig { return }
        DispatchQueue.global().async {
            let (code, _) = self.bridgeCall("/api/config", body: body)
            if code == 200 { UserDefaults.standard.set(sig, forKey: key); log("налаштування передано на сервер") }
        }
    }

    // MARK: спільний сервер

    /// Адреса вашого сервера (Cloudflare Worker). Береться з Info.plist (ключ PatuzhnoServer), куди її записує build_app.command з файлу server.url.
    static let sharedServer: String = ((Bundle.main.object(forInfoDictionaryKey: "PatuzhnoServer") as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

    /// Після входу в Wonderfree у програмі: реєстрація на спільному сервері (хмара, Telegram, панель на телефоні).
    func registerWithServer(tokens: [String: Any], deviceKey: String) {
        let base = bridge()?.url ?? Engine.sharedServer
        guard !base.isEmpty else { log("хмарний сервер не налаштовано (server.url) — працюю лише по Wi-Fi"); return }
        guard let url = URL(string: base + "/api/register") else { return }
        var body: [String: Any] = ["tokens": tokens, "device": ["dk": deviceKey]]
        if let k = bridge()?.key { body["key"] = k }   // повторний вхід того самого користувача — зберігаються історія, Telegram і посилання
        var cfg = [String: Any]()
        for k in ["group", "region_id", "dso_id", "capacity_wh", "reserve_percent", "night", "weekend_days", "fallback_watts", "model"] {
            if let v = config[k], !(v is NSNull) { cfg[k] = v }
        }
        body["config"] = cfg
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 40
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let sem = DispatchSemaphore(value: 0); var res: [String: Any]? = nil; var code = 0
        URLSession.shared.dataTask(with: req) { d, r, _ in
            code = (r as? HTTPURLResponse)?.statusCode ?? 0
            res = d.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            sem.signal()
        }.resume()
        sem.wait()
        guard code == 200, let key = res?["key"] as? String else {
            let msg = res?["error"] as? String ?? (code == 0 ? "немає інтернету" : "помилка \(code)")
            log("спільний сервер: реєстрація не вдалася (\(code)) \(msg)")
            lock.lock(); state["cloud_error"] = msg; lock.unlock()
            return
        }
        lock.lock(); state["cloud_error"] = NSNull(); lock.unlock()
        if let d = try? JSONSerialization.data(withJSONObject: ["url": base, "key": key], options: [.prettyPrinted]) {
            try? d.write(to: bridgeURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: bridgeURL.path)
        }
        UserDefaults.standard.removeObject(forKey: "cloudConfigSig")
        log("спільний сервер: підключено")
    }

    /// Посилання на Telegram-бота й панель на телефоні для цього користувача.
    func serverMe() -> [String: Any]? {
        let (code, j) = bridgeCall("/api/me")
        return code == 200 ? j : nil
    }

    /// Вихід з акаунта: прибрати свої дані зі спільного сервера.
    func unregisterFromServer() {
        guard bridge() != nil else { return }
        _ = bridgeCall("/api/unregister", body: [:])
        try? FileManager.default.removeItem(at: bridgeURL)
    }
}
