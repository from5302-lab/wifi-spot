// 와이파이 명당 찾기 · 카톡 연결 고치기
// 카페 와이파이의 동의(로그인) 화면이 끝까지 안 넘어가면 웹·줌 일부는 통해도 카톡 PC판 연결은 막힌다.
// 동의를 마친 뒤에도 카톡이 이전 연결을 붙잡고 있으면 다시 켜야 붙는다. 버튼 하나로 순서대로:
//   1) http://captive.apple.com/hotspot-detect.html 에 'Success' 가 있는지(캐시 없이, 5초 제한). 없으면 기본 브라우저로 열고 3초마다 다시(최대 2분)
//   2) 카톡이 이미 바깥에 연결돼 있으면 여기서 끝(다시 켜지 않음)
//   2-1) 연결이 없을 때만 카톡 정상 종료(NSRunningApplication.terminate, 5초 안에 안 꺼지면 한 번 더) → open -g 로 뒤에서 켬(창을 앞으로 안 띄움, 마우스 안 씀)
//   3) 15초 동안 KakaoTalk 의 바깥 TCP 연결(Established)이 생기는지 nettop 으로 확인(샌드박스라 lsof 에 안 보임)
// 버튼을 누르지 않을 때는 아무것도 돌지 않는다(타이머·프로세스 없음).
// 화면은 stage·message·hint·detail·running·outcome 을 읽는다. 시작은 run().
import AppKit
import Foundation

@MainActor
final class KakaoFixer: ObservableObject {
  enum Stage: String { case idle, portalCheck, portalWait, restarting, verifying, done }
  enum Outcome: String { case connected, blocked, portalTimeout, noKakao, offline }

  static let kakaoBundle = "com.kakao.KakaoTalkMac"
  static let portalURL = URL(string: "http://captive.apple.com/hotspot-detect.html")!

  @Published private(set) var stage: Stage = .idle
  @Published private(set) var outcome: Outcome? = nil
  /// 큰 글씨 한 줄(지금 하는 일 또는 결과)
  @Published private(set) var message = ""
  /// 결과 밑 한 줄(막혔을 때 할 일 등). 없으면 ""
  @Published private(set) var hint = ""
  /// '자세히' 안에 넣을 숫자·용어(동의 화면 응답, 연결 수 등)
  @Published private(set) var detail: [String] = []
  var running: Bool { stage != .idle && stage != .done }

  private var task: Task<Void, Never>?
  var log: ((String) -> Void)? = nil   // 시험용(WIFISPOT_KAKAOFIX_LOG)

  func run() {
    guard !running else { return }
    outcome = nil; hint = ""; detail = []
    task = Task { [weak self] in await self?.go() }
  }
  func cancel() { task?.cancel(); task = nil; set(.done, "멈췄어요") }

  private func set(_ s: Stage, _ m: String) { stage = s; message = m; log?("[\(s.rawValue)] \(m)") }
  private func note(_ d: String) { detail.append(d); log?("  · \(d)") }
  private func finish(_ o: Outcome, _ m: String, hint h: String = "") { outcome = o; hint = h; set(.done, m); if !h.isEmpty { log?("  → \(h)") } }

