// Setup.swift — перше налаштування: вхід у Wonderfree (отримання ключа станції) і пошук групи відключень за адресою.
import Foundation
import CryptoKit

enum Setup {
    struct Region { let base: String; let domain: String; let secret: String }
    static let clouds: [String: Region] = [
        "eu": Region(base: "https://iot-api.acceleronix.io", domain: "E.SP.4294967410", secret: "3aRNUwWahjyANa7WfBK2wCCkxCexB6nXxKJwXxfePvzf"),
        "na": Region(base: "https://iot-api.landecia.com", domain: "U.SP.8589934603", secret: "pUTp5goB1bLinprRQMmK3EPiiuPiGrJtKUNptWRXVmP"),
    ]
    static let yasnoRegions: [[String: Any]] = [
        ["region_id": 25, "dso_id": 902, "name": "Київ"],
    ]
    /// Ємність за назвою моделі (Вт·год). Для невідомих моделей користувач вводить вручну.
    static let capacities: [(String, Double)] = [("P2001-PLUS", 2048), ("P2001PLUS", 2048), ("P5000", 5120), ("P2001", 2000), ("P1201", 960), ("P800", 512)]
    static var pendingDevices: [[String: Any]] = []
    static var lastTokens: [String: Any]? = nil   // ключ сесії Wonderfree з останнього входу (для спільного сервера)

    static func http(_ method: String, _ url: String, headers: [String: String] = [:], form: [String: String]? = nil) -> (Int, Any?) {
        guard let u = URL(string: url) else { return (0, nil) }
        var req = URLRequest(url: u); req.httpMethod = method; req.timeoutInterval = 20
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let f = form {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
            let enc = { (x: String) in x.addingPercentEncoding(withAllowedCharacters: allowed) ?? x }
            req.httpBody = f.map { "\(enc($0.key))=\(enc($0.value))" }.joined(separator: "&").data(using: .utf8)
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        }
        let sem = DispatchSemaphore(value: 0); var res: (Int, Any?) = (0, nil)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            res = ((r as? HTTPURLResponse)?.statusCode ?? 0, d.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            sem.signal()
        }.resume()
        sem.wait()
        return res
    }

    static func hex<S: Sequence>(_ d: S) -> String where S.Element == UInt8 { d.map { String(format: "%02x", $0) }.joined() }

    static func encryptPassword(_ pwd: String, _ rnd: String) -> String {
        let md5 = hex(Insecure.MD5.hash(data: Data(rnd.utf8))).uppercased()
        let chars = Array(md5)
        let key = Data(String(chars[8..<24]).utf8)
        let iv = key.suffix(8) + key.prefix(8)
        return aesCBC(Data(pwd.utf8), key: key, iv: Data(iv), encrypt: true)?.base64EncodedString() ?? ""
    }

    static func modelCapacity(_ name: String) -> Double? {
        let n = name.uppercased().replacingOccurrences(of: " ", with: "")
        return capacities.first { n.contains($0.0) }?.1
    }

