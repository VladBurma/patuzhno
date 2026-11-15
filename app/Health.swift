// Health.swift — автоматичний догляд за батареєю LiFePO4: статистика, цикли, калібрування, поради.
import Foundation

struct HealthStats: Codable {
    var since: Double = Date().timeIntervalSince1970
    var dischargedPct: Double = 0      // сумарно віддані відсотки (100 = один повний цикл)
    var chargedPct: Double = 0
    var lastSoc: Double? = nil
    var lastFullTs: Double? = nil      // коли востаннє було 100 %
    var lastLowTs: Double? = nil       // коли востаннє було ≤ 20 %
    var lastCalibTs: Double? = nil     // повний цикл: ≤ 20 % → 100 % без перерви
    var lowSinceFull: Double? = nil    // мінімум заряду з моменту останніх 100 %
    var deepCount: Int = 0             // скільки разів опускалась до ≤ 5 %
    var maxTemp: Double? = nil
    var peakOutW: Double = 0
    var peakOutTs: Double? = nil
    var lastTs: Double? = nil         // час попереднього запису (щоб не рахувати двічі після сну)
}

extension Engine {
    var healthURL: URL { appSupport.appendingPathComponent("health.json") }

    func loadHealth() {
        if let d = try? Data(contentsOf: healthURL), let h = try? JSONDecoder().decode(HealthStats.self, from: d) { health = h; return }
        // перший запуск — відновлюємо статистику з наявної історії
        var h = HealthStats(); h.since = history.first?.ts ?? Date().timeIntervalSince1970
        health = h
        for s in history { updateHealth(ts: s.ts, soc: s.soc, out: s.out, temp: s.temp == 0 ? nil : s.temp, save: false) }
        saveHealth()
        log("здоров'я батареї: відновлено з історії, циклів ≈ \(r1(health.dischargedPct / 100))")
    }

    func saveHealth() { if let d = try? JSONEncoder().encode(health) { try? d.write(to: healthURL) } }

    /// Викликається з кожним записом історії (раз на 10 с), під lock.
    func updateHealth(ts: Double, soc: Double, out: Double, temp: Double?, save: Bool = true) {
        var h = health
        let prev = h.lastSoc
        let gap = h.lastTs.map { ts - $0 } ?? 0
        h.lastTs = ts
        if let p = prev, gap <= 120 {   // після перерви цю ділянку дорахує дозаповнення з сервера
            let d = soc - p
            if d < 0 && d > -20 { h.dischargedPct += -d } else if d > 0 && d < 20 { h.chargedPct += d }
        }
        h.lastSoc = soc
        if soc >= 99.5 {
            if let low = h.lowSinceFull, low <= 20 { h.lastCalibTs = ts }
            h.lastFullTs = ts; h.lowSinceFull = soc
        } else {
            h.lowSinceFull = min(h.lowSinceFull ?? soc, soc)
        }
        if soc <= 20 { h.lastLowTs = ts }
        if soc <= 5 && (prev ?? 100) > 5 { h.deepCount += 1 }
        if let t = temp { h.maxTemp = max(h.maxTemp ?? t, t) }
        if out > h.peakOutW { h.peakOutW = out; h.peakOutTs = ts }
        health = h
        if save && Int(ts) % 300 < 10 { saveHealth() }
    }