  private func go() async {
    // 1) 동의 화면
    set(.portalCheck, "카페 와이파이 동의 확인 중")
    var p = await Self.portalState()
    note("동의 확인(captive.apple.com): \(p.label)")
    if p == .offline { finish(.offline, "인터넷에 연결되지 않았어요", hint: "와이파이에 연결됐는지 먼저 확인해 주세요"); return }
    if p == .portal {
      NSWorkspace.shared.open(Self.portalURL)
      set(.portalWait, "카페 와이파이 동의 화면을 끝까지 넘겨 주세요")
      let start = Date()
      while p != .ok {
        if Task.isCancelled { return }
        if Date().timeIntervalSince(start) > 120 { finish(.portalTimeout, "동의 화면이 아직 안 끝났어요", hint: "브라우저에 뜬 카페 와이파이 화면에서 동의·연결 버튼을 눌러 주세요"); return }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        p = await Self.portalState()
      }
      note("동의 끝남(\(Int(Date().timeIntervalSince(start)))초)")
    }
    // 2) 이미 붙어 있으면 다시 켜지 않는다(2026-11-23 충쌤 "지금 누르면 그냥 카톡이 재실행되는데, 맞아?")
    guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.kakaoBundle) else { finish(.noKakao, "카카오톡이 이 컴퓨터에 없어요"); return }
    let was = NSRunningApplication.runningApplications(withBundleIdentifier: Self.kakaoBundle)
    if let pid = was.first?.processIdentifier {
      set(.verifying, "카톡 연결 확인 중")
      // 연결이 막 바뀌는 순간을 피하려고 1초 간격으로 세 번까지 본다
      for i in 0..<3 {
        let n = await Self.externalConnections(pid)
        if n > 0 { note("카톡 바깥 연결 \(n)개(다시 켜지 않음)"); finish(.connected, "카톡은 이미 연결돼 있어요"); return }
        if i < 2 { try? await Task.sleep(nanoseconds: 1_000_000_000) }
      }
      note("카톡 바깥 연결 0개 → 다시 켬")
    }
    // 3) 카톡 다시 켜기(연결이 없을 때만. 꺼져 있었으면 켜기만)
    set(.restarting, was.isEmpty ? "카톡 켜는 중" : "카톡 다시 켜는 중")
    if !was.isEmpty {
      for round in 0..<2 {
        for a in NSRunningApplication.runningApplications(withBundleIdentifier: Self.kakaoBundle) { a.terminate() }
        for _ in 0..<25 { try? await Task.sleep(nanoseconds: 200_000_000); if NSRunningApplication.runningApplications(withBundleIdentifier: Self.kakaoBundle).isEmpty { break } }
        if NSRunningApplication.runningApplications(withBundleIdentifier: Self.kakaoBundle).isEmpty { note("카톡 끔(\(round + 1)번째에)"); break }
      }
      if !NSRunningApplication.runningApplications(withBundleIdentifier: Self.kakaoBundle).isEmpty { finish(.blocked, "카톡이 꺼지지 않았어요", hint: "카톡을 직접 끄고(⌘Q) 다시 눌러 주세요"); return }
    } else { note("카톡이 꺼져 있어 켜기만 함") }
    try? await Task.sleep(nanoseconds: 800_000_000)
    let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false; cfg.addsToRecentItems = false
    _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: cfg)
    // 3) 붙었는지
    set(.verifying, "카톡 연결 확인 중")
    let start = Date()
    while Date().timeIntervalSince(start) < 15 {
      if Task.isCancelled { return }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
      guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.kakaoBundle).first?.processIdentifier else { continue }
      let n = await Self.externalConnections(pid)
      if n > 0 { note("카톡 바깥 연결 \(n)개(\(Int(Date().timeIntervalSince(start)))초)"); finish(.connected, "카톡 연결됐어요"); return }
    }
    note("15초 동안 카톡 바깥 연결 0개")
    finish(.blocked, "이 와이파이가 카톡을 막는 것 같아요. 휴대폰 핫스팟을 써 보세요",
           hint: "IP 주소 추적 제한이 켜져 있으면 꺼 보세요(시스템 설정 > Wi-Fi > (i))")
  }

  // ── 동의 화면 확인 ──
  enum Portal: Equatable { case ok, portal, offline; var label: String { self == .ok ? "Success" : self == .portal ? "다른 페이지로 넘어감(동의 필요)" : "응답 없음" } }
  static func portalState() async -> Portal {
    var r = URLRequest(url: portalURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
    r.setValue("CaptiveNetworkSupport/1.0 wispr", forHTTPHeaderField: "User-Agent")
    let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 5; cfg.timeoutIntervalForResource = 5; cfg.urlCache = nil
    let s = URLSession(configuration: cfg)
    defer { s.finishTasksAndInvalidate() }
    guard let (data, resp) = try? await s.data(for: r) else { return .offline }
    let body = String(decoding: data, as: UTF8.self)
    let finalHost = resp.url?.host ?? ""
    return body.contains("<TITLE>Success</TITLE>") || (finalHost == "captive.apple.com" && body.contains("Success")) ? .ok : .portal
  }

  // ── 카톡 바깥 TCP 연결 수(127.0.0.1·::1 제외) ──
  // 카톡은 샌드박스 앱이라 lsof 에 소켓이 안 보인다(2026-11-23 시험: lsof 0개, nettop 6개). 그래서 nettop 의 연결 줄에서 Established 를 센다(0.1초).
  static func externalConnections(_ pid: pid_t) async -> Int {
    await withCheckedContinuation { (c: CheckedContinuation<Int, Never>) in
      DispatchQueue.global(qos: .utility).async {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-m", "tcp", "-L", "1", "-n", "-p", String(pid)]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { c.resume(returning: 0); return }
        let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        c.resume(returning: rows.filter { $0.contains(",Established,") && $0.contains("<->") && !$0.contains("<->127.0.0.1") && !$0.contains("<->::1") }.count)
      }
    }
  }
}
