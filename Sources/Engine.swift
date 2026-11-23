// 와이파이 명당 찾기 · 측정 엔진
// 1초마다: CoreWLAN 신호(RSSI·노이즈·전송 속도·대역), 1.1.1.1 ping(지연·지터·손실). 2초마다: github.com:443 TCP 연결 시간(코딩 서버까지).
// 속도 측정은 하지 않는다. 판정은 지연·흔들림·손실·신호만.
import Foundation
import CoreWLAN
import SwiftUI
import AppKit
import CoreLocation

struct Sample: Identifiable { let id = UUID(); let t: Date; let rssi: Int?; let ping: Double? }

enum Grade: Int, Codable { case good = 2, fair = 1, bad = 0
  var color: Color { switch self { case .good: return Color(red: 0.13, green: 0.62, blue: 0.38); case .fair: return Color(red: 0.86, green: 0.6, blue: 0.08); case .bad: return Color(red: 0.84, green: 0.23, blue: 0.22) } }
  var word: String { switch self { case .good: return "좋음"; case .fair: return "애매"; case .bad: return "피하기" } }
}

@MainActor
final class Engine: NSObject, ObservableObject, CLLocationManagerDelegate {
  private(set) var ssid: String? = nil
  private(set) var rssi: Int? = nil
  private(set) var noise: Int? = nil
  private(set) var txRate: Double? = nil
  private(set) var band: String = ""
  private(set) var pingMs: Double? = nil
  private(set) var codeMs: Double? = nil
  private(set) var samples: [Sample] = []
  private(set) var tick = 0
  @Published var locationAsked = false
  /// 카톡 연결 고치기(KakaoFix.swift). 화면은 e.kakao 를 @ObservedObject 로 읽고 e.kakao.run() 으로 시작
  let kakao = KakaoFixer()

  private var pings: [Double?] = []      // 최근 30초(없으면 손실)
  private var lastPing: (Double?, Bool) = (nil, false)   // (값, 새로 왔는지)
  private var paused = false             // 잠자기·화면 잠금 동안 측정 멈춤
  private var observers: [NSObjectProtocol] = []
  private var codes: [Double] = []
  private var timer: Timer?
  private var pingBusy = false
  private let loc = CLLocationManager()