    /// Повний звіт: показники, поради й перелік усього, що віддає станція.
    func healthReport(soc: Double, grid: Bool, charging: Bool, nowW: Double, nextOff: (Date, Date)?, chargeW: Double, capWh: Double) -> [String: Any] {
        let now = Date().timeIntervalSince1970, s = state, h = health
        let day = history.filter { $0.ts > now - 86400 }
        let week = history.filter { $0.ts > now - 7 * 86400 }
        let temp = s["temp"] as? Double
        let temps24 = day.map { $0.temp }.filter { $0 != 0 }
        // пік доби — лише те, що трималось хоча б два виміри поспіль (одиничні викиди вимірювача не рахуємо)
        var peak24 = 0.0
        for i in 1..<max(1, day.count) where day[i].out <= 2600 { peak24 = max(peak24, min(day[i].out, day[i - 1].out)) }
        let fullShare = week.isEmpty ? 0 : Double(week.filter { $0.soc >= 99.5 }.count) / Double(week.count)
        let cycles = h.dischargedPct / 100
        let days = max(1, (now - h.since) / 86400)
        let acLimit = s["ac_limit"] as? Double
        let fmtDay: (Double) -> String = { ts in
            let d = Date(timeIntervalSince1970: ts), f = DateFormatter(); f.locale = Locale(identifier: "uk_UA")
            f.dateFormat = Calendar.current.isDateInToday(d) ? "'сьогодні' HH:mm" : Calendar.current.isDateInYesterday(d) ? "'вчора' HH:mm" : "d MMM"
            return f.string(from: d)
        }
        var tips: [[String: Any]] = []
        func tip(_ level: String, _ icon: String, _ title: String, _ text: String, action: [String: Any]? = nil) {
            var t: [String: Any] = ["level": level, "icon": icon, "title": title, "text": text]
            if let a = action { t["action"] = a }
            tips.append(t)
        }

        // 0. спільний сервер (віддалений доступ і Telegram) не прийняв підключення
        if let ce = s["cloud_error"] as? String, !ce.isEmpty {
            tip("warn", "battery", "Віддалений доступ не підключено", "Сервер відповів: «\(ce)». Без нього не працюють панель на телефоні й Telegram-сповіщення, коли ноут вимкнений. Увійдіть у Wonderfree знову.",
                action: ["nav": "/?login=1", "label": "Увійти знову"])
        }
        // 1. навантаження
        let out = (s["out_w"] as? Double) ?? 0
        if out > 2200 { tip("alert", "peak", "Майже межа інвертора", "Зараз \(Int(out)) Вт при максимумі 2400 Вт. Вимкніть щось потужне, інакше станція відключить розетки.") }
        else if peak24 > 1900 { tip("warn", "peak", "Був пік \(Int(peak24)) Вт", "За добу навантаження підходило до межі 2400 Вт. Не вмикайте чайник, бойлер чи обігрівач одночасно з іншим.") }

        // 2. низький заряд
        if !grid && soc <= 15 { tip("alert", "battery", "Заряд \(Int(soc))%", "Світла немає, а заряду мало. Залиште тільки найважливіше — роутер, телефон.") }
        else if grid && !charging && soc < 30, let low = h.lastLowTs, now - low < 6 * 3600 {
            tip("warn", "battery", "Станція не заряджається", "Світло є, але заряд \(Int(soc))% і не росте. Перевірте, чи увімкнена зарядка від мережі.")
        }
        if h.deepCount > 0, let low = h.lastLowTs, now - low < 86400, soc < 30, !charging {
            tip("warn", "battery", "Після глибокого розряду", "Батарея опускалась майже до нуля. Зарядіть її якнайшвидше — LiFePO4 не варто довго тримати розрядженою.")
        }

        // 3. температура
        if let t = temp {
            if t >= 45 { tip("alert", "temp", "Гаряче: \(Int(t)) °C", "Поставте станцію в прохолодне місце з вільним доступом повітря, зменшіть навантаження або потужність зарядки.") }
            else if t >= 40 { tip("warn", "temp", "Тепло: \(Int(t)) °C", "Не накривайте станцію й не ставте біля батареї опалення. Нормальна робоча температура — до 35 °C.") }
            else if t <= 3 && charging { tip("warn", "temp", "Холодно для зарядки: \(Int(t)) °C", "LiFePO4 не варто заряджати на морозі — занесіть станцію в тепло.") }
        }

        // 4. калібрування відсотків (BMS)
        let calibAge = h.lastCalibTs.map { (now - $0) / 86400 }
        if calibAge == nil || calibAge! > 30 {
            var how = "Раз на місяць розрядіть станцію до 15–20% і одразу зарядіть до 100% без перерви — так BMS уточнює відсотки й залишок часу."
            if let no = nextOff, capWh > 0 {
                let a = no.0, b = no.1
                let hrs = b.timeIntervalSince(a) / 3600, socAfter = soc - nowW * hrs / (capWh * 0.9) * 100
                if socAfter <= 30 { how += " Найближче відключення (\(isoMin(a).suffix(5))) якраз розрядить її до ~\(max(0, Int(socAfter)))% — гарна нагода." }
            }
            tip(calibAge == nil ? "info" : "warn", "calib", calibAge == nil ? "Варто відкалібрувати" : "Калібрування \(Int(calibAge!)) дн тому", how)
        }

        // 5. потужність зарядки
        if grid && charging && soc < 97, let lim = acLimit {
            let needWh = (100 - soc) / 100 * capWh / 0.92
            if let no = nextOff {
                let a = no.0
                let hoursLeft = a.timeIntervalSinceNow / 3600
                let atHalf = needWh / max(200, 1800 * 0.5)
                if lim > 60 && hoursLeft > atHalf * 1.5 + 1 {
                    tip("info", "slow", "Можна заряджати повільніше", "До відключення о \(isoMin(a).suffix(5)) ще \(Int(hoursLeft)) год, а на половинній потужності станція встигне за \(String(format: "%.1f", atHalf)) год. Повільна зарядка менше гріє батарею.",
                        action: ["key": "charge_limit", "value": 50, "label": "Зарядка 50%"])
                } else if lim < 100 && hoursLeft < needWh / max(200, 1800 * lim / 100) {
                    tip("warn", "fast", "Не встигне зарядитись", "Відключення о \(isoMin(a).suffix(5)), а на поточній потужності (\(Int(lim))%) до 100% не дійде.",
                        action: ["key": "charge_limit", "value": 100, "label": "Зарядка 100%"])
                }
            } else if lim > 60 {
                tip("info", "slow", "Відключень не видно", "Графіка відключень найближчим часом немає — можна заряджати на 50% потужності, це м'якше для батареї.",
                    action: ["key": "charge_limit", "value": 50, "label": "Зарядка 50%"])
            }
        }

        // 6. постійно 100 %
        if fullShare > 0.85 && week.count > 8640 * 5 && nextOff == nil {
            tip("info", "full", "Тиждень на 100%", "Для LiFePO4 у режимі ДБЖ це нормально. Якщо відключень ще довго не буде, раз на місяць проганяйте повний цикл (див. калібрування).")
        }

        if tips.isEmpty || tips.allSatisfy({ ($0["level"] as? String) == "info" }) {
            tip("ok", "ok", "Батарея в порядку", "Температура, навантаження й заряд у нормі. Програма стежить і підкаже, якщо щось зміниться.")
        }
        let order = ["alert": 0, "warn": 1, "info": 2, "ok": 3]
        tips.sort { (order[$0["level"] as! String] ?? 9) < (order[$1["level"] as! String] ?? 9) }

        let wearPct = cycles / 3000 * 100
        let stats: [String: Any] = [
            "cycles": r1(cycles), "since": isoMin(Date(timeIntervalSince1970: h.since)), "days": Int(days),
            "cycles_per_month": r1(cycles / days * 30), "wear_pct": (wearPct * 100).rounded() / 100,
            "discharged_kwh": r1(h.dischargedPct / 100 * capWh / 1000),
            "last_full": nn(h.lastFullTs.map(fmtDay)), "last_low": nn(h.lastLowTs.map(fmtDay)), "last_calib": nn(h.lastCalibTs.map(fmtDay)),
            "full_share_week": Int((fullShare * 100).rounded()),
            "temp_now": nn(temp), "temp_max_24h": nn(temps24.max()), "temp_min_24h": nn(temps24.min()), "temp_max_ever": nn(h.maxTemp),
            "peak_24h": Int(peak24), "peak_ever": Int(h.peakOutW), "deep_count": h.deepCount,
        ]
        return ["tips": tips, "stats": stats, "params": paramsList()]
    }