    static func saveDevice(_ d: [String: Any], engine: Engine) -> [String: Any] {
        let dk = d["deviceKey"] as? String ?? "", ak = d["authKey"] as? String ?? ""
        let auth: [String: Any] = ["device_key": dk, "auth_key": ak, "product_key": d["productKey"] ?? "", "name": d["deviceName"] ?? ""]
        if let data = try? JSONSerialization.data(withJSONObject: auth) {
            try? data.write(to: engine.authURL)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: engine.authURL.path)
        }
        let product = (d["productName"] as? String) ?? (d["deviceName"] as? String) ?? ""
        engine.lock.lock()
        engine.config["model"] = product
        if let cap = modelCapacity(product) { engine.config["capacity_wh"] = cap }
        engine.config["last_host"] = NSNull()
        engine.lock.unlock()
        engine.saveConfig()
        log("налаштування: збережено станцію \(product) \(dk)")
        if let t = lastTokens {   // підключення до спільного хмарного сервера: передаємо лише ключ сесії, не пароль
            lastTokens = nil
            DispatchQueue.global().async { engine.registerWithServer(tokens: t, deviceKey: dk) }
        }
        return ["ok": true, "device": ["name": d["deviceName"] ?? "", "model": product, "key": dk], "capacity_wh": engine.cfgD("capacity_wh"),
                "capacity_known": modelCapacity(product) != nil] as [String: Any]
    }

    // вхід і вибір станції змінюють спільний стан (lastTokens, pendingDevices) — виконуємо їх по черзі
    private static let flowLock = NSLock()
    static func handle(path: String, query: [String: String], body: [String: Any], engine: Engine) -> (Int, Any) {
        if path == "/api/setup/login" || path == "/api/setup/choose" {
            flowLock.lock(); defer { flowLock.unlock() }
            return handleFlow(path: path, query: query, body: body, engine: engine)
        }
        return handleFlow(path: path, query: query, body: body, engine: engine)
    }
    private static func handleFlow(path: String, query: [String: String], body: [String: Any], engine: Engine) -> (Int, Any) {
        switch path {
        case "/api/setup/login":
            guard let email = body["email"] as? String, let pwd = body["password"] as? String, !email.isEmpty, !pwd.isEmpty else {
                return (400, ["error": "вкажіть email і пароль"])
            }
            let reg = clouds[(body["region"] as? String) ?? "eu"] ?? clouds["eu"]!
            let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            let rnd = String((0..<16).map { _ in alphabet.randomElement()! })
            let enc = encryptPassword(pwd, rnd)
            let sig = hex(SHA256.hash(data: Data((email + enc + rnd + reg.secret).utf8)))
            let hdr = ["appVersion": "3.6.5", "appSystemType": "android", "appId": "277", "X-Q-Language": "en"]
            let (_, lj) = http("POST", reg.base + "/v2/enduser/enduserapi/emailPwdLogin", headers: hdr,
                               form: ["pwd": enc, "email": email, "random": rnd, "userDomain": reg.domain, "signature": sig])
            guard let login = lj as? [String: Any] else { return (502, ["error": "немає зв'язку з хмарою Wonderfree"]) }
            guard (login["code"] as? Int) == 200, let data = login["data"] as? [String: Any],
                  let token = (data["accessToken"] as? [String: Any])?["token"] as? String else {
                return (401, ["error": "не вдалося увійти: \(login["msg"] as? String ?? "перевірте email, пароль і регіон")"])
            }
            var h2 = hdr; h2["Authorization"] = token
            let at = data["accessToken"] as? [String: Any] ?? [:], rt = data["refreshToken"] as? [String: Any] ?? [:]
            if (body["cloud"] as? Bool) != false { lastTokens = ["access": token, "access_exp": at["expirationTime"] ?? 0, "refresh": rt["token"] ?? "", "refresh_exp": rt["expirationTime"] ?? 0] } else { lastTokens = nil }
            let (_, dj) = http("GET", reg.base + "/v2/binding/enduserapi/userDeviceList?page=1&pageSize=100&isAssociation=false", headers: h2)
            let list = (((dj as? [String: Any])?["data"] as? [String: Any])?["list"] as? [[String: Any]]) ?? []
            let devices = list.filter { ($0["authKey"] as? String)?.isEmpty == false }
            if devices.isEmpty { return (404, ["error": "в акаунті немає станцій. Спершу додайте станцію в застосунку Wonderfree."]) }
            if devices.count == 1 { return (200, saveDevice(devices[0], engine: engine)) }
            pendingDevices = devices
            return (200, ["choose": devices.map { ["key": $0["deviceKey"] ?? "", "name": $0["deviceName"] ?? "", "model": $0["productName"] ?? ""] as [String: Any] }])

        case "/api/setup/choose":
            guard let key = body["key"] as? String, let d = pendingDevices.first(where: { ($0["deviceKey"] as? String) == key }) else {
                return (400, ["error": "станцію не знайдено"])
            }
            pendingDevices = []
            return (200, saveDevice(d, engine: engine))

        case "/api/setup/regions":
            return (200, ["regions": yasnoRegions])

        case "/api/setup/streets":
            let rid = query["region"] ?? "25", dso = query["dso"] ?? "902"
            let q = (query["q"] ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let (_, j) = http("GET", "https://app.yasno.ua/api/blackout-service/public/shutdowns/addresses/v2/streets?regionId=\(rid)&query=\(q)&dsoId=\(dso)")
            return (200, ["items": j ?? []])

        case "/api/setup/houses":
            let rid = query["region"] ?? "25", dso = query["dso"] ?? "902", street = query["street"] ?? ""
            let q = (query["q"] ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            let (_, j) = http("GET", "https://app.yasno.ua/api/blackout-service/public/shutdowns/addresses/v2/houses?regionId=\(rid)&streetId=\(street)&query=\(q)&dsoId=\(dso)")
            return (200, ["items": j ?? []])

        case "/api/setup/group":
            let rid = (body["region_id"] as? Int) ?? 25, dso = (body["dso_id"] as? Int) ?? 902
            guard let street = body["street"] as? Int, let house = body["house"] as? Int else { return (400, ["error": "оберіть вулицю й будинок"]) }
            let (_, j) = http("GET", "https://app.yasno.ua/api/blackout-service/public/shutdowns/addresses/v2/group?regionId=\(rid)&streetId=\(street)&houseId=\(house)&dsoId=\(dso)")
            guard let g = j as? [String: Any], let grp = g["group"] as? Int else { return (404, ["error": "групу для цієї адреси не знайдено"]) }
            let name = "\(grp).\((g["subgroup"] as? Int) ?? 1)"
            engine.lock.lock()
            engine.config["group"] = name; engine.config["group_confirmed"] = true; engine.config["group_candidates"] = [String]()
            engine.config["region_id"] = rid; engine.config["dso_id"] = dso
            engine.config["region_name"] = (body["region_name"] as? String) ?? ""
            engine.config["setup_skipped_group"] = false
            engine.lock.unlock()
            engine.saveConfig()
            log("налаштування: група \(name)")
            return (200, ["ok": true, "group": name])

        default:
            return (404, ["error": "невідомий запит"])
        }
    }
}