  override init() {
    super.init()
    loc.delegate = self
    // 와이파이 이름(SSID)은 macOS에서 위치 권한이 있어야만 읽힌다. 처음 켤 때 바로 묻는다
    if loc.authorizationStatus == .notDetermined { loc.requestWhenInUseAuthorization() }
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in Task { @MainActor in self?.step() } }
    timer!.tolerance = 0.25   // 깨우기 합치기(전력)
    RunLoop.main.add(timer!, forMode: .common)
    watchSleep()
    step()
    // 시험용: WIFISPOT_KAKAOFIX_TEST=1 로 켜면 2초 뒤 카톡 연결 고치기를 한 번 돌리고 단계를 파일(WIFISPOT_KAKAOFIX_LOG)에 적는다
    let env = ProcessInfo.processInfo.environment
    if env["WIFISPOT_KAKAOFIX_TEST"] == "1" {
      let path = env["WIFISPOT_KAKAOFIX_LOG"] ?? "/tmp/wifispot-kakaofix.log"
      kakao.log = { line in
        let t = ISO8601DateFormatter().string(from: Date())
        if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write("\(t) \(line)\n".data(using: .utf8)!); try? h.close() }
        else { FileManager.default.createFile(atPath: path, contents: "\(t) \(line)\n".data(using: .utf8)) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.kakao.run() }
    }
  }

  /// 잠자기·화면 잠금 동안 측정 멈춤, 깨면 지난 값을 비우고 다시 시작
  private func watchSleep() {
    let ws = NSWorkspace.shared.notificationCenter, dn = DistributedNotificationCenter.default()
    let pause: (Notification) -> Void = { [weak self] _ in Task { @MainActor in self?.paused = true } }
    let resume: (Notification) -> Void = { [weak self] _ in Task { @MainActor in guard let self else { return }; self.paused = false; self.pings.removeAll(); self.codes.removeAll(); self.zoomShown = nil; self.codeShown = nil; self.step() } }
    observers += [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification].map { ws.addObserver(forName: $0, object: nil, queue: .main, using: pause) }
    observers += [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification].map { ws.addObserver(forName: $0, object: nil, queue: .main, using: resume) }
    observers.append(dn.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main, using: pause))
    observers.append(dn.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: resume))
  }

  /// 메인 창이 보이는지(닫힘·최소화·완전히 가려짐이면 false). 안 보이면 화면은 5초에 한 번만(메뉴 막대 점수용) 갱신
  private var windowVisible: Bool {
    NSApp.windows.contains { $0.title == "와이파이 명당 찾기" && $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) }
  }

  /// 메인 창 크기 고정: 크기 조절·초록 확대 버튼 막기
  private var lockedWindows = Set<ObjectIdentifier>()
  private func lockWindow() {
    for w in NSApp.windows where w.title == "와이파이 명당 찾기" && !lockedWindows.contains(ObjectIdentifier(w)) {
      w.styleMask.remove(.resizable)
      w.standardWindowButton(.zoomButton)?.isEnabled = false
      w.collectionBehavior.insert(.fullScreenNone)
      lockedWindows.insert(ObjectIdentifier(w))
    }
  }

  // ── 1초 측정 ──
  func step() {
    lockWindow()   // 창을 다시 열면 새 창이라 매번 확인(이미 잠근 창은 건너뜀)
    if paused { return }
    tick += 1
    readWiFi()
    // 지난 1초 사이 도착한 ping 반영(도착 즉시 다시 그리지 않고 틱에 묶음)
    if lastPing.1 { gotPing(lastPing.0); lastPing.1 = false }
    if !pingBusy {
      pingBusy = true
      DispatchQueue.global(qos: .utility).async { let ms = Engine.icmpPing(); Task { @MainActor in self.lastPing = (ms, true); self.pingBusy = false } }
    }
    let visible = windowVisible
    if tick % (visible ? 2 : 6) == 0 { Engine.tcpTime(host: "github.com", port: 443) { [weak self] ms in Task { @MainActor in if let ms { self?.codes.append(ms); if (self?.codes.count ?? 0) > 15 { self?.codes.removeFirst() }; self?.codeMs = self?.codes.median } } } }
    settleGrades()
    if visible || tick % 5 == 0 { objectWillChange.send() }
  }

  private var iface: CWInterface? = nil
  /// 신호 세기·잡음은 매초, 와이파이 이름은 10초마다, 채널·연결 속도는 5초마다(CoreWLAN 호출 줄이기)
  func readWiFi() {
    if iface == nil || tick % 30 == 0 { iface = CWWiFiClient.shared().interface() }
    guard let i = iface else { rssi = nil; return }
    let r = i.rssiValue(), n = i.noiseMeasurement()
    rssi = r == 0 ? nil : r
    noise = n == 0 ? nil : n
    if tick % 5 == 1 || band.isEmpty {
      txRate = i.transmitRate() > 0 ? i.transmitRate() : nil
      if let ch = i.wlanChannel() {
        switch ch.channelBand { case .band2GHz: band = "2.4GHz"; case .band5GHz: band = "5GHz"; case .band6GHz: band = "6GHz"; default: band = "" }
      } else { band = "" }
    }
    // WIFISPOT_DEMO_SSID: 화면 캡처용으로 실제 와이파이 이름 대신 보여 줄 이름
    if tick % 10 == 1 || ssid == nil { ssid = ProcessInfo.processInfo.environment["WIFISPOT_DEMO_SSID"] ?? i.ssid() }
  }

  func gotPing(_ ms: Double?) {
    pings.append(ms); if pings.count > 60 { pings.removeFirst() }   // 손실은 최근 60초, 지연·지터는 최근 30초
    pingMs = ms
    samples.append(Sample(t: Date(), rssi: rssi, ping: ms)); if samples.count > 60 { samples.removeFirst() }
  }

  // ── 계산 ──
  /// 지연·지터는 최근 30초 ping
  var okPings: [Double] { pings.suffix(30).compactMap { $0 } }
  /// 카페 와이파이가 ping(ICMP)만 막는 경우: 최근 10번 ping 이 모두 실패했는데 github 연결은 된다 → 손실은 '측정 안 됨'
  var pingBlocked: Bool { pings.count >= 10 && pings.suffix(10).allSatisfy { $0 == nil } && !codes.isEmpty }
  var latency: Double? { pingBlocked ? codeMs : (okPings.isEmpty ? nil : okPings.median) }
  var jitter: Double? {
    let p = pingBlocked ? codes : okPings; guard p.count >= 3 else { return nil }
    var s = 0.0; for k in 1..<p.count { s += abs(p[k] - p[k - 1]) }; return s / Double(p.count - 1)
  }
  /// 손실(%), 최근 60초. ping 이 막힌 망에서는 잴 수 없으므로 0으로 두고 pingBlocked 로 '측정 안 됨'을 표시
  /// 기준: 2% 미만 좋음 · 2~5% 애매('가끔 끊겨요') · 5% 이상 피하세요
  var loss: Double { pingBlocked || pings.isEmpty ? 0 : Double(pings.filter { $0 == nil }.count) / Double(pings.count) * 100 }
  var lossGrade: Grade { loss < 2 ? .good : loss < 5 ? .fair : .bad }
  /// 화면 말: 끊김 칸·이유 한 마디
  var lossWord: String { pingBlocked ? "측정 안 됨" : loss == 0 ? "없음" : loss < 2 ? "거의 없음" : loss < 5 ? "가끔" : "있어요" }
  var lossWhy: String { loss < 5 ? "가끔 끊겨요" : "끊김이 있어요" }
  var snr: Int? { if let r = rssi, let n = noise { return r - n }; return nil }

  var signalGrade: Grade { guard let r = rssi else { return .bad }; if r >= -67 && (snr ?? 30) >= 25 { return .good }; if r >= -75 { return .fair }; return .bad }
  var signalWord: String { guard let r = rssi else { return "와이파이 없음" }; if r >= -55 { return "아주 좋음" }; if r >= -67 { return "좋음" }; if r >= -75 { return "약함" }; return "나쁨" }

  /// 지금 자리 점수 0~100: 신호 40, 지연 25, 지터 20, 손실 15
  var score: Int {
    guard let r = rssi else { return 0 }
    let sig = clamp((Double(r) + 90) / 40) * 0.85 + clamp(Double((snr ?? 25) - 10) / 30) * 0.15
    let lat = latency.map { clamp(1 - ($0 - 20) / 180) } ?? 0.5
    let jit = jitter.map { clamp(1 - $0 / 50) } ?? 0.5
    let los = clamp(1 - loss / 10)
    var s = sig * 40 + lat * 25 + jit * 20 + los * 15
    return Int(s.rounded())
  }

  /// 화면에 보이는 판정: 바로 바뀌지 않고 같은 상태가 5초 이어져야 바뀜(깜빡임 방지)
  private(set) var zoomShown: Grade? = nil
  private(set) var codeShown: Grade? = nil
  private var zoomPending: (Grade, Int)? = nil
  private var codePending: (Grade, Int)? = nil
  var zoomGrade: Grade { zoomShown ?? zoomRaw }
  var codeGrade: Grade { codeShown ?? codeRaw }
  /// 매초 step 끝에서 부른다
  func settleGrades() {
    func settle(_ raw: Grade, _ shown: inout Grade?, _ pending: inout (Grade, Int)?) {
      guard let cur = shown else { if latency != nil { shown = raw }; return }   // 처음 값은 바로
      if raw == cur { pending = nil; return }
      if let p = pending, p.0 == raw { pending = (raw, p.1 + 1) } else { pending = (raw, 1) }
      if pending!.1 >= 5 { shown = raw; pending = nil }
    }
    settle(zoomRaw, &zoomShown, &zoomPending)
    settle(codeRaw, &codeShown, &codePending)
  }

  /// 줌 수업: 지터 <30ms, 손실 60초 <2%(5% 이상 피하기), 지연 <100ms
  var zoomRaw: Grade {
    guard rssi != nil, let l = latency else { return .bad }
    var g: Grade = .good
    func worse(_ x: Grade) { if x.rawValue < g.rawValue { g = x } }
    worse(l < 100 ? .good : l < 150 ? .fair : .bad)
    worse((jitter ?? 0) < 30 ? .good : (jitter ?? 0) < 50 ? .fair : .bad)
    worse(lossGrade)
    return g
  }
  /// 바이브코딩: 지연 <150ms(github 연결), 손실 60초 <2%(5% 이상 피하기)
  var codeRaw: Grade {
    guard rssi != nil, let l = codeMs ?? latency else { return .bad }
    var g: Grade = .good
    func worse(_ x: Grade) { if x.rawValue < g.rawValue { g = x } }
    worse(l < 150 ? .good : l < 250 ? .fair : .bad)
    worse(lossGrade)
    return g
  }

  // ── 와이파이 이름(위치 권한, 버튼으로만 요청) ──
  var locationAllowed: Bool { let s = loc.authorizationStatus; return s == .authorizedAlways || s == .authorized }
  var locationDenied: Bool { let s = loc.authorizationStatus; return s == .denied || s == .restricted }
  /// 거부된 뒤에는 권한 창이 다시 안 뜨므로 시스템 설정의 위치 서비스를 바로 연다
  func openLocationSettings() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!) }
  func askLocation() { locationAsked = true; loc.requestWhenInUseAuthorization() }
  nonisolated func locationManagerDidChangeAuthorization(_ m: CLLocationManager) { Task { @MainActor in self.ssid = nil; self.readWiFi(); self.objectWillChange.send() } }

  // ── 네트워크 도구 ──
  /// 1.1.1.1 로 ICMP 에코 한 번(앱 안에서 보냄: 1초마다 /sbin/ping 을 띄우던 비용 제거). 응답 시간(ms) 또는 nil
  nonisolated static func icmpPing(_ host: String = "1.1.1.1", timeout: Double = 0.9) -> Double? {
    let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var tv = timeval(tv_sec: 0, tv_usec: Int32(timeout * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return nil }
    let ident = UInt16(truncatingIfNeeded: getpid()), seq = UInt16.random(in: 0...UInt16.max)
    var pkt = [UInt8](repeating: 0, count: 16)
    pkt[0] = 8; pkt[4] = UInt8(ident >> 8); pkt[5] = UInt8(ident & 0xff); pkt[6] = UInt8(seq >> 8); pkt[7] = UInt8(seq & 0xff)
    var sum: UInt32 = 0
    for i in stride(from: 0, to: pkt.count, by: 2) { sum += UInt32(pkt[i]) << 8 | UInt32(pkt[i + 1]) }
    while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
    let ck = ~UInt16(sum); pkt[2] = UInt8(ck >> 8); pkt[3] = UInt8(ck & 0xff)
    let t0 = DispatchTime.now().uptimeNanoseconds
    let sent = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, pkt, pkt.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard sent == pkt.count else { return nil }
    var buf = [UInt8](repeating: 0, count: 256)
    while true {
      let n = recv(fd, &buf, buf.count, 0)
      if n <= 0 { return nil }   // 시간 초과
      let el = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
      if el > timeout * 1000 { return nil }
      var o = 0; if (buf[0] >> 4) == 4 { o = Int(buf[0] & 0x0f) * 4 }   // IP 머리가 붙어 오면 건너뜀
      guard n >= o + 8 else { continue }
      if buf[o] == 0, UInt16(buf[o + 6]) << 8 | UInt16(buf[o + 7]) == seq { return el }
    }
  }
  /// github.com:443 TCP 연결 시간(ms). Network.framework 대신 가벼운 소켓으로, 주소는 5분마다 한 번만 찾는다
  nonisolated(unsafe) static var cached: (ip: in_addr, at: Date)? = nil
  nonisolated static func tcpTime(host: String, port: UInt16, done: @escaping (Double?) -> Void) {
    DispatchQueue.global(qos: .utility).async { done(tcpConnectMs(host: host, port: port)) }
  }
  nonisolated static func resolve(_ host: String) -> in_addr? {
    if let c = cached, Date().timeIntervalSince(c.at) < 300 { return c.ip }
    var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
    var res: UnsafeMutablePointer<addrinfo>? = nil
    guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res, let sa = r.pointee.ai_addr else { return nil }
    defer { freeaddrinfo(res) }
    let ip = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    cached = (ip, Date()); return ip
  }
  nonisolated static func tcpConnectMs(host: String, port: UInt16, timeout: Int32 = 1800) -> Double? {
    guard let ip = resolve(host) else { return nil }
    let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { return nil }
    defer { close(fd) }
    var on: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let fl = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, fl | O_NONBLOCK)
    var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_port = port.bigEndian; addr.sin_addr = ip
    let t0 = DispatchTime.now().uptimeNanoseconds
    let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if rc != 0 && errno != EINPROGRESS { return nil }
    var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    guard poll(&pfd, 1, timeout) == 1 else { return nil }
    var err: Int32 = 0; var len = socklen_t(MemoryLayout<Int32>.size)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    guard err == 0 else { cached = nil; return nil }
    return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
  }

}

func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
extension Array where Element == Double { var median: Double { let s = sorted(); return s.isEmpty ? 0 : s[s.count / 2] } }