    /// Усе, що станція віддає по Wi-Fi (повний опис моделі з хмари Wonderfree), з поточними значеннями.
    func paramsList() -> [[String: Any]] {
        let s = state
        func v(_ k: String, _ unit: String = "") -> Any { if let x = s[k] as? Double { return "\(x == x.rounded() ? String(Int(x)) : String(x))\(unit)" }; if let b = s[k] as? Bool { return b ? "увімк" : "вимк" }; return "—" }
        let a = (s["usb_a"] as? [Double]) ?? [], c = (s["usb_c"] as? [Double]) ?? []
        let ver: (String) -> String = { k in (s[k] as? Double).map { let n = Int($0); return "\(n / 100).\(n / 10 % 10).\(n % 10)" } ?? "—" }
        var rows: [[String: Any]] = [
            ["g": "Батарея", "k": "Заряд", "v": v("soc", "%")],
            ["g": "Батарея", "k": "Залишок часу (оцінка станції)", "v": (s["remain_min"] as? Double).map { "\(Int($0) / 60) год \(Int($0) % 60) хв" } ?? "—"],
            ["g": "Батарея", "k": "До повної зарядки (оцінка станції)", "v": chargingNow(s) ? ((s["remain_charge_min"] as? Double).map { "\(Int($0) / 60) год \(Int($0) % 60) хв" } ?? "—") : "не заряджається"],
            ["g": "Батарея", "k": "Температура станції", "v": v("temp", " °C")],
            ["g": "Вхід", "k": "Загальний вхід", "v": v("in_w", " Вт")],
            ["g": "Вхід", "k": "Зарядка від мережі (AC)", "v": v("ac_in_w", " Вт")],
            ["g": "Вхід", "k": "Зарядка від сонця/авто (DC)", "v": v("dc_in_w", " Вт")],
            ["g": "Вхід", "k": "Потужність зарядки AC (ліміт)", "v": v("ac_limit", "%")],
            ["g": "Вихід", "k": "Загальний вихід", "v": v("out_w", " Вт")],
            ["g": "Вихід", "k": "Розетки 230 В", "v": v("ac_out_w", " Вт")],
            ["g": "Вихід", "k": "Напруга на розетках", "v": v("ac_v", " В")],
            ["g": "Вихід", "k": "USB-A 1 / 2 (QC)", "v": a.count == 2 ? "\(Int(a[0])) / \(Int(a[1])) Вт" : "—"],
            ["g": "Вихід", "k": "USB-C 1 / 2 / 3 / 4", "v": c.count == 4 ? c.map { String(Int($0)) }.joined(separator: " / ") + " Вт" : "—"],
            ["g": "Вихід", "k": "Автогніздо 12 В", "v": v("dc_out_w", " Вт")],
            ["g": "Вихід", "k": "Напруга / струм автогнізда", "v": "\(v("dc_v", " В")) / \(v("dc_a", " А"))"],
            ["g": "Керування", "k": "Розетки AC", "v": v("ac_on")],
            ["g": "Керування", "k": "USB", "v": v("usb_on")],
            ["g": "Керування", "k": "Автогніздо 12 В", "v": v("dc_on")],
            ["g": "Налаштування", "k": "Напруга виходу", "v": v("ac_set_v", " В")],
            ["g": "Налаштування", "k": "Частота виходу", "v": (s["freq"] as? Double).map { $0 == 1 ? "60 Гц" : "50 Гц" } ?? "—"],
            ["g": "Прошивка", "k": "Інвертор", "v": ver("ac_ver")],
            ["g": "Прошивка", "k": "BMS (батарея)", "v": ver("bms_ver")],
        ]
        if let extra = s["extra"] as? [String: Any], !extra.isEmpty {
            for (k, x) in extra.sorted(by: { $0.key < $1.key }) { rows.append(["g": "Недокументовані", "k": "id \(k)", "v": "\(x)"]) }
        }
        return rows
    }
}

func chargingNow(_ s: [String: Any]) -> Bool {
    let inW = (s["in_w"] as? Double) ?? 0, outW = (s["out_w"] as? Double) ?? 0, soc = (s["soc"] as? Double) ?? 0
    return inW > outW + 20 && soc < 99.5
}
